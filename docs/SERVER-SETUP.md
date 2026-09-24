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
| Container | `debian-moto` - Debian GNU/Linux 13 (trixie), systemd as PID 1, NAT network, `172.28.205.17`, `run_at_boot=1` |
| Inside | Docker Engine 29.8.1, `overlay2`, cgroup driver `cgroupfs`, **cgroup v1**, Compose v5.5.1 |
| Host tuning | ACC holds the pack at 55-60 % (qpnp band 75-80 % as a backstop), wakeup source `saipan-awake`, CPU ceilings, SIM-driven airplane mode - all re-asserted every 60 s |
| SELinux | **Enforcing** - permissive only during setup |

---

## 2. The three container settings that make Docker work on a 4.14 kernel

Nested containers on this kernel need three non-default settings. I found all three by hitting
the failure first, and all three are persisted in
`/data/local/Droidspaces/Containers/debian-moto/container.config`.

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
4.14 has no `BPF_CGROUP_DEVICE` prog-query support. Forcing cgroup v1 puts runc on the legacy
devices cgroup, which this kernel does support.

Droidspaces' docs recommend `cgroupfs` plus the `vfs` storage driver for legacy kernels.
`cgroupfs` was necessary; `vfs` was not - `overlay2` works here, and the base image's own
docker had already proven it.

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
state every minute instead of being hard-coded: no SIM means airplane mode on with Wi-Fi kept
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
su -c "/data/local/Droidspaces/bin/droidspaces --name=debian-moto run docker info"
su -c "/data/local/Droidspaces/bin/droidspaces --name=debian-moto run docker run --rm hello-world"

# tuning log
su -c "tail -30 /data/local/saipan-tuning.log"
```

Get a shell in the container:

```sh
su -c "/data/local/Droidspaces/bin/droidspaces --name=debian-moto enter"
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
