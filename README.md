# moto g(50) 5G kernel with Droidspaces / Docker container support

A custom Linux kernel for the Motorola moto g(50) 5G (XT2149-1, codename `saipan`, MediaTek
MT6833 / Dimensity 700, Android 12, kernel 4.14.186).

The goal was narrow: run containers on bare-metal Android. Docker inside
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) works on this kernel.
`docker run --rm hello-world` returns 0, with overlay2 and cgroup v1 live inside the container.

Two images, differing by one patch:

| # | image | md5 | what it adds | hardware verified |
|---|---|---|---|---|
| 1 | `boot-saipan-ksu.img` | `6698b76d58dacb34669bfe29cd2646d4` | Droidspaces config, KernelSU-Next root, vendor-module CRC tolerance | yes, flashed and validated |
| 2 | `boot-saipan-ksu-level.img` | `7c852300024f14f5b73e2f2fa8b23fda` | the same, plus a cmdline-selectable CPU DVFS segment | yes, flashed and validated - this is what runs on my handset |

Both are 28,549,120 and 28,551,168 bytes against a 41,943,040-byte boot partition, and both
reuse the stock ramdisk unchanged. Image 2 is a strict superset of image 1: with no
`mtk_cpufreq.level=` on the cmdline it behaves identically, so that is the one I published as
the recommended download.

---

## Why this kernel exists

Two separate problems, and the second one is the reason this took as long as it did.

**1. Stock doesn't do containers.** Motorola's config has no `IPC_NS`, no `USER_NS`, no
`CGROUP_DEVICE`, no `VETH`/`BRIDGE`. Droidspaces will not start a container at all without
them. That part is a config change and a rebuild, and Droidspaces documents exactly which
options are needed.

**2. The published source does not match the device's own modules.** The handset's 17 prebuilt
modules in `/vendor/lib/modules` were built by Motorola from branch
`android-12-release-s1rs32.38-20-7-16`. For that train, the only branch ever published is
`…-20-9` - I checked with `git ls-remote` and there is exactly one match for `s1rs`. Building
`-20-9`, **even with the completely unmodified shipped config**, produces different symbol
CRCs, so `check_version()` refuses every module:

```
motorola_wifi: disagrees about version of symbol module_layout
```

Wi-Fi, Bluetooth, the touchscreen, the fingerprint reader and GPS all go away together, and
the kernel still boots and looks healthy. I measured the difference in a control build - the
same config, one tree revision apart:

| build | `__crc_module_layout` |
|---|---|
| Droidspaces config, `-20-9` | `0xee4b197e` |
| **unmodified stock config, `-20-9`** | `0xbd424614` |

`CONFIG_MODVERSIONS=n` looks like the obvious fix and does not work - it is default-`y` and
gets re-selected, and turning it off would change `VERMAGIC_STRING`, which is the other gate
that rejects these modules. So the kernel keeps `CONFIG_MODVERSIONS=y` (vermagic therefore
stays byte-identical to stock) and patch two lines of `kernel/module.c` so a CRC mismatch
warns once and loads anyway.

That is defensible here specifically because `struct module`'s configuration is provably
identical to stock - every `CONFIG_*` that `include/linux/module.h` references matches between
the two trees - so the mismatch is confined to symbols whose *headers* moved between the two
revisions, not to the ABI the modules rely on. All 17 modules load and every subsystem works.
The reasoning, and the traps that go with it, are in **[docs/KERNEL-NOTES.md](docs/KERNEL-NOTES.md)**.

---

## What works, measured on a retail XT2149-1

| | result |
|---|---|
| Vendor modules | 17 of 17 loaded - Wi-Fi, Bluetooth, touch, fingerprint, GPS, FM, sensors, exFAT |
| Touchscreen | working (`/dev/input/event0` … `event8` all present) |
| Wi-Fi | connected, associated, default route up |
| Root | KernelSU-Next, `su -c id` → `uid=0(root) … context=u:r:ksu:s0` |
| SELinux | **Enforcing** |
| Droidspaces | v6.5.5, container `debian-moto`, Debian 13 trixie, systemd as PID 1 |
| Docker inside the container | Engine 29.8.1, `overlay2`, cgroup driver `cgroupfs`, **cgroup v1**, Compose v5.5.1, `hello-world` rc=0 |
| Kernel release string | `4.14.186+` - byte-identical to the stock vermagic |

## Kernel details

| | |
|---|---|
| Base | `MotorolaMobilityLLC/kernel-mtk`, branch `android-12-release-s1rs32.38-20-9` |
| Version | 4.14.186 (arm64) |
| Toolchain | AOSP `clang-r383902` (clang 11.0.1) + `aarch64-linux-android-4.9` binutils |
| LTO / CFI | `LTO_CLANG`, `THINLTO`, `CFI_CLANG` all preserved at stock settings |
| KernelSU | KernelSU-Next `legacy` branch, `KSU_MANUAL_HOOK=y`, built into the image |
| Container config | `DEVTMPFS`, `CGROUP_DEVICE`, `POSIX_MQUEUE`, `IPC_NS`, `USER_NS`, `CGROUP_PIDS`, `CGROUP_NET_PRIO`, `TMPFS_XATTR`, `TMPFS_POSIX_ACL`, `NF_TABLES`, `NETFILTER_XT_MATCH_ADDRTYPE`, `BRIDGE_NETFILTER`; `SYSVIPC` off |
| Compressed | yes, plain gzip `Image.gz` in the boot image |
| Boot image | header v2, 2048-byte pages, separate `dtb` section, stock ramdisk reused |

