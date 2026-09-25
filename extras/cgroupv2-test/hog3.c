/*
 * hog3 -- allocate memory that the compiler is not allowed to optimise away.
 *
 * Build: aarch64-linux-android24-clang -O2 -o hog3 hog3.c
 * Run  : hog3 <megabytes> [microseconds-per-MB]
 *
 * Why this exists: hog2 wrote each buffer with memset() and never read it back.
 * At -O2 that is a dead store, and clang deleted it -- the process "allocated"
 * 192 MB while its own VmRSS stayed at 2.6 MB. Every cgroup measurement taken
 * against it was measuring an empty process.
 *
 * The stores here go through a volatile pointer and the result is folded into a
 * value that gets printed, so neither the allocation nor the stores can be
 * removed. Sanity-check it: with no limit, VmRSS must climb to about the target.
 *
 * Exit: 0 reached target, 2 malloc failed, 137 SIGKILL from the memcg OOM killer.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define CHUNK (1024 * 1024)

int main(int argc, char **argv)
{
	long target_mb = argc > 1 ? atol(argv[1]) : 512;
	long delay_us = argc > 2 ? atol(argv[2]) : 0;
	unsigned long sink = 0;
	long i, j;

	setvbuf(stdout, NULL, _IOLBF, 0);
	printf("hog3: pid=%d target=%ld MB delay=%ld us/MB\n",
	       (int)getpid(), target_mb, delay_us);

	for (i = 0; i < target_mb; i++) {
		unsigned char *p = malloc(CHUNK);
		volatile unsigned char *vp;

		if (!p) {
			printf("hog3: malloc failed at %ld MB\n", i);
			return 2;
		}
		vp = p;
		/* volatile stores: these cannot be elided */
		for (j = 0; j < CHUNK; j += 4096)
			vp[j] = (unsigned char)(0x5a ^ (j & 0xff));
		/* and read one back, so the buffer is genuinely live */
		sink += vp[i & 4095];

		if (delay_us > 0)
			usleep((useconds_t)delay_us);
		if (i % 16 == 15)
			printf("hog3: %ld MB\n", i + 1);
	}

	printf("hog3: reached the full %ld MB (sink=%lu) - no limit was hit\n",
	       target_mb, sink);
	sleep(10);	/* hold the memory so the accounting can be read */
	return 0;
}
