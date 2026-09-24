#!/usr/bin/env python3
"""
Wire KernelSU-Next's MANUAL HOOKS into the kernel source.

Why manual hooks are required on this device:
  This is a 4.14 arm64 tree using the CLASSIC syscall ABI -- arch/arm64/kernel/sys.c does
      #undef  __SYSCALL
      #define __SYSCALL(nr, sym)  [nr] = sym,
  so sys_call_table points straight at sys_read/sys_execve/... . The pt_regs-based
  __arm64_sys_* wrappers that KernelSU's kprobe mode hooks (SYS_READ_SYMBOL =
  "__arm64_sys_read" ...) do not exist below 4.17. KernelSU-Next's own Kconfig agrees:
     KSU_KPROBES_HOOK       "This should not be used on kernel below 5.10."
     KSU_SYSCALL_TABLE_HOOK "Requires kernel >= 4.17 (pt_regs-based syscall ABI)."
  That leaves KSU_MANUAL_HOOK, which calls into the kernel at explicit source sites.
  Every ksu_handle_* symbol below is marked by KernelSU itself as a
  "manual hook integration point", so these are the intended call sites.

Sites patched:
  fs/exec.c        do_execve / compat_do_execve     -> ksu_handle_execveat
  fs/open.c        faccessat                        -> ksu_handle_faccessat
  fs/read_write.c  vfs_read                         -> ksu_handle_vfs_read   (init.rc append)
  fs/stat.c        newlstat/newfstatat/newfstat     -> ksu_handle_stat + ..._newfstat_ret
  kernel/reboot.c  reboot                           -> ksu_handle_sys_reboot
"""
import re
import sys

def edit(path, subs, imports=None):
    src = open(path, encoding="utf-8", errors="surrogateescape").read()
    orig = src
    if "CONFIG_KSU" in src and "ksu_handle" in src:
        print(f"  {path}: already patched")
        return True
    ok = True
    for label, old, new in subs:
        n = src.count(old)
        if n != 1:
            print(f"  !! {path} [{label}]: anchor found {n} times (expected 1)")
            ok = False
            continue
        src = src.replace(old, new, 1)
        print(f"  ok {path} [{label}]")
    if imports:
        src = src.replace(imports[0], imports[1], 1)
    if ok:
        open(path, "w", encoding="utf-8", errors="surrogateescape").write(src)
    else:
        print(f"  !! {path}: NOT written (anchor mismatch)")
    return ok


HDR_EXEC = '''#ifdef CONFIG_KSU
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr,
			       void *argv, void *envp, int *flags);
#endif

'''

HDR_READ = '''#ifdef CONFIG_KSU
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
			       size_t *count_ptr, loff_t **pos);
#endif

'''

HDR_OPEN = '''#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
				int *mode, int *unused_flags);
#endif

'''

HDR_STAT = '''#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
extern void ksu_handle_newfstat_ret(unsigned int *fd, struct stat __user **statbuf_ptr);
#endif

'''

HDR_REBOOT = '''#ifdef CONFIG_KSU
extern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd,
				 void __user **arg);
#endif

'''

print("== fs/exec.c ==")
edit("fs/exec.c", [
    ("do_execve externs",
     "int do_execve(struct filename *filename,",
     HDR_EXEC + "int do_execve(struct filename *filename,"),
    ("do_execve call",
     """	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);""",
     """	struct user_arg_ptr argv = { .ptr.native = __argv };
	struct user_arg_ptr envp = { .ptr.native = __envp };
#ifdef CONFIG_KSU
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);"""),
    ("compat_do_execve call",
     """	struct user_arg_ptr envp = {
		.is_compat = true,
		.ptr.compat = __envp,
	};
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);""",
     """	struct user_arg_ptr envp = {
		.is_compat = true,
		.ptr.compat = __envp,
	};
#ifdef CONFIG_KSU
	ksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);
#endif
	return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);"""),
])

