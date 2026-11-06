#ifndef REFLINK_CHECKOUT_H
#define REFLINK_CHECKOUT_H

/*
 * Copy-on-write ("reflink") checkout: when checkout is about to write a
 * regular file, clone it from another worktree of the same repository
 * (the "reflink source") instead, using its index's normal stat trust
 * model to select non-racy donors. EOL output additionally requires comparison
 * with the recipient's ordinary checkout output. See the limitations in
 * Documentation/technical/reflink-checkout.adoc.
 */

struct cache_entry;
struct checkout;
struct conv_attrs;
struct stat;
struct strbuf;

struct repository;

/*
 * Name of the per-worktree file (in the worktree's $GIT_DIR) that turns
 * reflink checkout on for that worktree, optionally naming its reflink
 * source.
 */
#define REFLINK_SOURCE_FILE "reflink-source"

/*
 * Try to create "path" for the regular-file entry "ce" by cloning it.
 * "ca" must be the conversion attributes for "ce". "path" must not exist.
 *
 * Returns 0 if "path" was cloned from an eligible donor, with the mode,
 * owner and timestamps of a newly written file. In that case
 * "*fstat_done" tells whether "*st" was filled
 * in from the new file, following the rules of fstat_checkout_output().
 *
 * Returns -1 if the entry was not cloned, for whatever reason (cloning
 * disabled, no reflink source, the reflink source does not hold this blob
 * or its stat data differs, the filesystem cannot clone, the donor
 * changed). Nothing is left at "path" and the caller must write the file
 * the ordinary way. No error is ever reported to the user.
 */
int reflink_checkout_entry(const struct cache_entry *ce,
			   const struct conv_attrs *ca,
			   const struct checkout *state,
			   const char *path,
			   struct stat *st, int *fstat_done);

/*
 * Compute the content of the reflink-source file naming the worktree
 * "arg" (a path or name, as for "git worktree move", relative to
 * "prefix"). With "arg" NULL, name the default reflink source: the main
 * worktree, or, if that is bare, the current worktree. Returns 0 and
 * fills "out", or -1 if there is no such worktree with a working tree.
 */
int reflink_source_spec(struct repository *r, const char *prefix,
			const char *arg, struct strbuf *out);

#endif /* REFLINK_CHECKOUT_H */
