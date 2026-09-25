# Releases

Five boot images. All reuse the stock Motorola ramdisk and DTB unmodified, and all are smaller
than the 41,943,040-byte (40 MiB) `boot` partition.

| # | file | size | md5 | hardware verified |
|---|---|---|---|---|
| 1 | `boot-saipan-ksu.img` | 28,549,120 | `6698b76d58dacb34669bfe29cd2646d4` | yes, flashed and validated |
| 2 | `boot-saipan-ksu-level.img` | 28,551,168 | `7c852300024f14f5b73e2f2fa8b23fda` | yes, flashed and validated |
| 3 | `boot-saipan-ksu-cgroupv2.img` | 28,551,168 | `eb78643f05b09394d9c0037eeba54108` | yes, flashed and validated |
| 4 | `boot-saipan-ksu-noprefix.img` | 28,551,168 | `6b1bccb22fe169b5ecee08693239f213` | yes, flashed and validated |
| 5 | `boot-saipan-ksu-cgroupv2-mem.img` | 28,551,168 | `f5e522848d0432f7eac3f728691dc21e` | yes, flashed and validated - **what runs on my handset** |

## Which one do I want?

**Download `boot-saipan-ksu-cgroupv2-mem.img`** (image 5), and install
[`extras/cgroupv2-delegate`](../extras/cgroupv2-delegate/) as a KernelSU module. That is the
current configuration and it is the only image here whose container memory cap actually covers
the whole container.

Images 4 and 5 carry the same kernel as image 3 plus Droidspaces' cgroup v1 `noprefix` fix
([docs/CGROUP-V2.md](../docs/CGROUP-V2.md) §10), which restores `cpuset.cpus` / `cpuset.mems` —
Android mounts `/dev/cpuset` with `noprefix`, so before this patch those names did not exist at
all and anything using the standard cgroup v1 names got `ENOENT`. They differ from each other
**only in the command line**:

| | kernel cmdline | container memory |
|---|---|---|
| image 4 | `bootopt=64S3,32N2,64N2 buildvariant=user` | on cgroup **v1**; Android keeps `/dev/memcg` |
| image 5 | the same **+ `cgroup_no_v1=memory`** | on cgroup **v2**; lmkd falls back to PSI |

Image 4 is the honest fallback: if the v2 arrangement misbehaves for you, flashing it puts
`memory` back on v1 and Android back on its own memcg-based killer, with the `noprefix` fix
retained. What you give up is cgroup isolation, and with it any cap that covers more than the
Docker workloads — see §7.3.

The earlier images are published because they are the builds that were flashed and validated
first, and keeping them makes the history honest.

## What was checked on all five

```
size                  < 41,943,040 bytes
vermagic              == 4.14.186+ SMP preempt mod_unload modversions aarch64
LTO / CFI             == CONFIG_LTO_CLANG=y, CONFIG_CFI_CLANG=y, CONFIG_THINLTO=y
vendor modules        == 17 of 17 load; Wi-Fi, Bluetooth, touch, fingerprint, GPS, FM, sensors
SELinux               == Enforcing
root                  == KernelSU-Next, su -c id -> uid=0 context=u:r:ksu:s0
Docker in Droidspaces == Engine 29.8.1, overlay2, hello-world rc=0
cgroup v2 (3, 5)      == bpf_prog_query(BPF_CGROUP_DEVICE) succeeds, and a device program
                         attaches and enforces EPERM; kernel panics 0, real BUG: 0
noprefix (4, 5)       == /dev/cpuset/cpuset.cpus exists and reads 0-7 inside the container
cgroup v2 in use (5)  == runc's device program is visible on the Docker scope:
                         BPF_CGROUP_DEVICE -> ret=0 attach_flags=0x2 prog_cnt=1
```

## Image 5 specifically

Verified after an unattended reboot with no manual steps:

```
cmdline                cgroup_no_v1=memory
container              bagda on cgroup v2 (force_cgroupv1=0), Debian 13, systemd running
memory.max             3457220608        (90% of RAM)
memory.swap.max        2592911360        (90% of swap)
coverage               0 of 25 container processes outside /droidspaces/bagda
oom_score_adj          0 on every container process except the two [ds-monitor] helpers
panics / BUG:          0 / 0
```

The cap was then tested live: with the container capped at 256 MB, a workload inside it was
killed by the kernel (`Memory cgroup out of memory: Kill process 16592 (python3) score 613`)
while the container and Portainer carried on.
