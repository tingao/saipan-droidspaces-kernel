# extras: the device-side tuning I run on the server phone

None of this is part of the kernel. It is the user-space half - the things that make a rooted
handset behave like a box that is up all the time - and it is here because the kernel alone
does not get you there.

| item | what it does |
|---|---|
| `saipan-tuning/` | KernelSU module: battery charge band, keep-awake wakeup source, CPU ceilings, Wi-Fi watchdog |
| `verify-tuning.sh` | prints the current state of all of the above, so you can check rather than assume |
| `container-no-suspend.sh` | run **inside the container**: stops it from being able to suspend the phone |

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

### Battery charge band

```
/sys/module/qpnp_adaptive_charge/parameters/upper_limit   -> 80
/sys/module/qpnp_adaptive_charge/parameters/lower_limit   -> 75
/sys/module/qpnp_adaptive_charge/parameters/blocking      -> 1
```

Leaving a phone permanently at 100 % on a charger is the fastest way to wear the cell. A 75-80 %
band keeps it near the flat part of the Li-ion voltage curve.

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

## What this does not do

* No debloating. I did not disable any preinstalled app on this device and I am not shipping a
  list I have not tested here.
* No GPU settings. I never tested GPU access from inside the container on this phone.
* Nothing about the modem. This handset has no SIM and I have not looked at whether the radio
  is drawing anything worth recovering.
