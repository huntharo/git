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
#include "lockfile.h"
#include "object-file.h"
#include "odb.h"
#include "odb/streaming.h"
#include "parse.h"
#include "quote.h"
#include "setup.h"
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
#include <copyfile.h>
#include <sys/acl.h>
#include <sys/attr.h>
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
		 resharing : 1,
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
	/* Existing checkout counters describe creation, not the repair scan. */
	if (!rc.resharing)
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

static int configured_reflink(struct repository *r)
{
	const char *value;
	int v;

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
			return 0;
	} else if (!rc.marker) {
		return 0;
	}
	return 1;
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

	if (!rc.test && !configured_reflink(r))
		return;

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
enum donor_use {
	DONOR_RAW_CHECKOUT,
	DONOR_EOL_CHECKOUT,
	DONOR_IN_PLACE,
};

static int open_donor(struct repository *r, const struct cache_entry *ce,
		      struct strbuf *donor, const struct cache_entry **source_ce,
		      enum donor_use use)
{
	struct index_state *src = source_index(r);
	const struct cache_entry *sce;
	struct stat st;
	size_t size;
	int pos, fd, open_flags = 0;

#if defined(__linux__) && defined(O_NOATIME)
	if (use == DONOR_IN_PLACE)
		open_flags = O_NOATIME;
#endif
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
	/* In-place dedupe imports no bytes; the kernel compares actual target data. */
	if (use != DONOR_IN_PLACE) {
		if (read_source_attributes(src)) {
			rc.source_unusable = 1;
			return -1;
		}
		if (rc.source_converted[pos])
			goto dirty;
	}

