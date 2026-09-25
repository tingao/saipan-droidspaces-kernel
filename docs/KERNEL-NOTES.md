# saipan: the four things that made this hard

Date: 2026-09-24 · Device: **moto g(50) 5G, `saipan`, XT2149-1, MT6833, Android 12
`S1RSS32.38-20-7-16`, kernel 4.14.186**

Four separate, non-obvious failures. Three of them are invisible from the config file, and
between them they account for almost all the time this took. They will recur on any
Motorola/MediaTek device from this era, so I am writing them down properly.

---

## 1. The bootloader was locked, not unlocked

I started from the assumption that it was already unlocked, because Developer Options said
`sys.oem_unlock_allowed = 1`. That flag only means the toggle is on. It says nothing about
whether anything was actually unlocked, and on this device nothing was:

```
ro.boot.flash.locked          1
ro.boot.vbmeta.device_state   locked
ro.boot.verifiedbootstate     green
fastboot getvar securestate   oem_locked
```

`verifiedbootstate=orange` is the one that means unlocked. Green means everything is still
verified, i.e. stock.

The device does emit `fastboot oem get_unlock_data`, and XT2149-1 is a retail `opencl` CID
`0x0032` unit, which is on Motorola's eligible list, so the official unlock key path works.
`fastboot oem unlock <key>` wiped the device, as it is supposed to.

**Never relock it afterwards.** On a Motorola MTK handset, relocking programs an efuse. It is
not a reversible toggle and it can leave a phone that will not flash anything, including
official firmware.

---

## 2. Failure #1 - a kconfig run without the toolchain silently drops LTO and CFI

**Symptom.** The kernel boots. `/proc/modules` is empty. Logcat says
`android.hardware.wifi@1.0-service-lazy: Failed to load WiFi driver`, and the touchscreen is
dead too.

**Cause.** `CONFIG_LTO_CLANG`, `CONFIG_CFI_CLANG` and `CONFIG_THINLTO` are gated on compiler
capability probes (`cc-option`). Running `make olddefconfig` with the **host gcc** instead of
`clang-r383902` silently selects `CONFIG_LTO_NONE=y` and drops CFI. Nothing warns you.

That matters because of one line in `include/linux/module.h`:

```c
#ifdef CONFIG_CFI_CLANG
	cfi_check_fn cfi_check;
#endif
```

Dropping CFI changes **`struct module`**. That changes the `module_layout` symbol CRC, and with
`CONFIG_MODVERSIONS=y` every prebuilt vendor module is then rejected.

**Rule: pass the real toolchain to *every* kconfig invocation, not just to the build.**

```sh
make O=out ARCH=arm64 TARGET_PRODUCT=saipan_retail CC=clang LD=ld.lld \
     NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
     READELF=llvm-readelf \
     CROSS_COMPILE=aarch64-linux-android- CLANG_TRIPLE=aarch64-linux-gnu- olddefconfig
```

**The check that catches it** is an assertion immediately before the build: `CONFIG_LTO_CLANG=y`,
`CONFIG_CFI_CLANG=y`, `CONFIG_THINLTO=y`, and `CONFIG_LTO_NONE` absent. A config that merely
*looks* right in a diff is not enough, because the failure is a *removal* - the option is
simply not there, and a diff against a config you built the same wrong way shows nothing.

---

## 3. Failure #2 - the published source branch is one patch level newer, so CRCs differ

Even with CFI and LTO restored, and with the **completely unmodified shipped config**, the
vendor modules still refused to load. A control build ruled the config out entirely:

| build | `__crc_module_layout` |
|---|---|
| Droidspaces config | `0xee4b197e` |
| **unmodified stock config** | `0xbd424614` |

The device's modules were built by Motorola from branch
**`android-12-release-s1rs32.38-20-7-16`**. The **only** published branch for this train is
**`…-20-9`** - I confirmed that with `git ls-remote`, which returns exactly one match for
`s1rs`. Building `-20-9`, even with a stock config, produces different symbol CRCs, so
`check_version()` rejects every module:

```c
bad_version:
	pr_warn("%s: disagrees about version of symbol %s\n", info->name, symname);
	return 0;      /* <-- fatal for every module */
```

**What I did.** Kept `CONFIG_MODVERSIONS=y`, so `VERMAGIC_STRING` stays byte-identical to stock,
and turned that one return into a warning (`patch_module2.py`). I also made `same_magic()`
tolerate the optional `modversions` token being present on only one side of the comparison
(`patch_module.py`), because the vermagic gate rejects the modules for the same underlying
reason.

