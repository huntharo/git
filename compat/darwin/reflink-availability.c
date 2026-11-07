/* Build-time probe; compile/link this program without executing it. */
#include <unistd.h>
#include <sys/attr.h>
#include <sys/clonefile.h>

int main(void)
{
	struct attrlist attrs = { 0 };

	attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
	attrs.forkattr = ATTR_CMNEXT_PRIVATESIZE;
	return fclonefileat(-1, -1, "", CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) ||
		fsetattrlist(-1, &attrs, &attrs, sizeof(attrs), 0);
}
