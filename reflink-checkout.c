/*
 * Copy-on-write ("reflink") checkout. See
 * Documentation/technical/reflink-checkout.adoc for the design.
 */
#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "reflink-checkout.h"
#include "abspath.h"
#include "config.h"
#include "convert.h"
#include "copy.h"
#include "dir.h"
#include "entry.h"
#include "gettext.h"
#include "hash.h"
#include "object-file.h"
#include "odb.h"
#include "odb/streaming.h"
#include "parse.h"
#include "path.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "run-command.h"
#include "statinfo.h"
#include "strbuf.h"
#include "string-list.h"
#include "tempfile.h"
#include "trace2.h"
#include "worktree.h"
#include "write-or-die.h"

#ifdef __APPLE__
#include <sys/xattr.h>
#endif

/*
 * A reflink source is named by its administrative directory relative
 * to the common directory: "." for the main worktree, "worktrees/<id>"
 * for a linked one. Unlike a path, that survives "git worktree move".
 */
static void worktree_spec(const struct worktree *wt, struct strbuf *out)
{
	strbuf_reset(out);
	if (is_main_worktree(wt))
		strbuf_addch(out, '.');
	else
		strbuf_addf(out, "worktrees/%s", wt->id);
}

int reflink_source_spec(struct repository *r, const char *prefix,
			const char *arg, struct strbuf *out)
{
	struct worktree **wts, *wt;
	int ret = -1;

	strbuf_reset(out);
	wts = get_worktrees_without_reading_head(r);
	if (arg)
		wt = find_worktree(wts, prefix, arg);
	else if (!wts[0]->is_bare)
		wt = wts[0];
	else if (r->worktree)
		wt = find_worktree_by_path(wts, r->worktree);
	else
		wt = NULL;
	if (wt && !wt->is_bare) {
		worktree_spec(wt, out);
		ret = 0;
	}
	free_worktrees(wts);
	return ret;
}

#if defined(__APPLE__) || defined(__linux__)

enum reflink_test_mode {
	REFLINK_TEST_OFF = 0,
	/* clone every eligible file, from a scratch donor if need be */
	REFLINK_TEST_ON,
	/* clone a wrong scratch donor, then force discard-and-write fallback */
	REFLINK_TEST_CORRUPT,
};

/*
 * Per-process state. It belongs to the first repository that checks
 * out a file; checkouts in any other repository in the same process
 * (there are none today, submodules are checked out by child
 * processes) do not clone.
 */
static struct {
	struct repository *repo;
	unsigned initialized : 1,
		 enabled : 1,
		 source_resolved : 1,
		 source_unusable : 1,
		 scratch_unusable : 1;
	enum reflink_test_mode test;
	char *marker;		/* contents of $GIT_DIR/reflink-source, or NULL */
	char *source_path;	/* working tree of the reflink source */
	char *source_gitdir;
	char *source_index_path;
	struct index_state *source_index;
	unsigned char *source_converted;
	unsigned clone_errors;	/* failed clones while none succeeded */
	unsigned clones_ok;
} rc;

static void count(enum trace2_counter_id id)
{
	trace2_counter_add(id, 1);
}

static char *read_marker(struct repository *r)
{
	struct strbuf sb = STRBUF_INIT;
	char *path = repo_git_path(r, REFLINK_SOURCE_FILE);
	int exists = strbuf_read_file(&sb, path, 0) >= 0;

	free(path);
	if (!exists) {
		strbuf_release(&sb);
		return NULL;
	}
	strbuf_trim(&sb);
	return strbuf_detach(&sb, NULL);
}

