# The server side: container, Docker, and the tuning that keeps it up

Device: **moto g(50) 5G**, `saipan`, XT2149-1, MediaTek MT6833, Android 12
`S1RSS32.38-20-7-16`, kernel 4.14.186+ (the one in this repository), bootloader unlocked,
KernelSU-Next root.

Everything below was verified end to end after a cold boot: the container starts on its own,
Docker runs containers, the charge band holds, the wakeup source holds, Wi-Fi is up, and SELinux
is Enforcing.

---

## 1. What is running

| layer | detail |
|---|---|
| Kernel | custom 4.14.186, built from `MotorolaMobilityLLC/kernel-mtk` branch `android-12-release-s1rs32.38-20-9`, clang-r383902, LTO and CFI preserved, vermagic byte-identical to stock |
| Root | KernelSU-Next, **manual-hook** mode - [KERNEL-NOTES.md](KERNEL-NOTES.md) §5 explains why nothing else works on 4.14 |
| Vendor modules | 17 of 17 load - Wi-Fi, Bluetooth, touch, fingerprint, GPS, FM, sensors |
| Runtime | Droidspaces v6.5.5 |
| Container | `bagda` - Debian GNU/Linux 13 (trixie), systemd as PID 1, NAT network, `172.28.205.17`, `run_at_boot=1` |
| Inside | Docker Engine 29.8.1, `overlay2`, cgroup driver `systemd`, **cgroup v2**, Compose v5.5.1 |
| Host tuning | ACC holds the pack at 55-60 % (qpnp band 75-80 % as a backstop), wakeup source `saipan-awake`, CPU ceilings, SIM-driven airplane mode - all re-asserted every 60 s |
| SELinux | **Enforcing** - permissive only during setup |

---

## 2. The three container settings that make Docker work on a 4.14 kernel

Nested containers on this kernel need three non-default settings. I found all three by hitting
the failure first, and all three are persisted in
`/data/local/Droidspaces/Containers/bagda/container.config`.

### 2.1 `--privileged=noseccomp` - the Adaptive Seccomp Shield

Without it, `docker run` fails at:

```
failed to start shim: start failed: failed to create TTRPC connection:
dial unix unix:///run/containerd/s/... ttrpc: connect: connection refused
```

containerd's shim starts and immediately dies. The cause is documented by Droidspaces
themselves (Troubleshooting → *Adaptive Seccomp Shield*): on legacy kernels (3.18-4.19)
Droidspaces intercepts namespace-related syscalls and returns `EPERM`, to avoid the 4.14 VFS
deadlock. The shim needs those syscalls, so it exits before it ever listens on its socket.

### 2.2 `--force-cgroupv1` - BPF_CGROUP_DEVICE

With the shield off, the next failure is:

```
error setting cgroup config for procHooks process:
bpf_prog_query(BPF_CGROUP_DEVICE) failed: invalid argument
```

The default container gets **cgroup v2**, and on v2 runc *must* program device rules with BPF.
This tree has no `BPF_PROG_QUERY` command at all - the command arrived in 4.15 - so runc's query
was answered `EINVAL`. Forcing cgroup v1 puts runc on the legacy devices cgroup, which this
kernel does support. **The kernel now implements the missing feature**: see the corrections
below, and [CGROUP-V2.md](CGROUP-V2.md) for the whole story.

Droidspaces' docs recommend `cgroupfs` plus the `vfs` storage driver for legacy kernels.
`cgroupfs` was necessary; `vfs` was not - `overlay2` works here, and the base image's own
docker had already proven it.

**Could this be avoided by staying on cgroup v2?** Not with the kernel as it then was. It is
worth recording that this was tested rather than assumed, because it is the obvious question and
the estate's own GKI notes say the opposite for newer kernels ("do not use `--force-cgroupv1`;
stay on cgroup v2").

The test: `force_cgroupv1=0` was set, the container came up cleanly, and `/sys/fs/cgroup` was
`cgroup2fs`. With Docker 29.8.1 and **runc 1.5.1**, `docker run --rm hello-world` still failed
with the same error, and so did `--privileged` and `--security-opt systempaths=unconfined`.
`CONFIG_CGROUP_BPF=y` is set in the stock config, which is what makes this look like it should
work.

