# extras: the device-side tuning I run on the server phone

None of this is part of the kernel. It is the user-space half - the things that make a rooted
handset behave like a box that is up all the time - and it is here because the kernel alone
does not get you there.

| item | what it does |
|---|---|
| `saipan-tuning/` | KernelSU module: battery charge band, keep-awake wakeup source, CPU ceilings, SIM-driven airplane mode, Wi-Fi watchdog |
| `saipan-tuning/airplane-mode.sh` | the airplane-mode policy on its own: `auto\|on\|off\|status` |
| `verify-tuning.sh` | prints the current state of all of the above, so you can check rather than assume |
| `container-no-suspend.sh` | run **inside the container**: stops it from being able to suspend the phone |
| `debloat-apply.sh` + `debloat-list.txt` | reversible debloat for a headless device: 111 Motorola, carrier, Google and AOSP packages, with the keep-list written down and every action logged to a rollback script |

Battery charging itself is not in this directory - it is **ACC** (Advanced Charging Controller), a
separate KernelSU module, because that is what the other two phone servers in this estate use.
See [Battery: ACC](#battery-acc) below.

## Installing the KernelSU module

```sh
adb push saipan-tuning /data/local/tmp/
su -c 'dd if=/data/local/tmp/saipan-tuning/module.prop of=/dev/null'   # (just checking the push)
# then, as root on the device:
mkdir -p /data/adb/modules/saipan-tuning
cp -r /data/local/tmp/saipan-tuning/. /data/adb/modules/saipan-tuning/
reboot
```

Do not use `cp` to move files around from inside the KernelSU `su` domain if it fails with
`Permission denied` on a path you know is writable - `cp` tries to restore mode and ownership,
which that domain cannot always do. `dd` works.

Then check it:

```sh
su -c 'sh /data/local/tmp/verify-tuning.sh'
su -c 'tail -30 /data/local/saipan-tuning.log'
```

## What the module does

`service.sh` runs once at boot, applies everything, and detaches `watchdog.sh`, which
re-applies it every 60 seconds.

**The watchdog is the point, not a nicety.** Android's own power and thermal HALs rewrite these
files underneath you, and a lock/suspend cycle can leave Wi-Fi switched off. A one-shot boot
script does not stay applied on this device - I have watched the charge band revert within
minutes.

### Battery charge band (backstop only)

```
/sys/module/qpnp_adaptive_charge/parameters/upper_limit   -> 80
/sys/module/qpnp_adaptive_charge/parameters/lower_limit   -> 75
/sys/module/qpnp_adaptive_charge/parameters/blocking      -> 1
```

**This band does not normally do anything.** ACC holds the pack at 55-60 %, well below it. The
qpnp band is set deliberately *above* ACC's so the two never fight, and it exists only as a
backstop: if `accd` ever stops, the charger driver still stops the pack at 80 % instead of
letting it run to 100 %. Remove it and the failure mode of a dead ACC daemon becomes a battery
held at full charge on a permanent cable, which is the thing all of this is meant to avoid.

**The write order matters and is not obvious.** Writing `upper_limit` resets `lower_limit` to
`-1` in this driver, so the scripts always write upper first, then lower. Verified on-device:

```
echo 75 > lower; echo 80 > upper   ->  reads back 80/-1   (lower lost)
echo 80 > upper; echo 75 > lower   ->  reads back 80/75   (correct)
```

Set `CHARGE_UPPER=-1` in `tuning.conf` for stock behaviour.

`tuning.conf` **must be LF-terminated.** With CRLF, `echo "$CHARGE_UPPER"` writes `"80\r"`, the
driver rejects it, and the band silently stays disabled while the watchdog cheerfully logs
"re-asserted" every minute. If you edit this file on Windows, save it as LF.

### Keep-awake

```
AWAKEN_POLICY = always | charging | off
```

Holds a kernel wakeup source so the handset does not deep-suspend and drop off the network.
Reasoning and costs: [../docs/KEEP-AWAKE.md](../docs/KEEP-AWAKE.md).

### CPU clocks

Ceilings and governor, re-asserted every minute. The defaults in `tuning.conf` are the stock
values for this handset's DVFS segment, so the mechanism is in place and changes nothing.

`tuning-uc.conf` is the underclock drop-in (big cluster capped at 2,000,000 instead of
2,203,000). Copy it over `tuning.conf` if you run something that pins the big cores - it
measured −9.2 % throughput, which is exactly the clock ratio, and on light load it buys no
thermal headroom (28.6-29.2 °C in both configurations).

There is deliberately **no overclock config**, because the one I built was rejected on evidence:
the driver's 2.4 GHz table is another speed-bin's clock plan, and on an FY-binned part it
reports 2.4 GHz while delivering about 45 % less throughput. Do not put `CPU_BIG_MAX=2400000`
in this file and assume it did something useful. Details:
[../docs/CPU-CLOCK.md](../docs/CPU-CLOCK.md).

### SELinux

Every interesting knob sits under a vendor-specific sysfs label that the KernelSU `su` domain
cannot write to by default:

| path | label |
|---|---|
| `/sys/module/qpnp_adaptive_charge/parameters/{upper,lower}_limit` | `vendor_sysfs_battery_supply` |
| `/sys/devices/system/cpu/cpu*/cpufreq/*` | `sysfs_devices_system_cpu` |
| `/proc/mtk_battery_cmd/en_power_path` | `proc_battery_cmd` (ACC's charging switch) |
| `/sys/class/power_supply/*/status`, `charge_type` | `sysfs_batteryinfo` |

Reads worked; only writes were denied. `sepolicy.rule` grants write on exactly those two labels
to `ksu`, `droidspacesd`, `init` and `vendor_init`, rather than allowing sysfs broadly or
running the phone permissive. SELinux stays **Enforcing**.

`/sys/power/wake_lock` is deliberately not listed - it is `sysfs_wake_lock` and is already
writable.

### The Android settings the module also sets

```
settings put global stay_on_while_plugged_in 7
settings put system  screen_off_timeout 2147483647
```

`service.sh` sets these at boot, but at that moment the settings service is frequently not up
and `settings put` fails silently - the boot log shows `stay_on_while_plugged_in=` with nothing
after it. The watchdog re-asserts them once the framework is definitely running, so the value
does not depend on catching the boot window.

## Debloating

`debloat-apply.sh debloat-list.txt`, as root on the device. It uses
`pm disable-user --user 0`, which is reversible with one command per package, leaves the APK on
the system partition so a mistake cannot leave the handset without something it needs to boot,
and writes a rollback script before it changes anything.

`debloat-list.txt` carries the **keep-list as well as the disable-list**, in the header, because
that is the half that is easy to get wrong. The short version: launcher, Settings, biometrics
(the touchscreen on this handset has failed before, so no fallback path gets removed), thermal
and SAR services, the hardware test and diagnostic apps, telephony, RRO overlays, Droidspaces
and KernelSU. Play, GMS and GSF are kept because Play needs them and the framework is happier
with them present - their background execution is restricted instead of disabled.

Five packages **cannot** be disabled on this ROM, including both Motorola OTA updaters:
`pm disable-user` and `pm uninstall --user 0` both answer `Failure: package is non-disable`,
`com.motorola.paks` answers `package is protected`, and `pm hide` reports `new hidden state:
false` without sticking. For those the script strips background execution with appops and
force-stops them. The OTA updaters are the ones that matter: an over-the-air update on an
unlocked bootloader with a custom kernel is how this device gets bricked.

## What this does not do

* No GPU settings. I never tested GPU access from inside the container on this phone.
* Nothing about the modem beyond the airplane-mode policy above - I have not measured what the
  radio draws when idle.