	strbuf_reset(donor);
	strbuf_addf(donor, "%s/%s", rc.source_path, ce->name);
	/*
	 * Skip anything the reflink source's own index would call
	 * modified. Look at the very file we will clone from, through a
	 * descriptor, so that it cannot be swapped for something else
	 * (a directory, a FIFO, a symlink) before we clone it.
	 */
	fd = open(donor->buf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | open_flags);
	if (fd < 0)
		goto dirty;
	if (fstat(fd, &st) || !S_ISREG(st.st_mode) ||
	    donor_changed(src, sce, &st) ||
	    st.st_size < 0 ||
	    (use != DONOR_IN_PLACE &&
	     (odb_read_object_info(r->objects, &ce->oid, &size) != OBJ_BLOB ||
	      (use == DONOR_RAW_CHECKOUT && (uintmax_t)st.st_size != size)))) {
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
		src_fd = open_donor(r, ce, &donor, &source_ce,
				    compare_output ? DONOR_EOL_CHECKOUT : DONOR_RAW_CHECKOUT);
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

/*
 * Unlike checkout creation, this operation preserves the existing target's
 * physical representation. Linux compares and shares in place. APFS compares
 * a clone with the target and replaces the path under Git's ordinary file
 * replacement concurrency assumptions (see worktree-reflink.adoc).
 */
struct reshare_result {
	const char *status;
	const char *reason;
	struct file_data_usage before, after;
	int before_known, after_known;
	uintmax_t deduplicated;
};

struct reshare_totals {
	uintmax_t scanned, eligible, already_shared, reshared, skipped, failed;
	uintmax_t allocated_before, allocated_after, private_before, private_after;
	uintmax_t potential_private, deduplicated, allocation_unknown;
	uintmax_t stat_clean, content_checked, content_check_bytes;
	uintmax_t userspace_compared, native_attempts, native_range_bytes;
	uintmax_t clone_attempts, comparison_bytes;
};

int reflink_checkout_enabled(struct repository *r)
{
	if (!rc.initialized)
		init_reflink(r);
	return rc.repo == r && rc.enabled && configured_reflink(r);
}

static int same_file_stat(const struct stat *a, const struct stat *b)
{
	return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
		a->st_mode == b->st_mode && a->st_nlink == b->st_nlink &&
		a->st_uid == b->st_uid && a->st_gid == b->st_gid &&
		a->st_size == b->st_size && a->st_mtime == b->st_mtime &&
		a->st_ctime == b->st_ctime &&
		ST_MTIME_NSEC(*a) == ST_MTIME_NSEC(*b) &&
		ST_CTIME_NSEC(*a) == ST_CTIME_NSEC(*b);
}

static int same_fd_bytes(int a, int b, off_t size)
{
	char abuf[16384], bbuf[16384];
	off_t offset = 0;

	while (offset < size) {
		uintmax_t left = size - offset;
		size_t len = left < sizeof(abuf) ? left : sizeof(abuf);
		ssize_t got_a = pread_in_full(a, abuf, len, offset);
		ssize_t got_b = pread_in_full(b, bbuf, len, offset);

		if (got_a < 0 || got_b < 0 || (size_t)got_a != len || (size_t)got_b != len)
			return -1;
		if (memcmp(abuf, bbuf, len))
			return 0;
		offset += len;
	}
	return 1;
}

#ifdef __APPLE__
/* copyfile may ignore individual metadata errors: verify before publishing. */
static int same_xattrs(int a, int b)
{
	ssize_t len = flistxattr(a, NULL, 0, 0), other = flistxattr(b, NULL, 0, 0);
	char *names, *av = NULL, *bv = NULL;
	int equal = 0;

	if (len < 0 || other != len)
		return 0;
	names = xmalloc(len + 1);
	if (flistxattr(a, names, len, 0) != len)
		goto out;
	for (ssize_t i = 0; i < len;) {
		const char *name = names + i;
		ssize_t size;
		size_t n = strnlen(name, len - i);

		if (n == (size_t)(len - i))
			goto out;
		i += n + 1;
		size = fgetxattr(a, name, NULL, 0, 0, 0);
		if (size < 0 || fgetxattr(b, name, NULL, 0, 0, 0) != size)
			goto out;
		av = xmalloc(size + 1);
		bv = xmalloc(size + 1);
		if (fgetxattr(a, name, av, size, 0, 0) != size ||
		    fgetxattr(b, name, bv, size, 0, 0) != size || memcmp(av, bv, size))
			goto out;
		FREE_AND_NULL(av);
		FREE_AND_NULL(bv);
	}
	equal = 1;
out:
	free(names);
	free(av);
	free(bv);
	return equal;
}

static int preserve_reshare_metadata(int target, int clone, const struct stat *st)
{
	struct attrlist al = { .bitmapcount = ATTR_BIT_MAP_COUNT,
		.commonattr = ATTR_CMN_CRTIME };
	struct timespec times[2] = { st->st_atimespec, st->st_mtimespec };
	struct stat actual;
	acl_t a = NULL, b = NULL;
	char *at = NULL, *bt = NULL;
	int ret = -1, aerr, berr;

	if (fcopyfile(target, clone, NULL, COPYFILE_METADATA) ||
	    fsetattrlist(clone, &al, (void *)&st->st_birthtimespec,
			 sizeof(st->st_birthtimespec), 0) ||
	    futimens(clone, times) || fstat(clone, &actual) ||
	    actual.st_mode != st->st_mode || actual.st_uid != st->st_uid ||
	    actual.st_gid != st->st_gid || actual.st_flags != st->st_flags ||
	    actual.st_atimespec.tv_sec != times[0].tv_sec ||
	    actual.st_atimespec.tv_nsec != times[0].tv_nsec ||
	    actual.st_mtimespec.tv_sec != times[1].tv_sec ||
	    actual.st_mtimespec.tv_nsec != times[1].tv_nsec ||
	    actual.st_birthtimespec.tv_sec != st->st_birthtimespec.tv_sec ||
	    actual.st_birthtimespec.tv_nsec != st->st_birthtimespec.tv_nsec ||
	    !same_xattrs(target, clone))
		goto out;
	errno = 0;
	a = acl_get_fd_np(target, ACL_TYPE_EXTENDED);
	aerr = errno;
	errno = 0;
	b = acl_get_fd_np(clone, ACL_TYPE_EXTENDED);
	berr = errno;
	if (!a || !b) {
		if (!a && !b && aerr == ENOENT && berr == ENOENT)
			ret = 0;
		goto out;
	}
	if (!(at = acl_to_text(a, NULL)) || !(bt = acl_to_text(b, NULL)) ||
	    strcmp(at, bt))
		goto out;
	ret = 0;
out:
	acl_free(a);
	acl_free(b);
	acl_free(at);
	acl_free(bt);
	return ret;
}
#define RESHARE_BACKEND "clone-replace"
#else
#define RESHARE_BACKEND "native-dedupe"
#endif

static void reshare_path(const struct reflink_reshare_options *opts,
			 const char *path, const struct reshare_result *result)
{
	char term = opts->nul_termination ? '\0' : '\n';

	if (opts->quiet)
		return;
	if (opts->porcelain) {
		fputs("path ", stdout);
		write_name_quoted(path, stdout, term);
		printf("status %s%creason %s%c", result->status, term,
		       result->reason, term);
		if (result->before_known)
			printf("allocated-before %"PRIuMAX"%cprivate-before %"PRIuMAX"%c",
			       result->before.allocated, term,
			       result->before.private_bytes, term);
		else
			printf("allocated-before unknown%cprivate-before unknown%c", term, term);
		if (result->after_known)
			printf("allocated-after %"PRIuMAX"%cprivate-after %"PRIuMAX"%c",
			       result->after.allocated, term,
			       result->after.private_bytes, term);
		else
			printf("allocated-after unknown%cprivate-after unknown%c", term, term);
		printf("deduplicated-range-bytes %"PRIuMAX"%c%c",
		       result->deduplicated, term, term);
	} else if (opts->verbose) {
		printf("%s (%s): ", result->status, result->reason);
		write_name_quoted(path, stdout, '\n');
	}
}

static void reshare_summary(struct repository *r,
			    const struct reflink_reshare_options *opts,
			    const struct reshare_totals *total)
{
	uintmax_t reduction = total->private_before > total->private_after ?
		total->private_before - total->private_after : 0;
	char term = opts->nul_termination ? '\0' : '\n';

#define RESHARE_COUNT(name, value) do { \
	trace2_data_intmax("reflink-reshare", r, name, value); \
	if (!opts->quiet && opts->porcelain) \
		printf("%s %"PRIuMAX"%c", name, (uintmax_t)(value), term); \
} while (0)
	if (!opts->quiet && opts->porcelain)
		printf("summary%c", term);
	RESHARE_COUNT("scanned", total->scanned);
	RESHARE_COUNT("eligible", total->eligible);
	RESHARE_COUNT("already-shared", total->already_shared);
	RESHARE_COUNT("reshared", total->reshared);
	RESHARE_COUNT("skipped", total->skipped);
	RESHARE_COUNT("failed", total->failed);
	RESHARE_COUNT("allocated-before", total->allocated_before);
	RESHARE_COUNT("allocated-after", total->allocated_after);
	RESHARE_COUNT("private-before", total->private_before);
	RESHARE_COUNT("private-after", total->private_after);
	RESHARE_COUNT("observed-private-reduction", reduction);
	RESHARE_COUNT("potential-private-reduction", total->potential_private);
	RESHARE_COUNT("deduplicated-range-bytes", total->deduplicated);
	RESHARE_COUNT("allocation-unknown", total->allocation_unknown);
	RESHARE_COUNT("stat-clean", total->stat_clean);
	RESHARE_COUNT("content-checked", total->content_checked);
	RESHARE_COUNT("content-check-bytes", total->content_check_bytes);
	RESHARE_COUNT("userspace-compared", total->userspace_compared);
	RESHARE_COUNT("native-attempts", total->native_attempts);
	RESHARE_COUNT("native-range-bytes", total->native_range_bytes);
	RESHARE_COUNT("clone-attempts", total->clone_attempts);
	RESHARE_COUNT("comparison-bytes", total->comparison_bytes);
#undef RESHARE_COUNT
	if (!opts->quiet && opts->porcelain)
		putchar(term);
	else if (!opts->quiet)
		printf(_("reflink: scanned %"PRIuMAX", eligible %"PRIuMAX", "
			 "already shared %"PRIuMAX", re-shared %"PRIuMAX", "
			 "skipped %"PRIuMAX", failed %"PRIuMAX"\n"
			 "observed private allocation reduction: %"PRIuMAX" bytes; "
			 "dry-run potential: %"PRIuMAX" bytes; "
			 "unknown allocation: %"PRIuMAX" paths\n"),
		       total->scanned, total->eligible, total->already_shared,
		       total->reshared, total->skipped, total->failed,
		       reduction, total->potential_private, total->allocation_unknown);
}

/* A deterministic hook for concurrent-write/path-replacement regressions. */
static void reshare_test_hook(const struct cache_entry *ce)
{
	const char *hook = getenv("GIT_TEST_REFLINK_RESHARE_HOOK");
	struct child_process cmd = CHILD_PROCESS_INIT;

	if (!hook)
		return;
	cmd.use_shell = 1;
	strvec_push(&cmd.args, hook);
	strvec_push(&cmd.args, ce->name);
	if (run_command(&cmd))
		die("GIT_TEST_REFLINK_RESHARE_HOOK failed");
}

int reflink_reshare_worktree(struct repository *r,
			     const struct reflink_reshare_options *opts)
{
	struct reshare_totals total = { 0 };
	struct strbuf path = STRBUF_INIT, donor = STRBUF_INIT;
	struct lock_file index_lock = LOCK_INIT;
	int index_locked = 0;
	int root_fd, root_supported;
	char term = opts->nul_termination ? '\0' : '\n';

	if (!r->worktree || !r->gitdir)
		return error(_("reflink requires a working tree"));
	if (!rc.initialized)
		init_reflink(r);
	if (rc.repo != r)
		return error(_("reflink repository context changed"));
	if (opts->source) {
		struct strbuf spec = STRBUF_INIT;

		if (reflink_source_spec(r, NULL, opts->source, &spec))
			return error(_("unknown reflink source '%s'"), opts->source);
		if (rc.source_resolved)
			BUG("reflink source overridden after lookup");
		free(rc.marker);
		rc.marker = strbuf_detach(&spec, NULL);
	}
	root_fd = open(r->worktree, O_RDONLY | O_NONBLOCK);
	root_supported = root_fd >= 0 && can_dedupe_file_data(root_fd);
#ifdef __APPLE__
	root_supported = path_fs_can_clone(r->worktree);
#endif
	if (root_fd >= 0)
		close(root_fd);
	trace2_region_enter("reflink-reshare", "worktree", r);
	rc.resharing = 1;
	trace2_data_string("reflink-reshare", r, "backend",
			   root_supported ? RESHARE_BACKEND : "unsupported");
	/* Hard reset must retain its ordinary result on unsupported systems. */
	if (opts->quiet && !root_supported)
		goto done;
	setup_work_tree(r);
#ifdef __APPLE__
	if (root_supported && !opts->dry_run) {
		if (repo_hold_locked_index(r, &index_lock, 0) < 0) {
			error_errno(_("cannot lock index for reflink metadata update"));
			total.failed++;
			goto done;
		}
		index_locked = 1;
	}
#endif
	if (repo_read_index(r) < 0) {
		error(_("index file corrupt"));
		total.failed++;
		goto done;
	}
	if (!rc.source_resolved)
		resolve_source(r);
	if (!opts->quiet && opts->porcelain) {
		printf("reflink 1%cworktree ", term);
		write_name_quoted(r->worktree, stdout, term);
		printf("dry-run %d%cbackend %s%c%c", !!opts->dry_run, term,
		       root_supported ? RESHARE_BACKEND : "unsupported", term, term);
	}
	for (size_t i = 0; i < r->index->cache_nr; i++) {
		struct cache_entry *ce = r->index->cache[i];
		const struct cache_entry *source_ce = NULL;
		struct reshare_result result = { .status = "skipped", .reason = "ineligible" };
		struct stat before, after, source_before, source_after, named;
		struct conv_attrs ca;
		struct object_id oid;
		int fd = -1, src_fd = -1, write_fd = -1, hash_fd, ret, changed;
		int noatime = 0;
#ifdef __APPLE__
		struct strbuf tempdir = STRBUF_INIT, clone_path = STRBUF_INIT;
		struct tempfile *clone_temp = NULL;
		int clone_fd = -1;
#else
		int dedupe_error;
#endif

#if defined(__linux__) && defined(O_NOATIME)
		noatime = O_NOATIME;
#endif
		total.scanned++;
		if (ce_stage(ce) || !S_ISREG(ce->ce_mode) ||
		    (ce->ce_flags & (CE_SKIP_WORKTREE | CE_INTENT_TO_ADD | CE_REMOVE))) {
			result.reason = "index-entry";
			goto record;
		}
		strbuf_reset(&path);
		strbuf_addf(&path, "%s/%s", r->worktree, ce->name);
		fd = open(path.buf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | noatime);
		if (fd < 0 || fstat(fd, &before) || !S_ISREG(before.st_mode)) {
			result.reason = "target-unavailable";
			goto record;
		}
		result.before_known = !get_file_data_usage(fd, &result.before);
		result.after = result.before;
		result.after_known = result.before_known;
		if (!before.st_size || (result.before_known && !result.before.allocated)) {
			result.reason = "no-allocation";
			goto record;
		}
		/* Metadata-only idempotence: no hash, conversion, clone or replace. */
		if (result.before_known && !result.before.private_bytes) {
			result.status = "already-shared";
			result.reason = "fully-shared";
			total.already_shared++;
			goto record;
		}
		if (!root_supported
#ifndef __APPLE__
		    || !can_dedupe_file_data(fd)
#endif
		   ) {
			result.reason = "unsupported-safe-dedupe";
			goto record;
		}
		if (!result.before_known) {
			result.reason = "allocation-unknown";
			goto record;
		}
		if (before.st_nlink != 1) {
			result.reason = "hardlinked-target";
			goto record;
		}
#ifdef __APPLE__
		if (before.st_flags || (before.st_mode & (S_ISUID | S_ISGID))) {
			result.reason = "special-metadata";
			goto record;
		}
#endif
		changed = ie_match_stat(r->index, ce, &before,
			CE_MATCH_IGNORE_VALID | CE_MATCH_IGNORE_SKIP_WORKTREE |
			CE_MATCH_IGNORE_FSMONITOR | CE_MATCH_RACY_IS_DIRTY);
		/* Match ie_modified(): known size changes resolve dirty eligibility. */
		if ((changed & (MODE_CHANGED | TYPE_CHANGED)) ||
		    ((match_stat_data(&ce->ce_stat_data, &before) & DATA_CHANGED) &&
		     ce->ce_stat_data.sd_size)) {
			result.reason = "target-dirty";
			goto record;
		}
		src_fd = open_donor(r, ce, &donor, &source_ce, DONOR_IN_PLACE);
		if (src_fd < 0 || fstat(src_fd, &source_before)) {
			result.reason = "no-donor";
			goto record;
		}
		if (source_before.st_dev != before.st_dev) {
			result.reason = "different-filesystem";
			goto record;
		}
		if (source_before.st_ino == before.st_ino ||
		    source_before.st_size != before.st_size) {
			result.reason = "representation-differs";
			goto record;
		}
		if (changed) {
			/* Ordinary Git would content-check this stat/racy ambiguity. */
			convert_attrs(r->index, &ca, ce->name);
			if (ca.drv || ca.working_tree_encoding) {
				result.reason = "conversion-unsupported";
				goto record;
			}
			hash_fd = dup(fd);
			if (hash_fd < 0) {
				result.status = "failed";
				result.reason = "descriptor-error";
				goto record;
			}
			total.content_checked++;
			total.content_check_bytes += before.st_size;
			if (index_fd(r->index, &oid, hash_fd, &before, OBJ_BLOB, ce->name, 0) ||
			    !oideq(&oid, &ce->oid)) {
				result.reason = "target-dirty";
				goto record;
			}
			if (fstat(fd, &after) || !same_file_stat(&before, &after)) {
				result.reason = "target-changed";
				goto record;
			}
		} else {
			/* No hash, object read, attribute lookup or filter invocation. */
			total.stat_clean++;
		}

		if (opts->dry_run) {
			total.userspace_compared++;
			total.comparison_bytes += 2 * (uintmax_t)before.st_size;
			ret = same_fd_bytes(src_fd, fd, before.st_size);
			if (ret != 1) {
				result.reason = ret ? "read-error" : "representation-differs";
				goto record;
			}
			if (fstat(fd, &after) || !same_file_stat(&before, &after) ||
			    fstat(src_fd, &source_after) ||
			    donor_changed(rc.source_index, source_ce, &source_after) ||
			    lstat(path.buf, &named) || named.st_dev != before.st_dev ||
			    named.st_ino != before.st_ino) {
				result.reason = "concurrent-change";
				goto record;
			}
			total.eligible++;
			total.potential_private += result.before.private_bytes;
			result.status = "eligible";
			result.reason = "dry-run-estimate";
			goto record;
		}
#ifdef __APPLE__
		/* A private directory gives clonefile an absent, unguessable pathname. */
		strbuf_add(&tempdir, path.buf, strrchr(path.buf, '/') - path.buf);
		strbuf_addstr(&tempdir, "/.git-reflink-XXXXXX");
		if (!mkdtemp(tempdir.buf)) {
			result.status = "failed";
			result.reason = "temporary-directory-error";
			goto record;
		}
		strbuf_addf(&clone_path, "%s/file", tempdir.buf);
		total.clone_attempts++;
		clone_fd = clone_fd_to_file(src_fd, clone_path.buf, before.st_mode);
		if (clone_fd < 0) {
			result.reason = "clone-failed";
			goto record;
		}
		clone_temp = register_tempfile(clone_path.buf);
		total.userspace_compared++;
		total.comparison_bytes += 2 * (uintmax_t)before.st_size;
		ret = same_fd_bytes(clone_fd, fd, before.st_size);
		if (ret != 1) {
			result.reason = ret ? "read-error" : "representation-differs";
			goto record;
		}
		if (preserve_reshare_metadata(fd, clone_fd, &before)) {
			result.reason = "metadata-unavailable";
			goto record;
		}
		reshare_test_hook(ce);
		if (fstat(fd, &after) || !same_file_stat(&before, &after) ||
		    lstat(path.buf, &named) || !same_file_stat(&before, &named) ||
		    fstat(src_fd, &source_after) ||
		    donor_changed(rc.source_index, source_ce, &source_after)) {
			result.reason = "concurrent-change";
			goto record;
		}
		if (rename_tempfile(&clone_temp, path.buf)) {
			result.status = "failed";
			result.reason = "replace-failed";
			goto record;
		}
		result.after_known = !get_file_data_usage(clone_fd, &result.after);
		if (fstat(clone_fd, &after) || lstat(path.buf, &named) ||
		    !same_file_stat(&after, &named)) {
			result.status = "failed";
			result.reason = "replacement-changed";
			goto record;
		}
		/* Use checkout's normal bookkeeping with the new file's real stat. */
		{
			struct checkout state = CHECKOUT_INIT;
			state.istate = r->index;
			state.refresh_cache = 1;
			update_ce_after_write(&state, ce, &after);
		}
		total.eligible++;
		result.deduplicated = before.st_size;
#else
		write_fd = open(path.buf, O_RDWR | O_NOFOLLOW | O_NONBLOCK | noatime);
		if (write_fd < 0 || fstat(write_fd, &after) || !same_file_stat(&before, &after)) {
			result.reason = "target-unavailable";
			goto record;
		}
		reshare_test_hook(ce);
		/* FIDEDUPERANGE compares under kernel locks; never imports unequal bytes. */
		total.native_attempts++;
		total.native_range_bytes += before.st_size;
		ret = dedupe_file_data(src_fd, write_fd, before.st_size, &result.deduplicated);
		dedupe_error = errno;
		result.after_known = !get_file_data_usage(write_fd, &result.after);
		if (ret == 1 && !result.deduplicated) {
			result.reason = "representation-differs";
			goto record;
		}
		if (ret < 0 && !result.deduplicated) {
			result.reason = "native-dedupe-failed";
			if (!clone_unsupported(dedupe_error) &&
			    dedupe_error != EINVAL && dedupe_error != EBADF)
				result.status = "failed";
			goto record;
		}
		total.eligible++;
		if (fstat(write_fd, &after) || lstat(path.buf, &named) ||
		    !same_file_stat(&before, &after) ||
		    named.st_dev != before.st_dev || named.st_ino != before.st_ino ||
		    fstat(src_fd, &source_after) ||
		    donor_changed(rc.source_index, source_ce, &source_after)) {
			result.reason = "concurrent-change";
			goto record;
		}
#endif
		result.status = "reshared";
		result.reason = result.after_known && !result.after.private_bytes ?
			"fully-shared" : "partially-shared";
		total.reshared++;
record:
#ifdef __APPLE__
		if (clone_fd >= 0)
			close(clone_fd);
		delete_tempfile(&clone_temp);
		if (tempdir.len)
			rmdir(tempdir.buf);
		strbuf_release(&clone_path);
		strbuf_release(&tempdir);
#endif
		if (!strcmp(result.status, "skipped"))
			total.skipped++;
		else if (!strcmp(result.status, "failed"))
			total.failed++;
		if (result.before_known && result.after_known) {
			total.allocated_before += result.before.allocated;
			total.allocated_after += result.after.allocated;
			total.private_before += result.before.private_bytes;
			total.private_after += result.after.private_bytes;
		} else if (S_ISREG(ce->ce_mode)) {
			total.allocation_unknown++;
		}
		total.deduplicated += result.deduplicated;
		reshare_path(opts, ce->name, &result);
		if (fd >= 0)
			close(fd);
		if (write_fd >= 0)
			close(write_fd);
		if (src_fd >= 0)
			close(src_fd);
	}
done:
	rc.resharing = 0;
	if (index_locked && write_locked_index(r->index, &index_lock,
					    COMMIT_LOCK | SKIP_IF_UNCHANGED)) {
		error(_("could not record reflink replacement metadata in index"));
		total.failed++;
	}
	reshare_summary(r, opts, &total);
	trace2_region_leave("reflink-reshare", "worktree", r);
	strbuf_release(&path);
	strbuf_release(&donor);
	return !!total.failed;
}


#else

int reflink_checkout_enabled(struct repository *r UNUSED)
{
	return 0;
}

int reflink_reshare_worktree(struct repository *r UNUSED,
			     const struct reflink_reshare_options *opts)
{
	char term = opts->nul_termination ? '\0' : '\n';

	if (!opts->quiet && opts->porcelain)
		printf("reflink 1%cbackend unsupported%c%csummary%cscanned 0%c"
		       "eligible 0%calready-shared 0%creshared 0%cskipped 0%cfailed 0%c%c",
		       term, term, term, term, term, term, term, term, term, term, term);
	else if (!opts->quiet)
		printf(_("reflink: safe in-place deduplication is unsupported\n"));
	return 0;
}

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
