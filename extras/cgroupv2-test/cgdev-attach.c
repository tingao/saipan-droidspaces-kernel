/*
 * cgdev-attach.c -- prove the whole cgroup-v2 device-controller path, not just
 * the query: load a BPF_PROG_TYPE_CGROUP_DEVICE program, attach it to a cgroup
 * with BPF_CGROUP_DEVICE, and show that it actually decides whether a device
 * can be opened.
 *
 * This is what runc does when it sets up a container on a cgroup-v2 host:
 *   1. bpf(BPF_PROG_LOAD, prog_type=BPF_PROG_TYPE_CGROUP_DEVICE, ...)
 *   2. bpf(BPF_PROG_ATTACH, attach_type=BPF_CGROUP_DEVICE, target_fd=<cgroup>)
 *   3. the kernel consults the program on every device open/mknod
 *
 * Phases, each one a control for the next:
 *   0. open /dev/null before anything is attached      -> must succeed
 *   1. attach an "allow" program                       -> must still succeed
 *   2. replace it with a "deny" program                -> must now FAIL EPERM
 *   3. detach                                           -> must succeed again
 *
 * Phase 2 is the one that matters: an EPERM there can only come from the
 * attached program, so it proves enforcement rather than mere acceptance.
 *
 * Everything happens in a scratch cgroup, and the process moves itself back to
 * the root cgroup before cleanup, so nothing else on the phone is affected.
 *
 * Build: aarch64-linux-android24-clang -O2 -Wall -o cgdev-attach cgdev-attach.c
 * Run:   cgdev-attach [cgroup2-mount]        (needs CAP_NET_ADMIN + root)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <linux/types.h>

union bpf_attr {
	struct { /* BPF_MAP_CREATE */
		__u32	map_type;
		__u32	key_size;
		__u32	value_size;
		__u32	max_entries;
		__u32	map_flags;
		__u32	inner_map_fd;
		__u32	numa_node;
	};
	struct { /* BPF_MAP_*_ELEM */
		__u32		map_fd;
		__aligned_u64	key;
		union {
			__aligned_u64 value;
			__aligned_u64 next_key;
		};
		__u64		flags;
	};
	struct { /* BPF_PROG_LOAD */
		__u32		prog_type;
		__u32		insn_cnt;
		__aligned_u64	insns;
		__aligned_u64	license;
		__u32		log_level;
		__u32		log_size;
		__aligned_u64	log_buf;
		__u32		kern_version;
		__u32		prog_flags;
	};
	struct { /* BPF_OBJ_* */
		__aligned_u64	pathname;
		__u32		bpf_fd;
		__u32		file_flags;
	};
	struct { /* BPF_PROG_ATTACH/DETACH */
		__u32		target_fd;
		__u32		attach_bpf_fd;
		__u32		attach_type;
		__u32		attach_flags;
	};
	struct { /* BPF_PROG_TEST_RUN */
		__u32		prog_fd;
		__u32		retval;
		__u32		data_size_in;
		__u32		data_size_out;
		__aligned_u64	data_in;
		__aligned_u64	data_out;
		__u32		repeat;
		__u32		duration;
	} test;
	struct { /* BPF_*_GET_*_ID */
		union {
			__u32	start_id;
			__u32	prog_id;
			__u32		map_id;
		};
		__u32	next_id;
		__u32	open_flags;
	};
	struct { /* BPF_OBJ_GET_INFO_BY_FD */
		__u32		bpf_fd;
		__u32		info_len;
		__aligned_u64	info;
	} info;
	struct { /* BPF_PROG_QUERY */
		__u32		target_fd;
		__u32		attach_type;
		__u32		query_flags;
		__u32		attach_flags;
		__aligned_u64	prog_ids;
		__u32		prog_cnt;
	} query;
} __attribute__((aligned(8)));

struct bpf_insn {
	__u8	code;
	__u8	dst_reg:4;
	__u8	src_reg:4;
	__s16	off;
	__s32	imm;
};

#define BPF_PROG_LOAD		5
#define BPF_PROG_ATTACH		8
#define BPF_PROG_DETACH		9
#define BPF_PROG_QUERY		16

#define BPF_PROG_TYPE_CGROUP_DEVICE	15
#define BPF_CGROUP_DEVICE		6
#define BPF_F_QUERY_EFFECTIVE		(1u << 0)