print("== fs/read_write.c ==")
edit("fs/read_write.c", [
    ("vfs_read externs",
     "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)",
     HDR_READ + "ssize_t vfs_read(struct file *file, char __user *buf, size_t count, loff_t *pos)"),
    ("vfs_read call",
     """{
	ssize_t ret;

	if (!(file->f_mode & FMODE_READ))""",
     """{
	ssize_t ret;

#ifdef CONFIG_KSU
	ksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif
	if (!(file->f_mode & FMODE_READ))"""),
])

print("== fs/open.c ==")
edit("fs/open.c", [
    ("faccessat externs",
     "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)",
     HDR_OPEN + "SYSCALL_DEFINE3(faccessat, int, dfd, const char __user *, filename, int, mode)"),
    ("faccessat call",
     """	unsigned int lookup_flags = LOOKUP_FOLLOW;

	if (mode & ~S_IRWXO)	/* where's F_OK, X_OK, W_OK, R_OK? */""",
     """	unsigned int lookup_flags = LOOKUP_FOLLOW;

#ifdef CONFIG_KSU
	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
	if (mode & ~S_IRWXO)	/* where's F_OK, X_OK, W_OK, R_OK? */"""),
])

print("== fs/stat.c ==")
edit("fs/stat.c", [
    ("stat externs",
     """SYSCALL_DEFINE2(newlstat, const char __user *, filename,
		struct stat __user *, statbuf)""",
     HDR_STAT + """SYSCALL_DEFINE2(newlstat, const char __user *, filename,
		struct stat __user *, statbuf)"""),
    ("newlstat",
     """SYSCALL_DEFINE2(newlstat, const char __user *, filename,
		struct stat __user *, statbuf)
{
	struct kstat stat;
	int error;

	error = vfs_lstat(filename, &stat);
	if (error)
		return error;

	return cp_new_stat(&stat, statbuf);
}""",
     """SYSCALL_DEFINE2(newlstat, const char __user *, filename,
		struct stat __user *, statbuf)
{
	struct kstat stat;
	int error;
#ifdef CONFIG_KSU
	int ksu_dfd = AT_FDCWD, ksu_flag = 0;
	ksu_handle_stat(&ksu_dfd, &filename, &ksu_flag);
#endif

	error = vfs_lstat(filename, &stat);
	if (error)
		return error;

	error = cp_new_stat(&stat, statbuf);
#ifdef CONFIG_KSU
	if (!error)
		ksu_handle_newfstat_ret((unsigned int *)&ksu_dfd, &statbuf);
#endif
	return error;
}"""),
    ("newfstatat",
     """SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;

	error = vfs_fstatat(dfd, filename, &stat, flag);
	if (error)
		return error;
	return cp_new_stat(&stat, statbuf);
}""",
     """SYSCALL_DEFINE4(newfstatat, int, dfd, const char __user *, filename,
		struct stat __user *, statbuf, int, flag)
{
	struct kstat stat;
	int error;
#ifdef CONFIG_KSU
	ksu_handle_stat(&dfd, &filename, &flag);
#endif

	error = vfs_fstatat(dfd, filename, &stat, flag);
	if (error)
		return error;
	error = cp_new_stat(&stat, statbuf);
#ifdef CONFIG_KSU
	if (!error)
		ksu_handle_newfstat_ret((unsigned int *)&dfd, &statbuf);
#endif
	return error;
}"""),
])

print("== kernel/reboot.c ==")
edit("kernel/reboot.c", [
    ("reboot externs",
     "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,",
     HDR_REBOOT + "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,"),
    ("reboot call",
     """	struct pid_namespace *pid_ns = task_active_pid_ns(current);
	char buffer[256];
	int ret = 0;

	/* We only trust the superuser with rebooting the system. */""",
     """	struct pid_namespace *pid_ns = task_active_pid_ns(current);
	char buffer[256];
	int ret = 0;

#ifdef CONFIG_KSU
	ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);
#endif
	/* We only trust the superuser with rebooting the system. */"""),
])

print("\n== verification: every ksu_handle_ call site now present ==")
import subprocess
for f in ("fs/exec.c", "fs/read_write.c", "fs/open.c", "fs/stat.c", "kernel/reboot.c"):
    n = subprocess.run(["grep", "-c", "ksu_handle_", f], capture_output=True, text=True).stdout.strip()
    print(f"  {f}: {n} ksu_handle_ reference(s)")
