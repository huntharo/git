#include "git-compat-util.h"
#include "statinfo.h"
#include <sys/attr.h>

int has_unreliable_stat_data(const char *path, const struct stat *st)
{
#if defined(ATTR_CMN_GEN_COUNT) && defined(FSOPT_ATTR_CMN_EXTENDED)
	struct attrlist attrs = { 0 };
	struct {
		uint32_t length;
		attribute_set_t returned;
		uint32_t device;
		uint32_t generation;
		uint64_t inode;
	} result = { 0 };
	attrgroup_t wanted = ATTR_CMN_DEVID | ATTR_CMN_GEN_COUNT | ATTR_CMN_FILEID;
	int saved_errno = errno;
	int unreliable = 1;

	attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
	attrs.commonattr = ATTR_CMN_RETURNED_ATTRS | wanted;
	/*
	 * getattrlist(2) defines zero as an invalid write generation count.
	 * Shared mappings that can write to the file invalidate this count,
	 * even before their first store. This is vnode metadata: the mapper
	 * need not retain an open descriptor or be inspectable by this process.
	 *
	 * A failed query or an unsupported attribute cannot establish that
	 * stat data is reliable. Fall back to comparing the contents.
	 */
	if (!getattrlist(path, &attrs, &result, sizeof(result),
			 FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW) &&
	    result.length == sizeof(result) &&
	    (result.returned.commonattr & wanted) == wanted &&
	    result.generation &&
	    (!st || (result.device == (uint32_t)st->st_dev &&
		     result.inode == (uint64_t)st->st_ino)))
		unreliable = 0;

	errno = saved_errno;
	return unreliable;
#else
	/* Older SDKs cannot establish that stat data is reliable. */
	(void)path;
	(void)st;
	return 1;
#endif
}
