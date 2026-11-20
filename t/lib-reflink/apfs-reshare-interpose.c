/*
 * Test-only Darwin interposer, never linked into Git. Model kernel-owned
 * provenance independently on the two descriptors after real metadata copy.
 * Other faults damage the actual disposable clone, never the target.
 */
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <sys/acl.h>
#include <copyfile.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int target = -1, clone = -1;
static unsigned copies, lists, values;
static const char provenance[] = "com.apple.provenance";
static const char ordinary[] = "org.git-scm.reshare";

static int fault_is(const char *name)
{
	const char *fault = getenv("APFS_RESHARE_FAULT");
	return fault && !strcmp(fault, name);
}

static int copy_metadata(int from, int to, copyfile_state_t state,
			 copyfile_flags_t flags)
{
	int ret = fcopyfile(from, to, state, flags);

	if (ret || flags != COPYFILE_METADATA)
		return ret;

	target = from;
	clone = to;
	copies++;
	if (fault_is("value"))
		ret = fsetxattr(to, ordinary, "other", 5, 0, 0);
	else if (fault_is("size"))
		ret = fsetxattr(to, ordinary, "longer", 6, 0, 0);
	else if (fault_is("missing") || fault_is("rename")) {
		ret = fremovexattr(to, ordinary, 0);
		if (!ret && fault_is("rename"))
			ret = fsetxattr(to, "org.git-scm.renamed", "value", 5, 0, 0);
	} else if (fault_is("extra"))
		ret = fsetxattr(to, "org.git-scm.extra", "value", 5, 0, 0);
	else if (fault_is("quarantine") || fault_is("quarantine-value"))
		ret = fsetxattr(to, "com.apple.quarantine", "0081;0;other;", 13, 0, 0);
	else if (fault_is("quarantine-missing"))
		ret = fremovexattr(to, "com.apple.quarantine", 0);
	else if (fault_is("prefix"))
		ret = fsetxattr(to, "com.apple.provenance.test", "other", 5, 0, 0);
	else if (fault_is("mode"))
		ret = fchmod(to, 0600);
	else if (fault_is("acl")) {
		acl_t acl = acl_init(0);
		ret = acl ? acl_set_fd_np(to, acl, ACL_TYPE_EXTENDED) : -1;
		acl_free(acl);
	}
	if (ret) {
		perror("reshare oracle fault setup");
		_exit(99);
	}
	return 0;
}

/* Damage the timestamp after Git restores it, before its verification. */
static int set_times(int fd, const struct timespec times[2])
{
	struct timespec changed[2];
	if (fd != clone || !fault_is("mtime"))
		return futimens(fd, times);
	memcpy(changed, times, sizeof(changed));
	changed[1].tv_nsec ^= 1;
	return futimens(fd, changed);
}

static int has_provenance(int fd)
{
	const char *model = getenv("APFS_RESHARE_PROVENANCE");
	if (!model || !strcmp(model, "absent"))
		return 0;
	return !strcmp(model, "same") || !strcmp(model, "different") ||
	       (fd == target && !strcmp(model, "target-only")) ||
	       (fd == clone && !strcmp(model, "clone-only"));
}

static ssize_t list_attributes(int fd, char *buffer, size_t size, int options)
{
	ssize_t len, used = 0;
	char *names;

	if (fd != target && fd != clone)
		return flistxattr(fd, buffer, size, options);
	lists++;
	if (fd == clone && fault_is("list-error")) {
		errno = EIO;
		return -1;
	}
	len = flistxattr(fd, NULL, 0, options);
	if (len < 0)
		return len;
	names = malloc(len + sizeof(provenance));
	if (!names)
		_exit(99);
	if (flistxattr(fd, names, len, options) != len)
		_exit(99);
	for (ssize_t i = 0; i < len;) {
		size_t n = strlen(names + i) + 1;
		if (strcmp(names + i, provenance)) {
			memmove(names + used, names + i, n);
			used += n;
		}
		i += n;
	}
	if (has_provenance(fd)) {
		memcpy(names + used, provenance, sizeof(provenance));
		used += sizeof(provenance);
	}
	if (fd == clone && used && fault_is("malformed"))
		names[used - 1] = 'X';
	if (buffer && size >= (size_t)used)
		memcpy(buffer, names, used);
	free(names);
	if (buffer && size < (size_t)used) {
		errno = ERANGE;
		return -1;
	}
	return used;
}

static ssize_t get_attribute(int fd, const char *name, void *buffer, size_t size,
			     u_int32_t position, int options)
{
	const char *model = getenv("APFS_RESHARE_PROVENANCE");
	const char *value;

	if (fd != target && fd != clone)
		return fgetxattr(fd, name, buffer, size, position, options);
	if (fd == clone && fault_is("value-error") && !strcmp(name, ordinary)) {
		errno = EIO;
		return -1;
	}
	if (strcmp(name, provenance))
		return fgetxattr(fd, name, buffer, size, position, options);
	values++;
	if (!has_provenance(fd)) {
		errno = ENOATTR;
		return -1;
	}
	value = fd == target || !strcmp(model, "same") ? "target" : "cloned";
	if (buffer && size < 6) {
		errno = ERANGE;
		return -1;
	}
	if (buffer)
		memcpy(buffer, value, 6);
	return 6;
}

__attribute__((destructor)) static void report(void)
{
	fprintf(stderr, "reshare-oracle %u %u %u\n", copies, lists, values);
}

__attribute__((used)) static struct {
	const void *replacement, *original;
} interpose[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)copy_metadata, (const void *)fcopyfile },
	{ (const void *)list_attributes, (const void *)flistxattr },
	{ (const void *)get_attribute, (const void *)fgetxattr },
	{ (const void *)set_times, (const void *)futimens }
};