It cannot, because the missing piece is `BPF_CGROUP_DEVICE`, which arrived in **Linux 4.15**.
The symbol appears **zero times** in the entire 4.14.186 tree, and the only cgroup BPF program
types present are `BPF_PROG_TYPE_CGROUP_SKB` (4.10) and `BPF_PROG_TYPE_CGROUP_SOCK` (4.14) -
what `CONFIG_CGROUP_BPF` covers on 4.14. On cgroup v2 there is no `devices` controller to fall
back to; device rules *are* the BPF program. runc asks for it, gets `EINVAL`, and refuses.

So this is a missing kernel feature, not a misconfiguration, and no Docker flag or config option
reaches it.

**But it is not unfixable, and an earlier version of this page was too pessimistic about that.**
[ravindu644](https://github.com/ravindu644) pointed at the right place on the Droidspaces PR:
[Kernels-by-ravindu644/samsung_kernel_exynos9820_extremerom@98d18e2](https://github.com/Kernels-by-ravindu644/samsung_kernel_exynos9820_extremerom/commit/98d18e2a7ec198d695e0b1a12f30c3bb76384cd7).

That commit does **not** drop into this tree, and the reason is worth understanding rather than
just trying it. He describes his kernel as a 4.14.356 tree that already has the feature, and it
does. **Corrected:** I first wrote that this was OpenELA's extended 4.14. It is not - I cloned
OpenELA's `linux-4.14.y` and it is at 4.14.357 with **no** `BPF_CGROUP_DEVICE` at all, still
using the pre-4.15 attach API (`struct bpf_prog *prog[]`, `disallow_override[]`,
`__cgroup_bpf_update`). His tree is LineageOS `android_kernel_samsung_exynos9820`, backported far
beyond 4.15. The conclusion held either way - his commit is a follow-up to a feature already
present - but the place to port *from* is upstream 4.15, not OpenELA.

| his fix | what it corrects |
|---|---|
| `kernel/bpf/syscall.c` | `bpf_prog_query()` must accept `BPF_CGROUP_DEVICE` - **corrected below: there was no `bpf_prog_query()` here at all** |
| `kernel/bpf/verifier.c` | return-value validation for the device program type |
| `kernel/bpf/cgroup.c` | narrow `u8`/`u16` reads of `access_type`, needed by programs LLVM 6+ emits |
| `kernel/bpf/cgroup.c` | `sysctl_func_proto()` chained to the device helpers instead of the base set |

So the work for saipan is **two** steps, not one: port the device-cgroup BPF feature first, then
apply his fixes on top. **Two corrections to this paragraph:** the place to port from is upstream
**4.15**, and the surface is bigger than the file list here - the command itself, its
`union bpf_attr.query` ABI, `check_return_code()` and two `bpf_prog_array_*()` helpers were all
missing too. And `security/device_cgroup.c` **does** need a change: the call site has to be
added, because this tree has no `devcgroup_check_permission()` for upstream's header wrapper to
sit in. The real port is 342 lines across 12 files.

**Corrected: this was done, and it does not pay twice.** The feature was ported, built, flashed
and proven on the handset - image 3 of [../releases/README.md](../releases/README.md), full story
in [CGROUP-V2.md](CGROUP-V2.md). It makes the cgroup v2 device controller work: a device program
loads, attaches, and genuinely refuses device opens while it is attached.

**And the part I got wrong after that: it does make `memory_limit` work, once `memory` is allowed
into v2.** I wrote here that "no backport could" fix the empty `cgroup.controllers`. That was true
only while Android kept every controller on v1, and it does not have to: `cgroup_no_v1=memory` on
the kernel cmdline moves `memory` to the v2 hierarchy, Android tolerates losing `/dev/memcg`
(lmkd logs `Using psi monitors for memory pressure detection` and carries on), and then
`/sys/fs/cgroup/droidspaces/bagda/memory.max` exists and binds. [CGROUP-V2.md](CGROUP-V2.md) §7.

**The container now runs on cgroup v2**, and the reason is isolation rather than the cap. On v1
with `--force-cgroupv1`, Droidspaces' own docs say cgroup isolation is unavailable, and the effect
was visible: the container's systemd wrote `/init.scope` and `/system.slice/*` at the *host*
hierarchy root, next to Android's own cgroups. That is why the v1 guard could only ever cover the
Docker workloads its `cgroup-parent` captured, and never `apt`. On v2 every container process
lands under `/sys/fs/cgroup/droidspaces/bagda`, so one cap covers all 25 of them. What v2 still
cannot give on 4.14 is `cpu.max`, `cpuset` and `freezer` — kernel-version facts, not measurements,
which is why the container ends up hybrid with `cpu`/`cpuset`/`blkio` still on v1.

The ceiling is [extras/container-memguard](../extras/container-memguard/), now version-aware and
resetting `oom_score_adj`, plus [extras/cgroupv2-delegate](../extras/cgroupv2-delegate/) on the
host to enable `+memory` down to the container cgroup. The measured detail is in
[§7.2](#72-a-container-memory-limit-and-why-memory_limit-is-not-how-you-get-one).

The cost was a kernel rebuild and a reflash, and re-proving the vendor modules still load. They
do: 17 of 20 loaded, Wi-Fi, Bluetooth, touch, fingerprint all up, zero kernel panics, zero real
`BUG:` lines. The module CRCs do move (`module_layout` `0xee4b197e` -> `0xa1c56ecb`), which is
harmless only because this tree already turns a CRC mismatch into a warning rather than a
rejection.

### 2.3 The systemd socket-activation fix, inside the container

Docker CE's unit uses `ExecStart=/usr/bin/dockerd -H fd://`, i.e. systemd socket activation. That
path failed here with `no sockets found via socket activation`. A drop-in replaces it with a
plain unix socket:

```ini
# /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker.sock
```

Two things that bit me while getting there:

* **After adding the drop-in, `systemctl restart docker` did not pick it up** - systemd had
  rate-limited the unit. `systemctl reset-failed docker.service docker.socket` then a restart
  fixed it.
* **The Debian 13 Droidspaces base image already ships `docker-compose` 2.26.1** from Debian,
  which owns `/usr/libexec/docker/cli-plugins/docker-compose` and collides with Docker's
  `docker-compose-plugin`. Remove the former before installing the plugin:
  `apt-get -y remove docker-compose`.

---

## 3. Host tuning: the `saipan-tuning` KernelSU module

A KernelSU module, installed at `/data/adb/modules/saipan-tuning/`. `service.sh` runs at boot,
applies the tuning and detaches `watchdog.sh`, which re-asserts everything every 60 seconds.

**The watchdog is the point.** Android's power and thermal HALs rewrite these files underneath
you, and a lock/suspend cycle can leave Wi-Fi switched off. I have watched the charge band revert
within minutes of being set. The files and the reasoning are in
[../extras/README.md](../extras/README.md).

### 3.1 Battery: ACC holds the band, qpnp is the backstop

Charging is controlled by **ACC (Advanced Charging Controller) v2023.10.16** as a KernelSU
module - the same module, and the same version, the S8+ runs. Its charging switch is MediaTek's
own charger control interface:

```
chargingSwitch=(/proc/mtk_battery_cmd/en_power_path 1 0 --)
capacity=(0 101 55 60 false false)      pause 60 %, resume 55 %
```

The switch was verified by hand before being trusted - ACC's auto-detection has silently failed
on this estate before:

```
echo 0 > /proc/mtk_battery_cmd/en_power_path   ->  current_now  +503 mA  ->  -127 mA
echo 1 > /proc/mtk_battery_cmd/en_power_path   ->  current_now  -127 mA  ->  +466 mA
```

Note the **bare value**: `"0 0"` and `"1 0"` are accepted by the shell and ignored by the driver.
And `status` keeps reporting `Charging` while the power path is off, so the sign of `current_now`
is the only reliable signal - which is what ACC's `battStatusWorkaround` exists for.

Underneath it, the module keeps Motorola's own charge band as a **backstop**:

```
/sys/module/qpnp_adaptive_charge/parameters/upper_limit   -> 80
/sys/module/qpnp_adaptive_charge/parameters/lower_limit   -> 75
/sys/module/qpnp_adaptive_charge/parameters/blocking      -> 1
```

It is deliberately set *above* ACC's band so the two never fight - the pack never gets near 80 %
in normal operation. Its only job is the failure case: if `accd` stops, the charger driver still
halts the pack at 80 % instead of letting it sit at 100 % on a permanent cable.

**Write order matters** on those qpnp nodes. Writing `upper_limit` resets `lower_limit` to `-1`,
so upper must go first and lower second. Verified on-device:

```
echo 75 > lower; echo 80 > upper   ->  80/-1   (lower lost)
echo 80 > upper; echo 75 > lower   ->  80/75   (correct)
```

### 3.2 Keep-awake

A kernel wakeup source held via `/sys/power/wake_lock`. That interface is labelled
`sysfs_wake_lock` and is already writable, so no policy rule is needed. `AWAKEN_POLICY` in
`tuning.conf` selects `charging` (what I run), `always` or `off`.

The rationale is the same as my other two phone servers, and [KEEP-AWAKE.md](KEEP-AWAKE.md) is
careful about which part of it I actually re-measured on this handset.

### 3.3 CPU clocks

`tuning.conf` carries per-cluster ceilings and the governor, re-asserted every minute so nothing
can silently raise them back:

```
cpu0-5 (A55):   500000 .. 2000000    schedutil
cpu6-7 (A76):   725000 .. 2203000    schedutil   <- stock values, in force
```

The v2 kernel additionally makes the MT6833 DVFS segment switchable per boot from the boot image
cmdline. I measured all three segments and kept the stock one: the 2.4 GHz table is a no-op on
this silicon - the PLL never leaves 2.202 GHz - while its core voltage is 43.75 mV higher.
[CPU-CLOCK.md](CPU-CLOCK.md) has the measurements and the hardware readback.

### 3.4 SELinux

Every useful knob sits under a vendor-specific sysfs label that the KernelSU `su` domain cannot
write to by default:

| path | label |
|---|---|
| `/sys/module/qpnp_adaptive_charge/parameters/{upper,lower}_limit` | `vendor_sysfs_battery_supply` |
| `/sys/devices/system/cpu/cpu*/cpufreq/*` | `sysfs_devices_system_cpu` |

Reads were allowed; only writes were denied. Rather than running the phone permissive, the module
ships a narrow `sepolicy.rule` granting write on exactly those two labels to `ksu`,
`droidspacesd`, `init` and `vendor_init`. SELinux is now **Enforcing** and the tuning still works.

### 3.5 Airplane mode, decided from the SIM

The modem is powered whether or not it is useful, and whether it is useful depends on the SIM -
which can change while the phone is deployed. So the policy is read from the handset's own SIM
state instead of being hard-coded - hourly by default (`SIM_CHECK_EVERY=60`, one watchdog pass per minute): no SIM means airplane mode on with Wi-Fi kept
alive, a SIM means the radio stays up. Full reasoning, including the `UNKNOWN`-at-boot trap that
turned the radio off on a phone that has a SIM, is in [../extras/README.md](../extras/README.md).

### 3.6 The container must not be able to sleep the phone

With hardware access, the container's systemd-logind sees the handset's lid/power/idle events,
and a `systemd-suspend.service` there suspends the **whole phone**. On the S8+ this only failed
with `Device or resource busy` by luck.

`extras/container-no-suspend.sh` closes it: logind is told to ignore every switch and idle
action, and every sleep target is masked. `systemctl suspend` inside the container now fails
cleanly, which is what you want.

---

## 4. Verifying it all

```sh
# host tuning
su -c "/system/bin/sh /data/local/tmp/verify-tuning.sh"

# container + docker
su -c "/data/local/Droidspaces/bin/droidspaces show"
su -c "/data/local/Droidspaces/bin/droidspaces --name=bagda run docker info"
su -c "/data/local/Droidspaces/bin/droidspaces --name=bagda run docker run --rm hello-world"

# tuning log
su -c "tail -30 /data/local/saipan-tuning.log"
```

Get a shell in the container:

```sh
su -c "/data/local/Droidspaces/bin/droidspaces --name=bagda enter"
```

---

## 5. Operating notes

* **Never relock the bootloader.** On a Motorola MTK handset it programs an efuse and can leave a
  phone that will not flash anything, including official firmware.
* **The Droidspaces daemon runs from a KernelSU module**, at `/data/adb/modules/droidspaces/`, not
  from the app. The app's UI cannot grant itself root here - KernelSU never prompts for it - so the
  CLI plus module path is the supported route on this device. Daemon mode is enabled with
  `/data/local/Droidspaces/.daemon_mode`.
* **Inline `su -c "a; b; c"` does not preserve shell state** on this device. Use a script file or
  absolute paths. [KERNEL-NOTES.md](KERNEL-NOTES.md) §6.
* **Config files for on-device scripts must be LF.** A CRLF `tuning.conf` makes the charge band
  silently fail while the watchdog logs "re-asserted" every minute. Same section.
* Reflash `releases/boot-saipan-ksu-level.img` to return to this kernel. Your stock `boot.img` goes
  back to stock; keep a MediaTek blankflash package for the case where fastboot is gone.

---

## 6. Access: the Cloudflare tunnel, and why the phone is reachable from anywhere

The container runs `sshd` on **1304**, key-only, hardened by `container-baseline.sh`. That is
reachable three ways:

| route | address | when it works |
|---|---|---|
| tunnel | `ssh motog` / `ssh bagda` | anywhere, through Cloudflare |
| LAN | `ssh motog-lan` | on the same Wi-Fi |
| out-of-band | `su -c 'droidspaces --name=bagda run <cmd>'` | always, from a USB cable |

### 6.1 The tunnel

A **remotely-managed** Cloudflare tunnel named `saipan-motog`, with two published hostnames both
pointing at the container's sshd:

```
motog-ssh.tingao.uk  ->  ssh://localhost:1304
bagda-ssh.tingao.uk  ->  ssh://localhost:1304
                     ->  http_status:404   (catch-all)
```

Both names are published because a tunnel hostname costs nothing and remembering one of two is
easier than remembering which one it was. The catch-all matters: without a terminal rule,
cloudflared refuses to serve anything at all.

The connector lives **inside the container**, so `localhost:1304` is the container's own sshd and
no port forward is involved. cloudflared comes from Cloudflare's apt repo and its token is kept in
a 0600 `EnvironmentFile` rather than in the unit, because the unit is world-readable.

Hardening on top: `StartLimitIntervalSec=0` so systemd never gives up on a flapping handset
uplink, and a 60-second watchdog that restarts the connector when its own `/ready` endpoint stops
answering - two consecutive failures, so an ordinary edge blip that cloudflared re-registers by
itself is left alone.

Verified: `status=healthy`, four QUIC connections (ams06, fra10, fra03, ams18), and `ssh motog` and
`ssh bagda` both land in the container.

### 6.2 The client side

`~/.ssh/config` on the workstation:

```
Host motog bagda motog-ssh motog-ssh.tingao.uk
  HostName motog-ssh.tingao.uk
  User tingao
  IdentityFile ~/.ssh/motog.key
  ProxyCommand .../cloudflared.exe access ssh --hostname motog-ssh.tingao.uk
```

The second hostname is a separate block with the hostname written out, not `%h` - `%h` expands to
whatever alias was typed, so `ssh bagda` would try to proxy to a hostname that does not exist.

Neither hostname has a Cloudflare Access policy, the same as `tokyo-ssh`. Access does not buy much
here anyway: the container's sshd is key-only, so a stolen hostname gets a login prompt and
nothing else.

### 6.3 The MOTD

Every login renders the suite installed by `container-baseline.sh` - system and kernel,
CPU/RAM/disk with the handset's battery on its own line, sshguard counters, listening ports,
fastfetch and the container list. It is the fastest way to tell whether the phone is healthy
without running anything.

---

## 7. Two things the handset does not allow, and one it did

### 7.1 The container kernel-panicked on 2026-09-25, because of apt

```
Kernel panic - not syncing: Out of memory and no killable processes...
(7)[10025:unattended-upgr]
```

Recovered from `/sys/fs/pstore/dmesg-ramoops-0` after the phone rebooted itself.

The container shares the handset's kernel and has **no memory limit**, so a process
inside it can starve Android. `unattended-upgrades` - which the container baseline
enables - ran `apt`/`dpkg`, and the phone has 3.7 GB with Android userspace already
holding most of it. The kernel's OOM killer then found nothing it was allowed to
kill and panicked rather than returning an error.

**"Allowed to kill" is the mechanism, not a figure of speech, and it is §7.3.** Every
task in that panic dump sits at `oom_score_adj = -1000`, which makes it ineligible as
an OOM victim at all, and `mm/oom_kill.c` panics unconditionally when a non-memcg OOM
finds no candidate. So the missing memory limit is only half the story: a cap over
unkillable tasks would have wedged apt at the ceiling and the panic would still have
arrived, just later. Both halves are now fixed.

Worth being precise about where the memory goes, because the obvious suspect is
wrong:

| | RSS |
|---|---|
| the whole container (dockerd + portainer + containerd + cloudflared + systemd) | **~200 MB** |
| `com.google.android.gms` | 437 MB |
| `system_server` | 386 MB |
| `com.google.android.gms.unstable` | 243 MB |
| `com.android.systemui` + Messaging + launcher + dialer + Gboard + Play Store | ~950 MB |

So it is not a leak and not the container being greedy - the phone simply runs tight,
and apt was the thing that tipped it over. **Automatic updates are therefore off**:

```sh
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
```

with `APT::Periodic::*` set to `0` in `/etc/apt/apt.conf.d/20auto-upgrades` so nothing
re-arms them. Updates are a deliberate action now: `apt-get update && apt-get -y upgrade`.

The tuning module also watches `MemAvailable` and logs when it drops below 600 MB,
dropping page cache below 300 MB. That cannot prevent the next one, but it means the
run-up appears in `/data/local/saipan-tuning.log` instead of only in pstore after a
restart.

### 7.2 A container memory limit, and why `memory_limit=` is not how you get one

`memory_limit=` exists in `container.config`, and Droidspaces implements it by writing
`memory.max` - a **cgroup v2** file. Since the v2 move that option now works here, because the
container is on cgroup v2 and the memory controller is delegated down to its cgroup. It is still
not what this setup uses: Droidspaces writes `memory.max` only, and a memory-only cap loses to
zram (finding 3 below), so the cap actually in force is
[`extras/container-memguard/`](../extras/container-memguard/), which sets `memory.max` **and**
`memory.swap.max`.

This page used to claim there was no memory ceiling at all, which was wrong. cgroup v1 has its own
memory controller and it works on this handset. Getting a cap that actually *binds* took four
findings, all measured rather than assumed. They apply to either cgroup version, which is why
they are kept - only the file names differ.

**1. `memory.use_hierarchy` defaults to 0, and that disables hierarchical limits.** With it
off, a cgroup's limit applies only to that cgroup's own charges. Measured: a child cgroup
reached **1008 MB under a 256 MB parent cap with `failcnt` 0** - the parent's limit was never
consulted. So a limit written on `/docker` constrains nothing, because containers live in
`/docker/<id>` beneath it.

**2. It can only be set on a cgroup with no children.** From `mm/memcontrol.c`:

```c
if ((!parent_memcg || !parent_memcg->use_hierarchy) && (val == 1 || val == 0)) {
        if (!memcg_has_children(memcg))
                memcg->use_hierarchy = val;
        else
                retval = -EBUSY;
}
```

`/docker` always has children the moment a container runs, and even stopping Docker and
removing them did not help - the write was still refused with `-EBUSY`. On cgroup v1 the working
approach was a cgroup of our own, created **before dockerd starts**, at
`/sys/fs/cgroup/memory/saipan-guard`, selected with Docker's `cgroup-parent`. It is fresh every
boot, so it is always childless at the moment it is configured:

```json
{ "cgroup-parent": "/saipan-guard" }
```

**That setting had to go when the container moved to v2**, and not because it was untidy: on v2
Docker selects the systemd cgroup driver, which requires a slice name, and dockerd refused to
start at all with

```
failed to start daemon: cgroup-parent for systemd cgroup should be a valid slice named as
"xxx.slice"
```

It is also unnecessary there. v2 gives the container a subtree of its own, so every process is
inside the boundary by construction and there is nothing to point Docker at.

**3. A memory cap alone is not a ceiling, because of zram.** A memory-only cap is satisfied by
swapping, so the process simply carries on. Measured: a **256 MB memory cap held at 255 MB
while a 1024 MB allocation continued happily**. The cap that bites is
`memory.memsw.limit_in_bytes`, which bounds memory *and* swap together. Swap accounting is
enabled on this kernel, so that file is available.

**4. Order matters when writing them.** The invariant `memory.limit <= memory.memsw.limit`
holds at all times, so lowering means writing memory first and raising means writing memsw
first. A fixed order silently fails one direction - it took two attempts to notice.

With those understood the guard is simple: 90% of RAM as the memory cap and 90% of swap as the
swap cap, applied by [`extras/container-memguard/`](../extras/container-memguard/). On cgroup v1
that was 90% of RAM and 90% of RAM+swap as a single `memsw` figure; splitting it the same way on
v2 keeps the combined ceiling identical.

**Verified on a real container**, not just a scratch cgroup, on both cgroup versions:

```
v1   guard dropped to 192 MB, container writing 900 MB
     -> stopped at 233 MB, memory.failcnt 8082
     -> Memory cgroup out of memory: Kill process 26782 (portainer) score 282

v2   container capped at 256 MB, memory.swap.max 0, workload inside the container
     -> oom_kill 7 -> 8, the workload stopped at 128 MB
     -> Memory cgroup out of memory: Kill process 16592 (python3) score 613
     -> container stayed running, portainer untouched
```

Both are **memory cgroup OOM kills**, which is the entire point: the kernel takes the workload
instead of taking the phone down. `system_server`, `zygote` and the framework were never involved
and nothing rebooted.

### 7.3 The part that was actually killing the phone

The cap is not what fixed the panic. This is.

`/sys/fs/pstore/dmesg-ramoops-0` shows the handset going down with

```
Kernel panic - not syncing: Out of memory and no killable processes...
 (7)[10025:unattended-upgr]
```

and **every task in that dump carries `oom_score_adj = -1000`**. That is `OOM_SCORE_ADJ_MIN`, so
none of them is a candidate for `oom_kill()`, and `mm/oom_kill.c` panics unconditionally when a
non-memcg OOM finds no victim. `panic_on_oom` is 0 here, so it was never a tunable.

`-1000` is Droidspaces' own doing, deliberately - `src/utils.c`, `ds_oom_protect()`: *"Set
oom_score_adj to -1000 (unkillable)"* - and everything in the container inherits it. A cap alone
does not save you from that: measured, a cap over unkillable tasks **wedges** the workload
(alive after 30 s, usage pinned at exactly the limit, zero kills) and the panic still arrives
later, from whatever is not in the cgroup.

So the guard resets `oom_score_adj` to 0 on every container process and lets the cgroup cap be
the protection instead. That, plus the isolation the v2 move bought, is what closes the hole -
and neither is visible from `droidspaces check`, which reports every requirement green either
way.

Worth recording what an *unguarded* container does, because it explains the original panic.
Ramping one process with no cgroup limit at all, the phone stayed up while the container
allocated **3840 MB - more than its 3663 MB of physical RAM** - with `MemAvailable` bottoming
at 32 MB and swap at 2001 MB. The kernel's OOM killer never fired once; Android's own
ActivityManager did the work, killing and restarting GMS, the launcher, the IME and
SmsForwarder. Linux plus zram will **thrash rather than fail fast**, which is why a ceiling has
to be imposed rather than hoped for. The practical budget before Android is squeezed below
1 GB free is about **1.5 GB**.
