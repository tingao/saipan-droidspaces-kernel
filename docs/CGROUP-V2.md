# cgroup v2 on the moto g(50) 5G

This is the story of getting cgroup v2's device controller — `BPF_CGROUP_DEVICE` — into
this handset's 4.14.186 kernel, and what it does and does not buy on this particular
phone. It also corrects two things I had wrong before.

**Short version:** the backport works and is proven end-to-end (load, attach, enforce,
detach). But this phone's cgroup v2 has **no resource controllers at all**, so moving the
container onto cgroup v2 would remove the memory cap and gain nothing. The container stays
on cgroup v1, and the kernel now supports cgroup v2 for anything that needs it.

## 1. The failure

On a cgroup v2 host, `runc` sets device rules with an eBPF program attached to the
container's cgroup. Before that it asks the kernel whether such a program is attached:

```
bpf_prog_query(BPF_CGROUP_DEVICE) failed: invalid argument
```

`docker run` dies there.

## 2. What was actually wrong — and correcting the earlier diagnosis

I had previously written that `bpf_prog_query()` was missing `BPF_CGROUP_DEVICE` from its
attach-type switch. **That was wrong, and it mattered**, because it made the fix sound like
a one-line change.

This tree has no `BPF_PROG_QUERY` command at all. `BPF_PROG_QUERY` (syscall command 16) was
added in 4.15 and never came to 4.14. The kernel's syscall dispatcher therefore returns
`-EINVAL` for an unknown command before any attach-type switch is reached.

The proof is a control experiment. On the original kernel, `BPF_PROG_QUERY` returned `EINVAL`
for **every** attach type, including `BPF_CGROUP_INET_INGRESS` — which has existed since
4.10 and was never in question:

```
BPF_CGROUP_DEVICE, count only   -> ret=-1 errno=22 (Invalid argument)
BPF_CGROUP_INET_INGRESS         -> ret=-1 errno=22 (Invalid argument)   <- the tell
BPF_CGROUP_SOCK_OPS             -> ret=-1 errno=22 (Invalid argument)
attach_type=99 (invalid)        -> ret=-1 errno=22 (Invalid argument)
```

When a legitimate and a nonsense argument give the same error, the error is not about the
argument. It was about the command.

## 3. About ravindu644's fix

