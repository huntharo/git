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
#include "statinfo.h"
#include "strbuf.h"
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
	/* always clone from a wrong scratch donor: verification must fail */
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
	dev_t source_dev;	/* st_dev of the reflink source's top */
	struct index_state *source_index;
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
	 * now, before reading its index or trying a single clone.
	 */
	if (src && same_clone_filesystem(src->path, r->worktree) &&
	    path_fs_can_clone(src->path)) {
		struct stat st;

		if (!stat(src->path, &st))
			rc.source_dev = st.st_dev;
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

/* Is the open file "fd" exactly the blob "oid"? */
static int fd_matches_blob(struct repository *r, int fd,
			   const struct object_id *oid)
{
	/*
	 * Collision detection buys nothing here: this is a second-preimage
	 * check against an object we already trust.
	 */
	const struct git_hash_algo *algo = unsafe_hash_algo(r->hash_algo);
	char hdr[MAX_HEADER_LEN];
	static char buf[64 * 1024];
	struct git_hash_ctx ctx;
	struct object_id got;
	struct stat st;
	off_t left;
	int hdrlen;

	if (fstat(fd, &st) || !S_ISREG(st.st_mode))
		return 0;
	hdrlen = format_object_header(hdr, sizeof(hdr), OBJ_BLOB, st.st_size);
	git_hash_init(&ctx, algo);
	git_hash_update(&ctx, hdr, hdrlen);
	for (left = st.st_size; left > 0; ) {
		ssize_t n = xread(fd, buf, left < (off_t)sizeof(buf) ?
				  (size_t)left : sizeof(buf));
		if (n <= 0) {
			git_hash_discard(&ctx);
			return 0;
		}
		git_hash_update(&ctx, buf, n);
		left -= n;
	}
	/* nor may it have grown */
	if (xread(fd, buf, 1) != 0) {
		git_hash_discard(&ctx);
		return 0;
	}
	git_hash_final_oid(&got, &ctx);
	return !memcmp(got.hash, oid->hash, r->hash_algo->rawsz);
}

/*
 * Phase one: find a file in the reflink source that, as far as its
 * index knows, holds the blob of "ce" unmodified. Returns a descriptor
 * open on it, or -1.
 */
static int open_donor(struct repository *r, const struct cache_entry *ce,
		      struct strbuf *donor)
{
	struct index_state *src = source_index(r);
	const struct cache_entry *sce;
	struct stat st;
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
	    match_stat_data(&sce->ce_stat_data, &st)) {
		close(fd);
		goto dirty;
	}
	/*
	 * A donor below a mount point inside the reflink source may be on
	 * a filesystem we cannot clone from: skip just that file, without
	 * trying.
	 */
	if (st.st_dev != rc.source_dev && !fd_fs_can_clone(fd)) {
		close(fd);
		count(TRACE2_COUNTER_ID_REFLINK_OTHER_FS);
		return -1;
	}
	return fd;

dirty:
	count(TRACE2_COUNTER_ID_REFLINK_SOURCE_DIRTY);
	return -1;
}

/*
 * Test mode: write the blob to a scratch file with deliberately unlike
 * metadata, so that every eligible file in the test suite goes through
 * cloning, metadata fix-ups and verification. Returns a descriptor on
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
	int src_fd = -1, fd, scratch = 0;

	if (!rc.initialized)
		init_reflink(r);
	if (!rc.enabled || r != rc.repo || !S_ISREG(ce->ce_mode) || !ca ||
	    !convert_to_working_tree_is_noop_ca(ca))
		return -1;

	if (rc.test != REFLINK_TEST_CORRUPT)
		src_fd = open_donor(r, ce, &donor);
	if (src_fd < 0) {
		if (!rc.test)
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
		 * A failure is about this one file. Only if the first 16
		 * attempts all fail does it say the filesystem cannot clone
		 * here at all (XFS without reflink, a nodatacow tree on
		 * btrfs, a kernel that refuses clones across mounts), and
		 * we stop trying. Once one clone has worked, we never stop.
		 */
		if (!rc.clones_ok && ++rc.clone_errors >= 16) {
			if (scratch)
				rc.scratch_unusable = 1;
			else
				rc.source_unusable = 1;
		}
		return -1;
	}
	close(src_fd);
	rc.clones_ok++;

	/*
	 * Phase two: make sure what we got is byte for byte what checkout
	 * would have written, whatever happened to the donor meanwhile.
	 */
	if (!fd_matches_blob(r, fd, &ce->oid)) {
		count(TRACE2_COUNTER_ID_REFLINK_VERIFY_FAILED);
		close(fd);
		unlink(path);
		return -1;
	}

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
