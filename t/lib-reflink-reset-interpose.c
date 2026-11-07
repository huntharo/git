/* Test-only Darwin interposer; never linked into Git. */
#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int publish_index(const char *from, const char *to)
{
	const char *index = getenv("GIT_TEST_REFLINK_INDEX");
	int ret = rename(from, to);

	if (!ret && index && !strcmp(to, index)) {
		const char *git = getenv("GIT_TEST_REFLINK_GIT");
		pid_t child;
		int status;

		/* Only the first publication: the second belongs to repair. */
		unsetenv("GIT_TEST_REFLINK_INDEX");
		child = fork();
		if (!child) {
			unsetenv("DYLD_INSERT_LIBRARIES");
			execl(git, git, "add", "staged", (char *)NULL);
			_exit(98);
		}
		if (child < 0)
			_exit(97);
		while (waitpid(child, &status, 0) < 0) {
			if (errno != EINTR)
				_exit(96);
		}
		if (!WIFEXITED(status) || WEXITSTATUS(status))
			_exit(95);
		fprintf(stderr, "cooperating git add completed\n");
	}
	return ret;
}

__attribute__((used)) static struct {
	const void *replacement, *original;
} interpose[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)publish_index, (const void *)rename }
};