The comment on
[Droidspaces-OSS#327](https://github.com/ravindu644/Droidspaces-OSS/pull/327#issuecomment-5824708932)
points at
[`98d18e2a`](https://github.com/Kernels-by-ravindu644/samsung_kernel_exynos9820_extremerom/commit/98d18e2a7ec198d695e0b1a12f30c3bb76384cd7).

That commit is **not** a self-contained "add `BPF_CGROUP_DEVICE`" patch. It is a fix-up
against the LineageOS exynos9820 4.14.356 tree, which **already has** the feature backported
(its context includes `bpf_ctx_range()`, `cgroup_base_func_proto()`, `BPF_CGROUP_SYSCTL` and
`BPF_CGROUP_GETSOCKOPT` — all far newer than 4.15). I had recorded it as being against
OpenELA's `4.14.356-openela-rc1`; that was wrong too. OpenELA's `linux-4.14.y` is at
4.14.357 and has **no** `BPF_CGROUP_DEVICE` at all — it still uses the pre-4.15 attach API
(`struct bpf_prog *prog[]`, `disallow_override[]`, `__cgroup_bpf_update`).

So his patch cannot be applied here. What it *is* useful for is telling you which four
things to check, and on this tree they land as follows:

| his fix | where it comes from here |
|---|---|
| 1. `bpf_prog_query()` must accept `BPF_CGROUP_DEVICE` | upstream `ebc614f68736` — but the whole command had to be ported first |
| 2. verifier return-value validation for the type | upstream `ebc614f68736` (`check_return_code`, which also did not exist in 4.14) |
| 3. `cgroup_dev_is_valid_access()` must allow narrow u8/u16 reads of `access_type` | upstream `06ef0ccb5a36` |
| 4. `sysctl_func_proto()` mis-chained to `cgroup_dev_func_proto()` | **not applicable** — this tree has no BPF sysctl programs, so nothing to mis-chain. The port never creates that call site. |

Credit where it is due: his list is what sent me looking, and item 3 is a real bug that I
would otherwise have shipped, because I would have ported the original 4.15 version verbatim.

## 4. What was ported

Upstream, from Linux 4.15:

- `ebc614f68736` — *bpf, cgroup: implement eBPF-based device controller for cgroup v2*
  (Roman Gushchin). Adds `BPF_PROG_TYPE_CGROUP_DEVICE`, `BPF_CGROUP_DEVICE`, the
  `struct bpf_cgroup_dev_ctx` ABI, `__cgroup_bpf_check_dev_permission()` and the hook in the
  device-cgroup path.
- `06ef0ccb5a36` — *bpf/cgroup: fix a verification error for a CGROUP_DEVICE type prog*
  (Yonghong Song). The narrow-read fix.

Plus the three things the feature stands on that this tree also lacked, all 4.15:

- `BPF_PROG_QUERY` — the command itself, `union bpf_attr.query`, `BPF_F_QUERY_EFFECTIVE`,
  `bpf_prog_query()`, `__cgroup_bpf_query()` / `cgroup_bpf_query()`.
- `check_return_code()` — validates that a cgroup program's `R0` is provably 0 or 1.
- `bpf_prog_array_length()` and `bpf_prog_array_copy_to_user()` — used by the query.

The result is `build/patches/cgroupv2-4.14.patch`: **342 insertions across 12 files**, and it
applies cleanly to the pristine tree (`git apply --check` passes).

### The tree is neither 4.14 nor 4.15

This matters for anyone porting this elsewhere. Motorola/MTK pulled the 4.15 cgroup-bpf
**attach** rework into this 4.14.186 — it has `struct bpf_prog_list`, `bpf_prog_list->progs[]`,
`BPF_F_ALLOW_MULTI`, `__cgroup_bpf_attach()`. Vanilla 4.14 (OpenELA) does not. Being close to
4.15 is what made this tractable: the upstream 4.15 device code fits with only the six
adaptations below.

### The six adaptations

1. **`include/linux/bpf_types.h` takes the ops symbol verbatim.** This tree's registry is
   `const struct bpf_verifier_ops * const bpf_prog_types[]`, built with `[_id] = &_ops`, and
   its entries are *verifier* ops named `..._prog_ops`. So the entry is
   `BPF_PROG_TYPE(BPF_PROG_TYPE_CGROUP_DEVICE, cg_dev_verifier_ops)` — not upstream's
   `cg_dev`, which relies on 4.15's `_prog_ops`-appending macro.
2. **No `struct bpf_prog_ops` exists in this tree at all**, so upstream's empty
   `cg_dev_prog_ops` is not defined. Only `cg_dev_verifier_ops`.
3. **`cgroup_bpf_query()` goes in `kernel/cgroup/cgroup.c`**, next to the existing
   `cgroup_bpf_attach()`/`cgroup_bpf_detach()` wrappers — that is where this tree keeps them,
   not in `kernel/bpf/cgroup.c` as 4.15 does.
4. **The device hook lives in `security/device_cgroup.c`**, at the top of
   `__devcgroup_check_permission()`. Upstream wraps `devcgroup_check_permission()` in the
   header; this tree has no such function, and its two entry points
   (`__devcgroup_inode_permission`, `devcgroup_inode_mknod`) both funnel through the static
   function in the `.c`. The `ACC_*`/`DEV_*` constants already have the same numeric values as
   upstream's `DEVCG_*`, so the `(access << 16) | type` encoding matches `BPF_DEVCG_*`.
   Consequence to be honest about: because this tree's header only declares
   `devcgroup_inode_permission()` under `#ifdef CONFIG_CGROUP_DEVICE`, the BPF check is
   reachable only when `CONFIG_CGROUP_DEVICE=y` too. Both are `=y` here.
5. **`verbose()` takes no `env` argument** in this tree's verifier, so the ported
   `check_return_code()` uses the 4.14 call form.
6. **`u64_to_user_ptr`, `tnum_in`, `capable`, the func-proto externs and `dummy_bpf_prog`**
   all already exist — checked before writing anything.

### The module CRCs move, and that is fine

`module_layout` changes (`0xee4b197e` → `0xa1c56ecb`) and 3,810 of 11,363 exported symbol
CRCs differ. On most kernels that would unload every vendor module and cost you Wi-Fi.

It does not here, for two reasons that are already in the tree:

- `patch_module2.py` applies `KSU_TOLERANT_CRC`, which turns the CRC-mismatch path in
  `check_version()` from `return 0` into a `pr_warn_once` + `return 1`. Vendor `.ko` files
  built against Motorola's unpublished `-20-7-16` branch load anyway.
- `CONFIG_MODVERSIONS=y` is kept (it cannot simply be turned off — it is default-y and
  re-selected), so `VERMAGIC_STRING` stays byte-identical to stock. Turning it off would have
  broken the vermagic gate instead, which is why `patch_module.py`'s old docstring about
  setting it to `n` is stale.

Confirmed at boot: **zero** `CRC differs` warnings, and 17 of the 20 modules in
`/vendor/lib/modules` loaded.

## 5. Build and flash

The backport is now step 1b of `build/build-ksu.sh`, so it is part of every build. The
`--level` variant was used, matching the kernel that was already on the handset:

```sh
KSRC=/root/saipan-kernel/kernel-mtk OUT=/root/saipan-kernel/out-cgv2 TC=/root/toolchain \
  ./build/build-ksu-level.sh
```

```
  vermagic : 4.14.186+ SMP preempt mod_unload modversions aarch64
  ksu syms : 290
  cg_dev   : 3
  Image.gz : 14034229
  md5      : d19723bdbde0fa3bb724a5dd3f0be71a
```

All the config assertions passed, including the ones that decide whether vendor modules load
at all (`LTO_CLANG`, `CFI_CLANG`, `THINLTO`, `MODVERSIONS`).

The boot image reuses the header, ramdisk and DTB from the image that was already running,
changing only the kernel — verified by hashing: ramdisk `86D75144FBA67143` and DTB
`8ECA9BABC52DD103` identical, cmdline identical (`bootopt=64S3,32N2,64N2 buildvariant=user`),
kernel md5 `D19723...` as built. `End` 28,551,168 of 41,943,040 bytes.

## 6. Verification

Two small programs in [`extras/cgroupv2-test/`](../extras/cgroupv2-test/) do the checking;
both have controls so a pass cannot be confused with a non-test.

`cgdev-query` — makes the exact call runc makes:

```
BPF_CGROUP_DEVICE, count only   -> ret=0 errno=0 (Success) attach_flags=0x0 prog_cnt=0
BPF_CGROUP_INET_INGRESS         -> ret=0 errno=0 (Success) prog_cnt=1
BPF_CGROUP_SOCK_OPS             -> ret=0 errno=0 (Success) prog_cnt=0
BPF_CGROUP_DEVICE, 8 slots      -> ret=0 errno=0 (Success) prog_cnt=0
attach_type=99 (invalid)        -> ret=-1 errno=22 (Invalid argument)   <- control
query_flags=0x40 (invalid)      -> ret=-1 errno=22 (Invalid argument)   <- control
VERDICT: PASS
```

The controls still fail, which is what makes the passes mean something.

`cgdev-attach` — proves enforcement, not just acceptance. It loads a real
`BPF_PROG_TYPE_CGROUP_DEVICE` program, attaches it to a scratch cgroup, moves itself in, and
tries to open devices:

```
phase 0: no program attached          open /dev/null                -> 0 (Success)
phase 1: ALLOW program (returns 1)    open /dev/null                -> 0 (Success)
phase 2: DENY program  (returns 0)    open /dev/null                -> 1 (EPERM)
                                      open /dev/zero                -> 1 (EPERM)
phase 3: detached                     open /dev/null                -> 0 (Success)
```

Phase 2 is the point: an `EPERM` that appears only while the deny program is attached can
only have come from the kernel running it. This also exercises the ported `check_return_code()`,
since both programs return a constant in `{0,1}` and the verifier accepted them.

### Health after flashing

| | |
|---|---|
| kernel | `4.14.186+ #1 SMP PREEMPT Fri Sep 25 12:14:34 CEST 2026` |
| boot | `sys.boot_completed=1` |
| modules | 17 of 20 loaded (`ets_fps`, `met`, `moto_f_usbnet` are normally not) |
| Wi-Fi | `wlan0` up, `192.168.0.239`, driver `wlan` |
| Bluetooth | `bluetooth-1-1` running |
| touch / fingerprint | `chipone_tddi_mmi`, `fpsensor_spi` loaded |
| kernel panics | 0 |
| real `BUG:` lines | 0 |
| `WARNING:` | 4 — all pre-existing or vendor-driver: `__free_irq` from `fpsensor_spi`, two `cleanup_net` (the netns teardown issue in [KERNEL-NOTES.md](KERNEL-NOTES.md) §6b), and the WMT regulator dump at Wi-Fi probe |
| traces in bpf/cgroup code | 0 |
| container | `bagda` running, systemd `running`, 0 failed units, Portainer up |
| memory guard | active, 3,457,220,608 bytes (3297 MB) |

The `cleanup_net` warnings are confirmed pre-existing: the previous session's captured dmesg
files already contain 6 and 3 of them respectively. My first count of `BUG:` was 1, which
turned out to be the substring inside Trustonic's `DEBUG:` line — there are none.

## 7. Why this container still stays on cgroup v1

This section began as a much shorter and much wronger claim — that cgroup v2 "has no resource
controllers at all". It does not have any *enabled*, and the precise reason, and what happens
if you change that, turned out to be worth knowing. Everything below is measured on the handset.

### 7.1 Where the controllers actually go, and why

Two independent things decide it, and neither is the kernel feature this document is about.

**Android userspace says so.** `/system/etc/cgroups.json` names the hierarchy for each
controller:

```
v1:  blkio -> /dev/blkio   cpu -> /dev/cpuctl   cpuset -> /dev/cpuset   memory -> /dev/memcg
v2:  freezer
```

So Android is not failing to use cgroup v2 — it is explicitly asking for `memory`, `cpu`,
`cpuset` and `blkio` on v1.

**And this 4.14 kernel cannot honour the one v2 request it makes.** `freezer` in cgroup v2
arrived in **Linux 5.2**; here `freezer_cgrp_subsys` has only `.legacy_cftypes`. So init's
request to delegate freezer in `Cgroups2` fails, `cgroup.subtree_control` stays empty, and
`cgroup.controllers` is empty with it. That is the whole reason a v2 directory on this phone
has only base files and pressure files.

Which controllers *could* be in v2 on this kernel, read straight out of the tree:

| controller | v2 capable? | evidence |
|---|---|---|
| **memory** | **yes** | `.dfl_cftypes = memory_files` — includes `memory.max`, `memory.current`, `memory.high` |
| **pids** | **yes** | `.dfl_cftypes = pids_files` |
| io (blkio) | yes | `.dfl_cftypes = blkcg_files` |
| `cpu` | no | only `.legacy_cftypes` (v2 cpu controller landed in **4.15**) |
| `cpuset` | no | only `.legacy_cftypes` |
| `freezer` | no | only `.legacy_cftypes` (v2 freezer landed in **5.2**) |

### 7.2 What actually happens if you move memory to v2

This is testable without touching the system partition, because 4.14 supports the boot
parameter **`cgroup_no_v1=`** (`__setup("cgroup_no_v1=", cgroup_no_v1)`), and we control the
boot cmdline. With `cgroup_no_v1=memory`:

- `memory` leaves v1 entirely, and `cgroup.controllers` becomes **`memory pids`**.
- **Android tolerates it.** `cgroups.json` marks memory `"Optional": true`, init's mount of
  `/dev/memcg` fails without complaint, and **lmkd falls back to PSI** — it logs
  `Using psi monitors for memory pressure detection` and keeps running. `system_server`,
  `zygote`, WebView, Wi-Fi and all 17 vendor modules came up normally, `boot_completed=1`,
  0 panics.
- `echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control` then works, and a **direct child**
  of the root gets `memory.max`, `memory.current`, `memory.high`, `memory.swap.max`. (Direct
  child matters: a controller enabled at the root is only offered one level down.)

And then the part that decides the question:

**The cap binds, but nothing gets killed.** With `memory.max = 64 MB` and a workload
allocating 192 MB:

```
memory.current      = 67108864    <- pinned exactly at the cap
memory.swap.current = 0
memory.events       = low 0 high 0 max 213311 oom 30472 oom_kill 0
process state       = R (running), VmRSS 67892 kB
dmesg "Memory cgroup out of memory" lines: 0
```

`memory.max` is enforced precisely — resident memory cannot exceed it. But the OOM path was
entered **30,472 times** and `oom_kill` stayed **0**: the memcg OOM killer does not fire on
cgroup v2 on this kernel, and the process **spins forever** at the cap instead of dying. On
cgroup **v1** the same kernel does kill — that is proven in
[SERVER-SETUP.md §7.2](SERVER-SETUP.md#72-a-container-memory-limit-and-why-memory_limit-is-not-how-you-get-one),
which captured `Memory cgroup out of memory: Kill process (portainer)`.

A cap that hangs the offender instead of terminating it is worse than useless for the problem
this phone actually has, which is an `apt` run growing until the kernel panics with
"Out of memory and no killable processes". So v2 memory is not an upgrade here.

**And a memory-only cap is not a ceiling on either version.** With `memory.max = 64 MB` and
swap left uncapped, a 192 MB allocation was absorbed rather than stopped: `memory.current`
peaked at 63 MB while **`memory.swap.current` reached 129 MB**. This is the same lesson the v1
guard already recorded — `memory.limit_in_bytes` alone loses to zram, and the pair that binds
is `memory.limit_in_bytes` + `memory.memsw.limit_in_bytes`. On v2 it would be `memory.max` +
`memory.swap.max`, and even then nothing would be killed.

### 7.3 The decision

- **cgroup v2 device control works** — proven in §6, and that is what unblocks runc/Docker on a
  cgroup v2 host.
- **cgroup v2 memory accounts and caps but does not kill** on this kernel, so it cannot replace
  the v1 guard.
- **cgroup v2 has no `cpu.max` or `cpuset`** on 4.14 at all.

So `bagda` stays on cgroup v1, where the 90 % guard
([container-memguard](../extras/container-memguard/)) both binds *and* kills, and where the
`devices` controller is a first-class kernel feature rather than a bolted-on program type. The
`cgroup_no_v1=memory` experiment was reverted; the cmdline is stock again.

### 7.4 Would porting LineageOS help? No.

Two separate reasons, and the first one is fatal on its own:

1. **The tree in question is for a different SoC.** ravindu644's kernel is for **Exynos 9820**
   (Galaxy S10). This phone is **MediaTek MT6833**. Kernels do not port across SoC families —
   the display, modem, Wi-Fi/BT, touch, sensor and charger drivers are all SoC-specific, and
   this phone's 17 vendor modules are prebuilt against Motorola's MTK kernel with matching
   module CRCs. A foreign-SoC kernel would not boot at all. That has nothing to do with cgroups.
   A LineageOS *for saipan* would be a different and much larger project, and the kernel would
   still be 4.14.
2. **Even a LineageOS 4.14 for this device would not change the outcome**, because the
   controller placement is set by Android's `cgroups.json` (§7.1), and whether a controller
   *can* be in v2 is a kernel-version matter. Any 4.14 lacks v2 `cpu`, `cpuset` and `freezer`.
   OpenELA's `linux-4.14.y` and LineageOS's exynos9820 tree are both 4.14.

The one thing his tree had that this one lacked — `BPF_CGROUP_DEVICE` — we now have, ported and
proven, and the port is in this repo as a patch anyone can read.

### 7.5 Two more things worth recording

- **Droidspaces contains no BPF code at all.** `strings` finds no `bpf*` symbols. Its cgroup v2
  support is mounting cgroup2 and writing `memory.max` / `cpu.max` / `pids.max`, and it knows
  how to skip a controller it cannot use (`'memory' controller not supported, limit skipped`).
  None of that needs this backport.
- **`droidspaces check` reporting `[✓] Cgroup v2 support` is not evidence of this work.** That
  check only establishes that cgroup2 can be mounted; it passes on this kernel with or without
  the backport. I nearly reported it as a result.

### 7.6 A note on measuring this, because I got it wrong four times

Every one of the four invalid measurements below came from my own test harness, not the kernel,
and three of them produced a confident wrong answer before being caught:

1. **Sampled after the process had finished.** A completed process reads `memory.current ≈ 0`,
   which is indistinguishable from "the cgroup never charged anything".
2. **Suppressed `mkdir`'s error**, so the test cgroups were never created and every later write
   failed for an unrelated reason.
3. **Split "move into the cgroup" and "run the workload" into two shells**, so the pid written
   to `cgroup.procs` belonged to a shell that exited immediately and the workload actually ran
   in the root cgroup.
4. **The workload was optimised away.** The test binary wrote each 1 MB buffer with `memset()`
   and never read it back; at `-O2` that is a dead store and clang deleted it. The program
   "allocated 192 MB" 192 times while its own `VmRSS` stayed at **2.6 MB**. The fix is a
   `volatile` store plus reading a byte back, and the check that catches it is comparing the
   process's own `VmRSS` against the cgroup's counter.

The lasting lesson is the one this estate keeps re-learning: an `EINVAL`, a zero, or a
surviving process means nothing until you have a control that rules out the boring explanation.
The `cgdev-query` control row in §6 (a genuinely invalid attach type must still fail) exists for
the same reason.

`hog3.c`, the workload that survives optimisation, is in
[`extras/cgroupv2-test/`](../extras/cgroupv2-test/) so the next person does not rediscover the
dead-store trap the hard way.

## 8. Reproducing, and rolling back

```sh
# rebuild
KSRC=... OUT=... TC=... ./build/build-ksu-level.sh

# roll back to the stock kernel
./build/flash-boot.ps1 -Image .\fw\extracted\boot.img -Restore

# roll back to the kernel from before this change (already on disk)
./build/flash-boot.ps1 -Image C:\storage\ai\saipan\rollback-boot-4.14.186-nocgv2.img
```

Full rollback is one flash either way. Do **not** relock the bootloader on this device — that
programs an efuse and is irreversible.
