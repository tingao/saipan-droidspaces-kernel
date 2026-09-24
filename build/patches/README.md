# patches

## `ksu-next-4.14.patch`

A `git apply` diff carrying the tree changes KernelSU-Next needs on a 4.14 kernel. These are
upstream's required integration edits, not mine, which is why they are kept as a patch
instead of a Python patcher - there is nothing here I need to re-derive.

| file | change | why |
|---|---|---|
| `fs/internal.h`, `fs/namespace.c` | adds `path_umount()` | 4.14 has no exported `path_umount()`; `ksud` needs it to unmount a module's overlay cleanly. Upstream backports this from 4.9.x's `kern_path_umount` shape. |
| `include/linux/seccomp.h` | `atomic_t filter_count` in `struct seccomp` | KernelSU's seccomp handling counts filters per task; older kernels only track one filter pointer. |
| `security/selinux/hooks.c` | `cred->security` → `selinux_cred(cred)`, `inode->i_security` → `selinux_inode(inode)` | the accessor helpers KernelSU's SELinux code patches against. Functionally identical on this tree - both macros resolve to the same field - so this is a shape change, not a behaviour change. |
| `security/selinux/include/objsec.h` | defines those accessors | as above. |
| `security/selinux/selinuxfs.c`, `security/selinux/xfrm.c` | use the accessors | as above. |
| `drivers/Kconfig` | `source "drivers/kernelsu/Kconfig"` | wires the Kconfig in. |
| `drivers/Makefile` | `obj-$(CONFIG_KSU) += kernelsu/` | wires the build in. |

Apply it to a pristine tree (`build-ksu.sh` checks for `path_umount` in `fs/internal.h` first
and skips it if it is already there).

## The Python patchers

These are the changes that are actually mine, and each one is written as a locate-anchor-
then-refuse-if-ambiguous edit rather than a diff, because a diff against someone else's
kernel tree is the thing that goes stale silently.

| script | touches | what it does | written up in |
|---|---|---|---|
| `patch_module.py` | `kernel/module.c` | `same_magic()` ignores the optional `modversions` vermagic token | [../docs/KERNEL-NOTES.md](../docs/KERNEL-NOTES.md) §3 |
| `patch_module2.py` | `kernel/module.c` | `check_version()`'s CRC mismatch path warns instead of refusing to load | same section |
| `patch_manual_hooks.py` | `fs/exec.c`, `fs/read_write.c`, `fs/open.c`, `fs/stat.c`, `kernel/reboot.c` | the five KernelSU manual-hook call sites | §5 |
| `patch_cpu_level.py` | `.../mach/mt6833/mtk_cpufreq_platform.c` | adds the `mtk_cpufreq.level=` `__setup` override | [../docs/CPU-CLOCK.md](../docs/CPU-CLOCK.md) |

All four are idempotent and all four print what they found before they change it.