#define BPF_ALU64	0x07
#define BPF_MOV		0xb0
#define BPF_K		0x00
#define BPF_JMP		0x05
#define BPF_EXIT	0x90
#define BPF_REG_0	0

static char logbuf[8192];

static int bpf(int cmd, union bpf_attr *attr)
{
	return syscall(__NR_bpf, cmd, attr, sizeof(*attr));
}

/* a device-cgroup program that returns @ret (1 = allow, 0 = deny) */
static int load_dev_prog(int ret)
{
	struct bpf_insn insns[2];
	union bpf_attr attr;
	int fd;

	memset(insns, 0, sizeof(insns));
	insns[0].code = BPF_ALU64 | BPF_MOV | BPF_K;
	insns[0].dst_reg = BPF_REG_0;
	insns[0].imm = ret;
	insns[1].code = BPF_JMP | BPF_EXIT;

	memset(&attr, 0, sizeof(attr));
	attr.prog_type = BPF_PROG_TYPE_CGROUP_DEVICE;
	attr.insn_cnt = 2;
	attr.insns = (__u64)(uintptr_t)insns;
	attr.license = (__u64)(uintptr_t)"GPL";
	attr.log_level = 1;
	attr.log_size = sizeof(logbuf);
	attr.log_buf = (__u64)(uintptr_t)logbuf;

	memset(logbuf, 0, sizeof(logbuf));
	errno = 0;
	fd = bpf(BPF_PROG_LOAD, &attr);
	if (fd < 0)
		printf("      verifier log:\n%s\n", logbuf);
	return fd;
}

static int attach_prog(int cgrp_fd, int prog_fd)
{
	union bpf_attr attr;

	memset(&attr, 0, sizeof(attr));
	attr.target_fd = (__u32)cgrp_fd;
	attr.attach_bpf_fd = (__u32)prog_fd;
	attr.attach_type = BPF_CGROUP_DEVICE;
	attr.attach_flags = 0;
	return bpf(BPF_PROG_ATTACH, &attr);
}

static int detach_prog(int cgrp_fd, int prog_fd)
{
	union bpf_attr attr;

	memset(&attr, 0, sizeof(attr));
	attr.target_fd = (__u32)cgrp_fd;
	attr.attach_bpf_fd = (__u32)prog_fd;
	attr.attach_type = BPF_CGROUP_DEVICE;
	return bpf(BPF_PROG_DETACH, &attr);
}

static __u32 query_count(int cgrp_fd)
{
	union bpf_attr attr;

	memset(&attr, 0, sizeof(attr));
	attr.query.target_fd = (__u32)cgrp_fd;
	attr.query.attach_type = BPF_CGROUP_DEVICE;
	attr.query.query_flags = BPF_F_QUERY_EFFECTIVE;
	attr.query.prog_cnt = 0;
	if (bpf(BPF_PROG_QUERY, &attr) < 0)
		return 0xffffffffu;
	return attr.query.prog_cnt;
}

/* returns 0 if the device could be opened, else errno */
static int try_open(const char *path, int write)
{
	int fd = open(path, write ? O_RDWR : O_RDONLY);

	if (fd < 0)
		return errno;
	close(fd);
	return 0;
}

static void move_self(const char *cgpath)
{
	int fd = open(cgpath, O_WRONLY);
	char pid[32];

	if (fd < 0) {
		printf("      (could not open %s: %s)\n", cgpath, strerror(errno));
		return;
	}
	snprintf(pid, sizeof(pid), "%d", getpid());
	if (write(fd, pid, strlen(pid)) < 0)
		printf("      (could not move into %s: %s)\n", cgpath, strerror(errno));
	close(fd);
}

static int fail;
static void check(const char *what, int got, int want)
{
	int ok = (got == want);

	if (!ok)
		fail = 1;
	printf("    [%s] %-46s got %-3d (%s) want %d\n", ok ? "OK" : "BAD",
	       what, got, strerror(got), want);
}