static void init_reflink(struct repository *r)
{
	const char *env = getenv("GIT_TEST_REFLINK_CHECKOUT");
	int v;

	rc.initialized = 1;
	rc.repo = r;
	if (!r->gitdir || !r->worktree)
		return;

	rc.marker = read_marker(r);

	if (env && *env) {
		if (!strcmp(env, "corrupt"))
			rc.test = REFLINK_TEST_CORRUPT;
		else if ((v = git_parse_maybe_bool(env)) == 0)
			return; /* forced off */
		else if (v > 0)
			rc.test = REFLINK_TEST_ON;
		else
			die(_("bad value '%s' for GIT_TEST_REFLINK_CHECKOUT"), env);
	}

	if (!rc.test) {
		/*
		 * An explicit checkout.reflink=false is a kill switch;
		 * otherwise "true", or a reflink-source file left by
		 * "git worktree add --reflink", turns it on.
		 */
		const char *value;

		if (!repo_config_get_string_tmp(r, "checkout.reflink", &value)) {
			/*
			 * Never die halfway through a checkout over this:
			 * a bad value just means "off".
			 */
			v = git_parse_maybe_bool(value);
			if (v < 0)
				warning(_("bad boolean config value '%s' for '%s'; "
					  "not cloning"), value, "checkout.reflink");
			if (v <= 0)
				return;
		} else if (!rc.marker) {
			return;
		}
	}

	rc.enabled = 1;
}

static int same_filesystem(const char *a, const char *b)
{
	struct stat sa, sb;

	return !stat(a, &sa) && !stat(b, &sb) && sa.st_dev == sb.st_dev;
}

/* Can "wt" be a reflink source of the current worktree at all? */
static int usable_source(const struct worktree *wt)
{
	return wt && !wt->is_bare && !wt->is_current && wt->path &&
	       is_directory(wt->path);
}

static void resolve_source(struct repository *r)
{
	struct worktree **wts, **p, *src = NULL;
	struct strbuf spec = STRBUF_INIT;
	const char *config = NULL;

	rc.source_resolved = 1;
	wts = get_worktrees_without_reading_head(r);

	/*
	 * The first usable one of: the worktree named by our reflink-source
	 * file, checkout.reflinkSource (a worktree path or name), the main
	 * worktree. A missing, bare or self candidate is not an error.
	 */
	if (rc.marker && *rc.marker) {
		for (p = wts; *p && !src; p++) {
			worktree_spec(*p, &spec);
			if (!strcmp(spec.buf, rc.marker) && usable_source(*p))
				src = *p;
		}
	}
	if (!src && !repo_config_get_string_tmp(r, "checkout.reflinksource",
						&config)) {
		struct worktree *wt = find_worktree(wts, NULL, config);
		if (usable_source(wt))
			src = wt;
	}
	if (!src && usable_source(wts[0]))
		src = wts[0];

	/*
	 * Neither is one on a filesystem we cannot clone on: find that out
	 * now, before reading its index.
	 */
	if (src && same_filesystem(src->path, r->worktree) &&
	    path_fs_can_clone(src->path)) {
		rc.source_path = xstrdup(src->path);
		rc.source_gitdir = get_worktree_git_dir(src);
		rc.source_index_path = xstrdup(worktree_git_path(src, "index"));
	}
	trace2_data_string("reflink", r, "source",
			   rc.source_path ? rc.source_path : "(none)");
	strbuf_release(&spec);
	free_worktrees(wts);
}

static struct index_state *source_index(struct repository *r)
{
	if (!rc.source_resolved)
		resolve_source(r);
	if (!rc.source_path || rc.source_unusable)
		return NULL;
	if (!rc.source_index) {
		rc.source_index = xmalloc(sizeof(*rc.source_index));
		index_state_init(rc.source_index, r);
		/*
		 * Read it as it is on disk, and never die over it: a
		 * reflink source whose index we cannot read only means
		 * that nothing gets cloned.
		 */
		if (read_index_from_flags(rc.source_index,
					  rc.source_index_path,
					  rc.source_gitdir,
					  READ_INDEX_GENTLY | READ_INDEX_RAW) < 0) {
			release_index(rc.source_index);
			index_state_init(rc.source_index, r);
			rc.source_unusable = 1;
			trace2_data_string("reflink", r, "source-index",
					   "unreadable");
		}
	}
	return rc.source_unusable ? NULL : rc.source_index;
}

/*
 * Errors that say "these two paths can never be cloned", as opposed to
 * a problem with one file. After one of these we stop trying.
 */
static int clone_unsupported(int err)
{
	return err == EXDEV || err == ENOSYS || err == ENOTSUP ||
#if defined(EOPNOTSUPP) && EOPNOTSUPP != ENOTSUP
	       err == EOPNOTSUPP ||
#endif
	       err == ENOTTY;
}