I tried `CONFIG_MODVERSIONS=n` first, as the more obvious fix. It cannot be forced: the symbol
is default-`y` and gets re-selected, and turning it off changes `VERMAGIC_STRING` to
`4.14.186+ SMP preempt mod_unload aarch64`, which is the *other* gate that rejects these
modules. So the CRC comparison had to be made tolerant rather than removed.

**Why this is safe here, and where I stopped.** `struct module`'s configuration is provably
identical to stock - every `CONFIG_*` that `include/linux/module.h` references matches between
the two trees - so the mismatch is confined to symbols whose *headers* moved between the two
revisions, not to the ABI the modules rely on. I verified that empirically rather than by
argument: all 17 modules load, and Wi-Fi, Bluetooth, touch, fingerprint, GPS, FM and the
sensors all work. What I did *not* do is prove that every one of those symbols is
layout-compatible; I verified the modules that exist on this device on this ROM. Treat it as
validated for this combination, not as a general licence to mix kernel branches.

**Also required, and easy to miss:** `CONFIG_LOCALVERSION=""` and a deterministic `+`.
`scripts/setlocalversion` prints `.scmversion` verbatim, so

```sh
printf '+' > .scmversion
```

gives exactly `4.14.186+` regardless of what git thinks the tree is. Do **not** set
`CONFIG_LOCALVERSION="+"` as well, or you get two of them.

Resulting vermagic, byte-identical to stock:

```
4.14.186+ SMP preempt mod_unload modversions aarch64
```

---

## 4. Failure #3 - `CONFIG_SYSVIPC` would have shifted `struct task_struct`

Droidspaces' non-GKI option list asks for `SYSVIPC` + `IPC_NS`. `IPC_NS` is genuinely required.
`SYSVIPC` is not, and enabling it here would have been a quiet disaster. From
`include/linux/sched.h`:

```c
#ifdef CONFIG_SYSVIPC
	struct sysv_sem			sysvsem;
	struct sysv_shm			sysvshm;
#endif
#ifdef CONFIG_DETECT_HUNG_TASK
	unsigned long			last_switch_count;
#endif
	/* Filesystem information: */
	struct fs_struct		*fs;
	/* Open file information: */
	struct files_struct		*files;
	/* Namespaces: */
	struct nsproxy			*nsproxy;
	/* Signal handlers: */
	struct signal_struct		*signal;
	struct sighand_struct		*sighand;
```

Enabling `SYSVIPC` inserts those two fields **before** `fs`, `files`, `nsproxy`, `signal` and
`sighand`, shifting offsets that prebuilt vendor modules compile against. That is silent memory
corruption, not a clean failure - exactly the kind of thing that would have shown up as an
occasional mystery crash weeks later.

**What I did instead.** `IPC_NS` only `depends on (SYSVIPC || POSIX_MQUEUE)`. Enabling
**`POSIX_MQUEUE`** alone satisfies it. Its only structural effect is one added field in
`struct user_struct`, which no vendor module touches.

I went through the four options by hand rather than trusting the list:

| option | struct impact | verdict |
|---|---|---|
| `IPC_NS` | none - function declarations only | safe |
| `USER_NS` | none - inline functions only; `cred->user_ns` is unconditional | safe |
| `POSIX_MQUEUE` | `struct user_struct` +1 field | safe enough |
| `SYSVIPC` | **shifts `task_struct` fields** | **avoid** |

This is the one place where following the documented option list verbatim gives you a kernel
that boots, passes every container check, and is quietly broken.

---

## 5. Failure #4 - KernelSU's kprobe mode cannot work below kernel 4.17

KernelSU-Next's `drivers/kernelsu/include/arch.h` hardcodes:

```c
#define SYS_READ_SYMBOL   "__arm64_sys_read"
#define SYS_EXECVE_SYMBOL "__arm64_sys_execve"
#define SYS_FSTAT_SYMBOL  "__arm64_sys_newfstat"
```

Those `pt_regs`-based wrappers **do not exist in this tree**. `arch/arm64/kernel/sys.c` uses the
classic ABI:

```c
#undef  __SYSCALL
#define __SYSCALL(nr, sym)	[nr] = sym,     /* sys_call_table -> sys_read, sys_execve, ... */
```

So kprobe registration fails silently - the code logs the result but does not fail hard - the
`init.rc` injection never happens, `/data/adb/ksud post-fs-data` never runs, and `su` never
appears. KernelSU-Next's own Kconfig agrees and rules out the alternatives:

* `KSU_KPROBES_HOOK` - *"This should not be used on kernel below 5.10."*
* `KSU_SYSCALL_TABLE_HOOK` - *"Requires kernel >= 4.17 (pt_regs-based syscall ABI)."*