int main(int argc, char **argv)
{
	const char *mnt = argc > 1 ? argv[1] : "/sys/fs/cgroup";
	char scratch[512], procs[512], rootprocs[512];
	int cgfd, allow_fd, deny_fd, r;

	printf("cgroup2 mount: %s\n\n", mnt);
	snprintf(scratch, sizeof(scratch), "%s/cgdev-attach-test", mnt);
	snprintf(procs, sizeof(procs), "%s/cgroup.procs", scratch);
	snprintf(rootprocs, sizeof(rootprocs), "%s/cgroup.procs", mnt);

	/* --- phase 0: baseline, nothing attached --- */
	printf("--- phase 0: baseline (no program attached) ---\n");
	r = try_open("/dev/null", 0);
	check("open /dev/null", r, 0);
	printf("    effective prog count: %u\n", query_count(open(mnt, O_RDONLY|O_DIRECTORY)));

	/* --- scratch cgroup --- */
	if (mkdir(scratch, 0755) < 0 && errno != EEXIST) {
		printf("FATAL: mkdir %s: %s\n", scratch, strerror(errno));
		return 2;
	}
	cgfd = open(scratch, O_RDONLY | O_DIRECTORY);
	if (cgfd < 0) {
		printf("FATAL: open %s: %s\n", scratch, strerror(errno));
		return 2;
	}
	move_self(procs);
	printf("    moved self into %s\n", scratch);

	/* --- phase 1: allow program --- */
	printf("\n--- phase 1: attach ALLOW program (returns 1) ---\n");
	allow_fd = load_dev_prog(1);
	if (allow_fd < 0) {
		printf("    [BAD] BPF_PROG_LOAD(CGROUP_DEVICE, allow) failed: %s\n",
		       strerror(errno));
		fail = 1;
	} else {
		printf("    [OK] loaded allow program, fd=%d\n", allow_fd);
		if (attach_prog(cgfd, allow_fd) < 0) {
			printf("    [BAD] BPF_PROG_ATTACH failed: %s\n", strerror(errno));
			fail = 1;
		} else {
			printf("    [OK] attached to %s\n", scratch);
		}
		printf("    effective prog count now: %u (want 1)\n",
		       query_count(cgfd));
		check("open /dev/null with ALLOW attached", try_open("/dev/null", 0), 0);
	}

	/* --- phase 2: deny program (the real proof) --- */
	printf("\n--- phase 2: replace with DENY program (returns 0) ---\n");
	deny_fd = load_dev_prog(0);
	if (deny_fd < 0) {
		printf("    [BAD] BPF_PROG_LOAD(CGROUP_DEVICE, deny) failed: %s\n",
		       strerror(errno));
		fail = 1;
	} else {
		printf("    [OK] loaded deny program, fd=%d\n", deny_fd);
		/* replace the single attached program (flags 0 = override) */
		if (attach_prog(cgfd, deny_fd) < 0) {
			printf("    [BAD] BPF_PROG_ATTACH(deny) failed: %s\n",
			       strerror(errno));
			fail = 1;
		} else {
			printf("    [OK] deny program now attached\n");
		}
		printf("    effective prog count now: %u (want 1)\n",
		       query_count(cgfd));
		r = try_open("/dev/null", 0);
		check("open /dev/null with DENY attached (must be EPERM)", r, EPERM);
		r = try_open("/dev/zero", 0);
		check("open /dev/zero with DENY attached (must be EPERM)", r, EPERM);
		/* a window into enforcement: this is the kernel actually running it */
		printf("    [%s] device access was actually refused by the program\n",
		       r == EPERM ? "OK" : "BAD");
		if (r != EPERM)
			fail = 1;
	}

	/* --- phase 3: detach --- */
	printf("\n--- phase 3: detach ---\n");
	move_self(rootprocs);
	if (deny_fd >= 0 && detach_prog(cgfd, deny_fd) < 0)
		printf("    detach(deny): %s\n", strerror(errno));
	if (allow_fd >= 0 && detach_prog(cgfd, allow_fd) < 0)
		printf("    detach(allow): %s\n", strerror(errno));
	printf("    effective prog count now: %u (want 0)\n", query_count(cgfd));
	check("open /dev/null after detach", try_open("/dev/null", 0), 0);

	if (allow_fd >= 0) close(allow_fd);
	if (deny_fd >= 0) close(deny_fd);
	close(cgfd);
	if (rmdir(scratch) < 0)
		printf("    (rmdir %s: %s)\n", scratch, strerror(errno));

	printf("\n==================================================\n");
	if (!fail)
		printf("VERDICT: PASS -- BPF_CGROUP_DEVICE loads, attaches, and ENFORCES.\n"
		       "         Device opens were refused only while the deny\n"
		       "         program was attached.\n");
	else
		printf("VERDICT: FAIL -- see the [BAD] lines above.\n");
	return fail;
}