static int donor_changed(struct index_state *src,
			 const struct cache_entry *ce, struct stat *st)
{
	/* Only the recipient's executable bit determines the created mode. */
	return ie_match_stat(src, ce, st,
		CE_MATCH_IGNORE_VALID | CE_MATCH_IGNORE_SKIP_WORKTREE |
		CE_MATCH_IGNORE_FSMONITOR | CE_MATCH_RACY_IS_DIRTY) & ~MODE_CHANGED;
}

/*
 * Attribute lookup must run in the source worktree's context: its attributes,
 * config.worktree and core.attributesFile need not be ours. Use check-attr's
 * existing lookup, once per process, rather than teaching convert.c about a
 * second worktree. EOL conversions are covered by the blob size check or
 * comparison with the recipient's checkout output below.
 */
static int read_source_attributes(struct index_state *src)
{
	static const char *attrs[] = { "filter", "working-tree-encoding", NULL };
	struct child_process cmd = CHILD_PROCESS_INIT;
	struct child_process config = CHILD_PROCESS_INIT;
	struct strbuf input = STRBUF_INIT, output = STRBUF_INIT;
	struct string_list filters = STRING_LIST_INIT_DUP;
	const char *p, *end;
	int ret = -1;
	int status;

	if (rc.source_converted)
		return 0;
	config.git_cmd = 1;
	config.dir = rc.source_path;
	config.no_stderr = 1;
	prepare_other_repo_env(&config.env, rc.source_gitdir);
	strvec_pushl(&config.args, "config", "--null", "--get-regexp",
		     "^filter\\..*\\.(clean|smudge|process)$", NULL);
	status = pipe_command(&config, NULL, 0, &output, 0, NULL, 0);
	if (status && status != 1)
		goto out;
	for (char *key = output.buf; key < output.buf + output.len; ) {
		char *value = strchr(key, '\n');
		char *next = key + strlen(key) + 1;
		char *dot;

		if (!value)
			goto out;
		*value = 0;
		dot = strrchr(key, '.');
		if (!dot || dot <= key + strlen("filter."))
			goto out;
		*dot = 0;
		string_list_insert(&filters, key + strlen("filter."));
		key = next;
	}
	strbuf_reset(&output);
	for (size_t i = 0; i < src->cache_nr; i++)
		strbuf_add(&input, src->cache[i]->name,
			   ce_namelen(src->cache[i]) + 1);
	cmd.git_cmd = 1;
	cmd.dir = rc.source_path;
	cmd.no_stderr = 1;
	prepare_other_repo_env(&cmd.env, rc.source_gitdir);
	strvec_pushl(&cmd.args, "-c", "core.fsmonitor=false",
		     "check-attr", "--stdin", "-z", NULL);
	strvec_pushv(&cmd.args, attrs);
	if (pipe_command(&cmd, input.buf, input.len, &output, 0, NULL, 0))
		goto out;
	CALLOC_ARRAY(rc.source_converted, src->cache_nr);
	p = output.buf;
	end = p + output.len;
	for (size_t i = 0; i < src->cache_nr; i++) {
		for (size_t j = 0; j < ARRAY_SIZE(attrs) - 1; j++) {
			const char *fields[3];

			for (size_t k = 0; k < ARRAY_SIZE(fields); k++) {
				const char *nul = memchr(p, 0, end - p);
				if (!nul)
					goto out;
				fields[k] = p;
				p = nul + 1;
			}
			if (strcmp(fields[0], src->cache[i]->name) ||
			    strcmp(fields[1], attrs[j]))
				goto out;
			if ((!j && string_list_has_string(&filters, fields[2])) ||
			    (j && strcmp(fields[2], "unspecified") &&
			     strcmp(fields[2], "unset")))
				rc.source_converted[i] = 1;
		}
	}
	if (p == end)
		ret = 0;
out:
	if (ret)
		FREE_AND_NULL(rc.source_converted);
	strbuf_release(&input);
	strbuf_release(&output);
	string_list_clear(&filters, 0);
	return ret;
}