**What I did.** `CONFIG_KSU_MANUAL_HOOK=y` plus the five documented call sites
(`build/patch_manual_hooks.py`):

| file | hook |
|---|---|
| `fs/exec.c` | `do_execve`, `compat_do_execve` → `ksu_handle_execveat` |
| `fs/read_write.c` | `vfs_read` → `ksu_handle_vfs_read` (this is the one that appends the `init.rc` snippet) |
| `fs/open.c` | `faccessat` → `ksu_handle_faccessat` |
| `fs/stat.c` | `newlstat`, `newfstatat` → `ksu_handle_stat` + `ksu_handle_newfstat_ret` |
| `kernel/reboot.c` | `reboot` → `ksu_handle_sys_reboot` |

Two more things were needed before root worked: `strscpy_pad()` does not exist in 4.14.186
(it arrives in 4.14.222), so `drivers/kernelsu/policy/allowlist.c` had to use
`__strscpy_pad()`; and four tree edits KernelSU-Next needs on an old kernel
(`path_umount`, `selinux_cred()`/`selinux_inode()` accessors, `filter_count` in
`struct seccomp`), which are in `build/patches/ksu-next-4.14.patch`.

After flashing, launching the KernelSU-Next manager once and **rebooting** produced
`/system/bin/su`. It did not appear before the reboot, which is worth knowing if you flash and
immediately think it failed.

---

## 6. Four more traps worth remembering

**`TARGET_PRODUCT` must be set for a manual `make`.** `drivers/misc/mediatek/eccci/port/Makefile`
does:

```makefile
ifneq (,$(findstring saipan, $(strip $(TARGET_PRODUCT))))
ccflags-y += -DSAIPAN_SWTP_CONFIG
endif
```

Without it `MAX_PIN_NUM` is undefined and the build dies in `ccsi_swtp.c` with a message that
points at the driver rather than at the missing build variable. Use
`TARGET_PRODUCT=saipan_retail`.

**Inline `su -c "a; b; c"` does not preserve shell state.** Neither variables nor `cd` survive
between the `;`-separated commands under KernelSU's `su` on this device:

```sh
su -c "cd /data/local/tmp; pwd"        # prints "/"    - the cd did not stick
su -c "R=/x; dd if=a of=$R/b"          # $R is empty  - the assignment did not stick
```

This looks exactly like a permissions problem, because the write lands at `/`, which genuinely
is read-only, so you get `Read-only file system` and `Permission denied`. I spent real time
chasing SELinux before working out what it actually was. Put multi-step logic in a script file
(`su -c "sh /path/script.sh"`), where shell state behaves normally, or keep every command
self-contained with absolute paths.

**Config files for on-device scripts must be LF.** A `tuning.conf` I regenerated on Windows had
CRLF endings. `echo "$CHARGE_UPPER" > …/upper_limit` then wrote `"80\r"`, the
`qpnp_adaptive_charge` driver rejected it, and the charge band silently stayed disabled while
the watchdog logged "re-asserted" every minute. The log looked healthy and the battery kept
charging to 100 %. Check with `od -c file | grep '\r'` before you blame the driver.

**The boot image's cmdline reaches the kernel.** I verified this rather than assuming it:
`/proc/cmdline` on the running device contains `bootopt=64S3,32N2,64N2 buildvariant=user`, which
is the cmdline stored in the boot header, not something the bootloader supplied. That is what
makes the `mtk_cpufreq.level=` override in [CPU-CLOCK.md](CPU-CLOCK.md) work at all - one kernel
build, three DVFS segments, chosen by repacking the boot image.

---

## 6b. The warning that is not a fault

`dmesg` does not stay clean on this kernel once Docker is running, and it is worth knowing why
before you go hunting it:

```
WARNING: CPU: 0 PID: 19153 at fs/proc/proc_sysctl.c:1687 cleanup_net+0x334/0x574
Workqueue: netns cleanup_net
 sysctl_net_exit+0x38/0x40
 cleanup_net+0x334/0x574
```

It is a network-namespace teardown warning in `sysctl_net_exit`, and **Docker causes it**: every
container that exits tears down its netns. Measured directly - three `docker run --rm` calls
produced exactly six new occurrences, two per run, reproducibly:

```
warnings before: 2
warnings after : 8   (three runs)
```

