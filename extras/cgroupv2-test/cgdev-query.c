/*
 * cgdev-query.c -- prove that bpf_prog_query(BPF_CGROUP_DEVICE) works.
 *
 * runc calls exactly this before starting a container on a cgroup-v2 host:
 *
 *     bpf_prog_query(BPF_CGROUP_DEVICE) failed: invalid argument
 *
 * There is a control case (an attach type that is genuinely invalid) so an
 * EINVAL can never be read as success: if the control also returned EINVAL
 * the test would prove nothing.
 *
 * union bpf_attr is reproduced verbatim from this kernel's
 * include/uapi/linux/bpf.h -- it must NOT be taken from a modern libc header,
 * because fields added after 4.14 (batch, iter, link, btf...) shift the
 * offsets of everything that follows.
 *
 * Build: aarch64-linux-android24-clang -static -O2 -o cgdev-query cgdev-query.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <linux/types.h>	/* gives __u8/__u16/__u32/__u64, bionic already has them */

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
			__u32	map_id;
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

/* enum bpf_cmd: 16 consecutive commands before BPF_PROG_QUERY */
#define BPF_PROG_QUERY		16

/* enum bpf_attach_type */
#define BPF_CGROUP_INET_INGRESS		0
#define BPF_CGROUP_INET_EGRESS		1
#define BPF_CGROUP_INET_SOCK_CREATE	2
#define BPF_CGROUP_SOCK_OPS		3
#define BPF_CGROUP_DEVICE		6

#define BPF_F_QUERY_EFFECTIVE		(1u << 0)

static int bpf(int cmd, union bpf_attr *attr)
{
	return syscall(__NR_bpf, cmd, attr, sizeof(*attr));
}

static int query_dev(const char *what, int fd, __u32 attach_type, __u32 flags,
		     __u32 *ids, __u32 cnt)
{
	union bpf_attr attr;
	int r, e;

	memset(&attr, 0, sizeof(attr));
	attr.query.target_fd = (__u32)fd;
	attr.query.attach_type = attach_type;
	attr.query.query_flags = flags;
	attr.query.prog_ids = (__u64)(uintptr_t)ids;
	attr.query.prog_cnt = cnt;

	errno = 0;
	r = bpf(BPF_PROG_QUERY, &attr);
	e = errno;

	printf("  %-42s -> ret=%d errno=%d (%-14s) attach_flags=0x%x prog_cnt=%u\n",
	       what, r, e, strerror(e), attr.query.attach_flags,
	       attr.query.prog_cnt);
	return e;
}

int main(int argc, char **argv)
{
	const char *cg = argc > 1 ? argv[1] : "/sys/fs/cgroup";
	__u32 ids[8] = { 0 };
	int fd, e_dev, e_ctrl;

	printf("cgroup2 root: %s\n", cg);
	fd = open(cg, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0) {
		printf("FATAL: open(%s): %s\n", cg, strerror(errno));
		return 2;
	}
	printf("opened, fd=%d\n\n", fd);

	printf("--- the call runc makes ---\n");
	e_dev = query_dev("BPF_CGROUP_DEVICE, count only",
			  fd, BPF_CGROUP_DEVICE, BPF_F_QUERY_EFFECTIVE,
			  NULL, 0);

	printf("\n--- other real attach types (kernel must accept these too) ---\n");
	query_dev("BPF_CGROUP_INET_INGRESS", fd, BPF_CGROUP_INET_INGRESS,
		  BPF_F_QUERY_EFFECTIVE, NULL, 0);
	query_dev("BPF_CGROUP_SOCK_OPS", fd, BPF_CGROUP_SOCK_OPS,
		  BPF_F_QUERY_EFFECTIVE, NULL, 0);

	printf("\n--- with a prog_ids buffer, like runc asks for ---\n");
	query_dev("BPF_CGROUP_DEVICE, 8 slots",
		  fd, BPF_CGROUP_DEVICE, BPF_F_QUERY_EFFECTIVE, ids, 8);

	printf("\n--- CONTROL: genuinely invalid attach type (must be EINVAL) ---\n");
	e_ctrl = query_dev("attach_type=99 (invalid)",
			   fd, 99, BPF_F_QUERY_EFFECTIVE, NULL, 0);

	printf("\n--- CONTROL: genuinely invalid query_flags (must be EINVAL) ---\n");
	query_dev("query_flags=0x40 (invalid)",
		  fd, BPF_CGROUP_DEVICE, 0x40, NULL, 0);

	printf("\n==================================================\n");
	if (e_dev == 0 && e_ctrl == EINVAL) {
		printf("VERDICT: PASS -- BPF_CGROUP_DEVICE is supported and the\n"
		       "         command switch is discriminating (control got EINVAL).\n");
		return 0;
	}
	if (e_dev == EINVAL && e_ctrl == EINVAL) {
		printf("VERDICT: FAIL -- BPF_CGROUP_DEVICE returns EINVAL, same as a\n"
		       "         nonsense attach type. The command is not supported.\n");
		return 1;
	}
	printf("VERDICT: INCONCLUSIVE -- e_dev=%d (%s) e_ctrl=%d (%s)\n",
	       e_dev, strerror(e_dev), e_ctrl, strerror(e_ctrl));
	return 3;
}