/*
 * Phase one: find a file in the reflink source that, as far as its
 * index knows, holds the blob of "ce" unmodified. Returns a descriptor
 * open on it, or -1.
 */
static int open_donor(struct repository *r, const struct cache_entry *ce,
		      struct strbuf *donor, const struct cache_entry **source_ce,
		      int compare_output)
{
	struct index_state *src = source_index(r);
	const struct cache_entry *sce;
	struct stat st;
	size_t size;
	int pos, fd;

	if (!src)
		return -1;
	pos = index_name_pos_sparse(src, ce->name, ce_namelen(ce));
	if (pos < 0) {
		count(TRACE2_COUNTER_ID_REFLINK_NO_DONOR);
		return -1;
	}
	sce = src->cache[pos];
	if (ce_stage(sce) || !S_ISREG(sce->ce_mode) ||
	    (sce->ce_flags & (CE_SKIP_WORKTREE | CE_INTENT_TO_ADD | CE_REMOVE)) ||
	    !oideq(&sce->oid, &ce->oid)) {
		count(TRACE2_COUNTER_ID_REFLINK_NO_DONOR);
		return -1;
	}
	/*
	 * An empty file is cheaper to create than to clone. (Not sd_size,
	 * which is truncated to 32 bits: a 4 GiB file has sd_size 0.)
	 */
	if (is_empty_blob_oid(&ce->oid, r->hash_algo))
		return -1;
	/*
	 * With these checks disabled, even restoring mtime can hide an edit.
	 * Decline the optimization instead of adding content verification.
	 */
	if (!repo_config_values(r)->check_stat ||
	    !repo_config_values(r)->trust_ctime) {
		count(TRACE2_COUNTER_ID_REFLINK_SOURCE_DIRTY);
		return -1;
	}
	if (read_source_attributes(src)) {
		rc.source_unusable = 1;
		return -1;
	}
	if (rc.source_converted[pos])
		goto dirty;

	strbuf_reset(donor);
	strbuf_addf(donor, "%s/%s", rc.source_path, ce->name);
	/*
	 * Skip anything the reflink source's own index would call
	 * modified. Look at the very file we will clone from, through a
	 * descriptor, so that it cannot be swapped for something else
	 * (a directory, a FIFO, a symlink) before we clone it.
	 */
	fd = open(donor->buf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
	if (fd < 0)
		goto dirty;
	if (fstat(fd, &st) || !S_ISREG(st.st_mode) ||
	    donor_changed(src, sce, &st) ||
	    odb_read_object_info(r->objects, &ce->oid, &size) != OBJ_BLOB ||
	    st.st_size < 0 || (!compare_output && (uintmax_t)st.st_size != size)) {
		close(fd);
		goto dirty;
	}
	*source_ce = sce;
	return fd;

dirty:
	count(TRACE2_COUNTER_ID_REFLINK_SOURCE_DIRTY);
	return -1;
}

/* Compare only the output whose physical representation the index cannot tell us. */
static int match_output_chunk(int fd, const char *expected, size_t len)
{
	char actual[16384];

	while (len) {
		size_t n = sizeof(actual) < len ? sizeof(actual) : len;
		ssize_t got = read_in_full(fd, actual, n);

		if (got > 0)
			trace2_counter_add(TRACE2_COUNTER_ID_REFLINK_OUTPUT_BYTES, got);
		if (got < 0 || (size_t)got != n || memcmp(actual, expected, n))
			return 0;
		expected += n;
		len -= n;
	}
	return 1;
}

/*
 * A clean index records normalized identity, not the checkout representation.
 * In particular, changing attributes and refreshing can leave a clean LF donor
 * under eol=crlf. Compare the clone with what the ordinary recipient writer
 * would produce. Never run an external filter here: it may depend on checkout
 * metadata, the pathname, or state, and must run exactly in the ordinary writer.
 *
 * Explicit EOL conversion streams just as checkout does. Auto conversion needs
 * the ordinary in-core converter's binary/mixed-EOL detection. No object hash
 * or index/stat metadata is replaced by this comparison.
 */
static int compare_clone_output(struct repository *r, const struct cache_entry *ce,
				const struct conv_attrs *ca, int fd)
{
	struct stream_filter *filter = get_stream_filter_ca(ca, &ce->oid);
	char extra;
	int matches = 1;

	if (filter) {
		struct odb_stream *stream = odb_stream_from_object(r->objects,
								 &ce->oid, filter);
		char expected[16384];
		ssize_t n;

		if (!stream) {
			free_stream_filter(filter);
			return 0;
		}
		if (stream->type != OBJ_BLOB)
			matches = 0;
		while (matches && (n = odb_stream_read(stream, expected,
						       sizeof(expected))) != 0) {
			if (n < 0 || !match_output_chunk(fd, expected, n))
				matches = 0;
		}
		if (odb_stream_close(stream))
			matches = 0;
	} else {
		enum object_type type;
		size_t size;
		char *blob = odb_read_object(r->objects, &ce->oid, &type, &size);
		struct strbuf converted = STRBUF_INIT;

		if (!blob || type != OBJ_BLOB) {
			free(blob);
			return 0;
		}
		if (convert_to_working_tree_ca(ca, ce->name, blob, size,
					      &converted, NULL))
			matches = match_output_chunk(fd, converted.buf, converted.len);
		else
			matches = match_output_chunk(fd, blob, size);
		strbuf_release(&converted);
		free(blob);
	}
	return matches && read_in_full(fd, &extra, 1) == 0;
}

static int clone_matches_output(struct repository *r, const struct cache_entry *ce,
				const struct conv_attrs *ca, int fd)
{
	int matches;

	count(TRACE2_COUNTER_ID_REFLINK_OUTPUT_COMPARED);
	trace2_region_enter("reflink", "compare-output", r);
	matches = compare_clone_output(r, ce, ca, fd);
	trace2_region_leave("reflink", "compare-output", r);
	return matches;
}

/*
 * Test mode: write the blob to a scratch file with deliberately unlike
 * metadata, so that every eligible file in the test suite goes through
 * cloning, metadata fix-ups and fallback. Returns a descriptor on
 * it; the file itself is already gone.
 */
static int open_scratch_donor(struct repository *r, const struct cache_entry *ce)
{
	struct timespec old[2] = { { 978307200, 0 }, { 978307200, 0 } };
	struct tempfile *tmp;
	char *template;
	int fd, ret = 0;

	if (rc.scratch_unusable)
		return -1;
	template = repo_git_path(r, "reflink-donor-XXXXXX");
	tmp = mks_tempfile_m(template, 0700);
	free(template);
	if (!tmp)
		return -1;
	fd = get_tempfile_fd(tmp);
	/* stream it, large blobs must not be read into memory */
	if (odb_stream_blob_to_fd(r->objects, fd, &ce->oid, NULL, 0) ||
	    (rc.test == REFLINK_TEST_CORRUPT && write_in_full(fd, "\n", 1) < 0))
		ret = -1;
#ifdef __APPLE__
	fsetxattr(fd, "org.git-scm.test-reflink", "1", 1, 0, 0);
#endif
	futimens(fd, old);
	fd = ret ? -1 : open(get_tempfile_path(tmp), O_RDONLY);
	delete_tempfile(&tmp);
	if (fd >= 0)
		count(TRACE2_COUNTER_ID_REFLINK_SCRATCH);
	return fd;
}

/*
 * Test hook: simulate someone changing the donor of the path named by
 * $GIT_TEST_REFLINK_TAMPER after phase one and before it is cloned.
 * "<path>" appends to the donor; "<path>:replace" renames it away and
 * puts a directory holding an untracked file in its place.
 */
static void tamper_with_donor(const struct cache_entry *ce, const char *donor)
{
	const char *env = getenv("GIT_TEST_REFLINK_TAMPER");
	const char *how;
	size_t len;

	if (!env)
		return;
	how = strchrnul(env, ':');
	len = how - env;
	if (len != ce_namelen(ce) || strncmp(env, ce->name, len))
		return;
	if (!*how) {
		int fd = open(donor, O_WRONLY | O_APPEND);
		if (fd < 0 || write_in_full(fd, "tampered\n", 9) < 0)
			die_errno("GIT_TEST_REFLINK_TAMPER: cannot modify '%s'",
				  donor);
		close(fd);
	} else if (!strcmp(how, ":replace")) {
		struct strbuf sb = STRBUF_INIT;

		strbuf_addf(&sb, "%s.tampered", donor);
		if (rename(donor, sb.buf) || mkdir(donor, 0777))
			die_errno("GIT_TEST_REFLINK_TAMPER: cannot replace '%s'",
				  donor);
		strbuf_reset(&sb);
		strbuf_addf(&sb, "%s/untracked", donor);
		write_file(sb.buf, "untracked");
		strbuf_release(&sb);
	} else {
		die("GIT_TEST_REFLINK_TAMPER: unknown mode '%s'", how + 1);
	}
}

int reflink_checkout_entry(const struct cache_entry *ce,
			   const struct conv_attrs *ca,
			   const struct checkout *state,
			   const char *path,
			   struct stat *st, int *fstat_done)
{
	struct repository *r = state->istate && state->istate->repo ?
		state->istate->repo : the_repository;
	static struct strbuf donor = STRBUF_INIT;
	const struct cache_entry *source_ce = NULL;
	int src_fd = -1, fd, scratch = 0, compare_output;

	if (!rc.initialized)
		init_reflink(r);
	if (!rc.enabled || r != rc.repo || !S_ISREG(ce->ce_mode) || !ca ||
	    ca->drv || ca->working_tree_encoding || ca->ident)
		return -1;
	compare_output = !convert_to_working_tree_is_noop_ca(ca);

	if (rc.test != REFLINK_TEST_CORRUPT)
		src_fd = open_donor(r, ce, &donor, &source_ce, compare_output);
	if (src_fd < 0) {
		if (!rc.test || compare_output)
			return -1;
		src_fd = open_scratch_donor(r, ce);
		if (src_fd < 0)
			return -1;
		scratch = 1;
	} else {
		tamper_with_donor(ce, donor.buf);
	}

	fd = clone_fd_to_file(src_fd, path, ce->ce_mode);
	if (fd < 0) {
		int err = errno;

		close(src_fd);
		/*
		 * Something is in the way at "path" (a path collision on a
		 * case-insensitive filesystem, say): the caller's ordinary
		 * write reports or handles that, it says nothing about
		 * cloning.
		 */
		if (err == EEXIST || err == EISDIR || err == ENOENT ||
		    err == ENOTDIR)
			return -1;
		count(TRACE2_COUNTER_ID_REFLINK_CLONE_FAILED);
		/*
		 * Stop trying once the filesystem says it cannot clone,
		 * or after a run of failures without a single success
		 * (e.g. btrfs refusing every file of a nodatacow tree).
		 */
		if (clone_unsupported(err) ||
		    (!rc.clones_ok && ++rc.clone_errors >= 16)) {
			if (scratch)
				rc.scratch_unusable = 1;
			else
				rc.source_unusable = 1;
		}
		return -1;
	}
	rc.clones_ok++;

	/*
	 * A concurrent ordinary write must not be recorded as clean in the
	 * recipient. Recheck the same descriptor against the source's index;
	 * never copy donor stat data into the recipient's cache entry.
	 */
	if ((!scratch && (fstat(src_fd, st) ||
			 donor_changed(rc.source_index, source_ce, st))) ||
	    (scratch && rc.test == REFLINK_TEST_CORRUPT) ||
	    (compare_output && !clone_matches_output(r, ce, ca, fd))) {
		count(TRACE2_COUNTER_ID_REFLINK_VERIFY_FAILED);
		close(src_fd);
		close(fd);
		unlink(path);
		return -1;
	}
	close(src_fd);

	*fstat_done = fstat_checkout_output(fd, state, st);
	if (close(fd)) {
		unlink(path);
		return -1;
	}
	count(TRACE2_COUNTER_ID_REFLINK_CLONED);
	return 0;
}

#else

int reflink_checkout_entry(const struct cache_entry *ce UNUSED,
			   const struct conv_attrs *ca UNUSED,
			   const struct checkout *state UNUSED,
			   const char *path UNUSED,
			   struct stat *st UNUSED, int *fstat_done UNUSED)
{
	/* clone_fd_to_file() is not implemented on this platform */
	return -1;
}

#endif