> `SYSVIPC` is off on purpose even though Droidspaces' non-GKI list mentions it. `IPC_NS`
> only `depends on (SYSVIPC || POSIX_MQUEUE)`, so `POSIX_MQUEUE` alone satisfies it - and
> `SYSVIPC` inserts `sysvsem`/`sysvshm` into `struct task_struct` *before* `fs`, `files`,
> `nsproxy`, `signal` and `sighand`, shifting offsets the prebuilt vendor modules depend on.
> `POSIX_MQUEUE` only adds one field to `struct user_struct`, which they do not touch.

## Droidspaces notes

Three non-default settings are required to get nested containers running on 4.14, and I found
all three by hitting the failure first:

```sh
droidspaces --name=debian-moto start --net=nat --hw-access --privileged=noseccomp --force-cgroupv1
```

* **`--privileged=noseccomp`** - on legacy kernels (3.18-4.19) Droidspaces intercepts
  namespace syscalls and returns `EPERM` to dodge the 4.14 VFS deadlock. containerd's shim
  needs those syscalls, so `docker run` dies with `failed to create TTRPC connection`.
* **`--force-cgroupv1`** - the default is cgroup v2, and on v2 runc *must* program device
  rules with BPF. 4.14 has no `BPF_CGROUP_DEVICE` prog-query support, so it fails with
  `bpf_prog_query(BPF_CGROUP_DEVICE) failed: invalid argument`. Forcing v1 puts runc on the
  legacy devices cgroup, which this kernel does support.
* **A systemd drop-in inside the container.** Docker CE's unit uses `-H fd://` (socket
  activation), which failed here with `no sockets found via socket activation`. A drop-in
  replaces it with plain `-H unix:///var/run/docker.sock`.

Also: the Debian 13 base image ships Debian's own `docker-compose` 2.26.1, which owns
`/usr/libexec/docker/cli-plugins/docker-compose` and collides with `docker-compose-plugin`.
Remove the former before installing the plugin.

Full write-up, with the verification commands: **[docs/SERVER-SETUP.md](docs/SERVER-SETUP.md)**.

## CPU clocks

The MT6833 cpufreq driver carries three OPP tables and picks one from an efuse segment code,
so the 2.4 GHz table is present in the source even on parts binned for 2.2 GHz. I made the
choice switchable from the boot image cmdline and then measured all three.

| segment | big cluster | sysbench, pinned to cpu6 | verdict |
|---|---|---|---|
| `FY` (stock) | 2,203,000 kHz | **529.2 events/s** | fastest measured - this handset's efuse value |
| `B20G` | 2,000,000 kHz | 480.5 events/s (−9.2 %) | exactly 2000/2203; underclock works as expected |
| `B24G` | 2,400,000 kHz | **288.2 events/s (−45 %)** | rejected - the driver reports 2.4 GHz under load, the silicon does not deliver it |

So the handset stays on the stock segment, and I am not shipping an overclock. The measurements
and what they rule out are in **[docs/CPU-CLOCK.md](docs/CPU-CLOCK.md)**.

## Flashing

Read [FLASHING.md](FLASHING.md) first. Short version:

* Unlocked bootloader required. **Never relock it on a Motorola MTK device** - it programs an
  efuse and can leave a phone that will not flash anything, including official firmware.
* Only the `boot` partition is touched. Nothing here modifies `dtbo`, `vbmeta` or `super`.
* Back up your current `boot` partition before you write anything, and read it back to verify.
* `build/flash-boot.ps1` does the flash and waits for `sys.boot_completed`;
  `-Restore` puts the stock image back.

## Building it yourself

```sh
git clone <this repo>
cd build
./build-ksu-level.sh
```

You supply Motorola's kernel source and the AOSP toolchain yourself - [SOURCE.md](SOURCE.md)
explains why and where from. [build/README.md](build/README.md) has the expected layout, the
KernelSU-Next version, and how to pack the resulting `Image.gz` into a boot image.

## Running a container server on it

A phone that serves something is woken by nobody, so a few userspace behaviours matter more
than they would on a desktop. `extras/` has the KernelSU module I use:
[extras/README.md](extras/README.md).

* **It suspends, and the tunnel dies with it.** When this handset deep-suspends, the Wi-Fi
  driver's suspend path fails and the radio stops passing traffic, so anything reached over
  the network goes away until somebody touches the screen. The module holds a kernel wakeup
  source. [docs/KEEP-AWAKE.md](docs/KEEP-AWAKE.md).
* **A charger left connected at 100 % is the fastest way to wear the cell.** The module keeps
  the pack in a 75-80 % band through Motorola's own `qpnp_adaptive_charge` parameters.
* **Android's power and thermal HALs rewrite these files underneath you.** Everything the
  module applies is re-asserted by a watchdog every 60 s, because a one-shot boot script
  does not stay applied on this device.

## Not included

* Any kind of thermal or performance kernel tweak. `extras/` offers CPU ceilings and a
  governor, and on this hardware those are the honest levers; the measured result of pushing
  the big cluster beyond its bin is that throughput *falls*, so there is nothing to gain here.
* A GPU story. I never tested GPU access from inside the container on this device.
* GPU/vendor firmware of any kind, or Motorola's userspace.

## Licence

The Linux kernel is GPLv2. My changes ship under the same terms - see [LICENSE](LICENSE).
Motorola's proprietary components are not redistributed here. Read [SOURCE.md](SOURCE.md)
and [NOTICE.md](NOTICE.md) before reusing anything from this repository.

## Credits

* [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) by ravindu644 - the container
  runtime this kernel is tuned for, and the source of the non-GKI option list and the three
  container settings above.
* [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) - root, on its `legacy`
  branch.
* Motorola, for publishing the kernel source for this device at all.