Nothing comes of it. Through the same test the phone stayed up, `MemAvailable` held at ~2.19 GB,
Docker answered, and `sshd` and `cloudflared` stayed active. It is a `WARNING`, so it taints the
kernel and it will show up in any `panic|oops|BUG:|WARNING:` sweep - including the checks in this
repo. Treat a nonzero count as expected on a handset that runs containers, and judge the kernel by
`panic`/`oom`/suspend behaviour instead. A `sysctl_net_exit` warning is not evidence of a bad
kernel build; I chased this briefly as one.

It also fires during boot, before anything invokes Docker, because starting the container itself
creates a network namespace. Three occurrences at 35 s, 38 s and 91 s on a clean reboot, all the
same site, and no vendor module appears anywhere in the trace.

---

## 6c. Two ways a health check lies to you

Both of these reported a failure today on a handset that was working perfectly, and both cost
more time than the real bugs.

**`droidspaces` is not on `PATH` for a `su -c` shell.** It lives in
`/data/local/Droidspaces/bin/droidspaces`. A check that calls it bare gets
`droidspaces: inaccessible or not found` and reports the container as down, on a device where the
container is running fine:

```sh
su -c 'droidspaces --name=bagda run /bin/true'   # not found
su -c '/data/local/Droidspaces/bin/droidspaces --name=bagda run /bin/true'   # works
```

A ten-minute soak recorded `container=DOWN` in all sixty samples for exactly this reason, while
`sqlite3`, `curl` and `systemctl` calls inside that same container were working. **A soak that
reports a component down for every single sample is describing its own bug, not a fault** - a real
outage is rarely that uniform.

**`/dev/tcp` is a bash feature and Android has no bash.** This looks like it should test a
listening port and instead always fails:

```sh
(echo > /dev/tcp/127.0.0.1/1304) >/dev/null 2>&1 && echo up || echo down   # always "down"
```

Test a port from off-device instead, where the answer is real - `Test-NetConnection <lan-ip> 1304`
from Windows, or `adb forward` plus a connection to the forwarded port. Both confirmed sshd was
listening on `192.168.0.239:1304` while the on-device check insisted it was not.

## 7. Build recipe

Everything above is baked into `build/build-ksu.sh`, so this is the summary rather than the
procedure. Use the script.

```sh
# toolchain: clang-r383902 - it reports itself as "clang version 11.0.1 / 6443078 based on
# r383902", which is the same string in the handset's stock kernel banner
cd kernel-mtk
printf '+' > .scmversion

# 1. seed from the SHIPPED config (pulled from /proc/config.gz) for maximum parity
cp saipan-stock.config out/.config

# 2. kconfig WITH the toolchain (see section 2)
make O=out ARCH=arm64 TARGET_PRODUCT=saipan_retail CC=clang LD=ld.lld \
     NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
     READELF=llvm-readelf \
     CROSS_COMPILE=aarch64-linux-android- CLANG_TRIPLE=aarch64-linux-gnu- olddefconfig

# 3. Droidspaces + root (see sections 4 and 5)
scripts/config --file out/.config \
  -e DEVTMPFS -e CGROUP_DEVICE -e POSIX_MQUEUE -e IPC_NS -e USER_NS \
  -e CGROUP_PIDS -e CGROUP_NET_PRIO -e TMPFS_XATTR -e TMPFS_POSIX_ACL \
  -e NF_TABLES -e NETFILTER_XT_MATCH_ADDRTYPE -e BRIDGE_NETFILTER \
  -e KPROBES -e KPROBE_EVENTS -e KSU -e KSU_MANUAL_HOOK \
  -d KSU_KPROBES_HOOK -d SYSVIPC -d DEVTMPFS_MOUNT -d MODULE_SIG

# 4. same toolchain args again
make ... olddefconfig

# 5. assert LTO/CFI survived BEFORE building (section 2)
grep -E '^CONFIG_(LTO_CLANG|CFI_CLANG|THINLTO|MODVERSIONS)=' out/.config

# 6. build
make ... -j"$(nproc)" Image
gzip -9 -n -c out/arch/arm64/boot/Image > Image.gz
```

Pack it into the boot image with the **stock** ramdisk and the **stock** dtb (header v2, 2048-byte
pages, 41,943,040-byte partition). `build/pack-boot.ps1` unpacks and repacks; the layout is
documented in [../build/README.md](../build/README.md).

## 8. Recovery assets

| file | purpose |
|---|---|
| your own `boot` partition backup | the only undo button that matters - take it first |
| `blankflash_saipan.zip` | last-resort MediaTek BROM recovery, if fastboot is gone |
| the stock `boot.img` from your firmware | one fastboot command back to stock |

I keep all three on disk. The blankflash is the one you hope never to need, and it is also the
one you cannot download after the phone stops booting.
