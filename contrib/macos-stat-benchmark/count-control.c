/* Known-input validation for count-io.c; not a benchmark. */
#define main mapper_main
#include "mapper.c"
#undef main

int main(int argc, char **argv)
{
	char data[128], *mapping;
	struct stat st;
	int fd;

	if (argc != 2)
		return 2;
	fd = open(argv[1], O_RDONLY);
	if (fd < 0 || fstat(fd, &st) ||
	    read(fd, data, sizeof(data)) != sizeof(data) ||
	    pread(fd, data, 64, 0) != 64)
		fail("control read/pread");
	mapping = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (mapping == MAP_FAILED || close(fd) || munmap(mapping, st.st_size))
		fail("control mmap/close/unmap");
	printf("%u\n", generation(argv[1]));
	return 0;
}
