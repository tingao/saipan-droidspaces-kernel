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
| `sms-telegram/` | every SMS the handset receives, forwarded to a Telegram bot. A KernelSU module on the phone plus a systemd timer in the container |

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

### Battery: ACC

Charging is controlled by **ACC (Advanced Charging Controller) v2023.10.16**, installed as a
KernelSU module - the same module and the same version the S8+ runs, and the same idea the S21
runs.

```
capacity=(0 101 55 60 false false)                            pause 60, resume 55
chargingSwitch=(/proc/mtk_battery_cmd/en_power_path 1 0 --)   MTK charger, pinned
temperature=(40 60 90 65)                                     mirrored from the S8+/S21
prioritizeBattIdleMode=false                                  mirrored from the S8+/S21
```

The switch was **verified by hand before being trusted**, because ACC's auto-detection has failed
on this estate before (on the S8+ it came up with no switch at all and charged to 100 % while
looking configured):

```
echo 0 > /proc/mtk_battery_cmd/en_power_path   ->  current_now  +503 mA  ->  -127 mA
echo 1 > /proc/mtk_battery_cmd/en_power_path   ->  current_now  -127 mA  ->  +466 mA
```

Two things about that interface are worth knowing:

* **It takes a bare value.** `"0 0"` and `"1 0"` are accepted by the shell and silently ignored
  by the driver - the node reads back `1` either way. Only `echo 0` / `echo 1` do anything.
* **`status` keeps reporting `Charging` while the power path is off**, because the charger is
  still attached. The only reliable signal is the sign of `current_now`. That is exactly what
  ACC's `battStatusWorkaround` (on by default) handles, which is why the switch works with ACC
  even though it looks contradictory.

ACC needs write access to `proc_battery_cmd`, which the KernelSU `su` domain does not have by
default - see the SELinux section below.

**ACC is a KernelSU module, so it does not appear in the app drawer.** That is expected, not a
failed install: there is no APK, only `accd`, `/data/adb/modules/acc/`, and the config at
`/data/adb/vr25/acc-data/config.txt`. For a GUI, install **ACC Settings**
([CrazyBoyFeng/AccSettings](https://github.com/CrazyBoyFeng/AccSettings),
package `crazyboyfeng.accSettings`, v2022.6.7, targetSdk 32):

```
adb install app-debug.apk
```

It is a front-end for an ACC that is already installed, so it reads and writes the config above
rather than replacing it. The alternative front-end,
[AccA](https://github.com/MatteCarra/AccA), **ships its own copy of ACC and installs it on first
launch** - the wrong shape here, because it would fight the KernelSU module that is already
configured.

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

Set `CHARGE_UPPER=-1` in `tuning.conf` for stock behaviour on the qpnp side.

`tuning.conf` **must be LF-terminated.** With CRLF, `echo "$CHARGE_UPPER"` writes `"80\r"`, the
driver rejects it, and the band silently stays disabled while the watchdog cheerfully logs
"re-asserted" every minute. If you edit this file on Windows, save it as LF.

### Airplane mode, driven by the SIM

The cellular modem is powered whether or not it is useful. Whether it *is* useful depends on the
SIM, which can change while the phone is deployed, so the policy is decided from the handset's
own SIM state rather than hard-coded - hourly by default (`SIM_CHECK_EVERY=60`):

| `AIRPLANE_POLICY` | behaviour |
|---|---|
| `auto` (default) | **SIM fitted → airplane mode OFF**; no SIM → airplane mode ON, Wi-Fi kept alive |
| `always` / `never` | force it on or off regardless of the SIM |

How often it re-evaluates is `SIM_CHECK_EVERY`, counted in watchdog passes - the watchdog ticks
every 60 s, so **60 is hourly** and is what this runs at. A SIM change is therefore noticed within
the hour, or the hour after that for removal, since the policy waits for a second `ABSENT` reading
before cutting the radio. Set it to `1` for every minute (what you want if you are swapping SIMs),
or `1440` for daily. Re-evaluating is only two property reads, so the setting is purely about
reaction time.

`saipan-tuning/airplane-mode.sh auto` does the work; `status` prints the verdict, the raw modem
reading and the absence streak, so there is nothing to infer.

Stated once more, because it has been read backwards: **a SIM in the phone means airplane mode
off.** The modem only gets cut when it reports a positive `ABSENT`.

What this gets right, each of which it got wrong first:

* **`UNKNOWN` is not "no SIM".** At boot, and during any modem reset, the modem reports `UNKNOWN`
  before it has read the card. Treating that as absent turned airplane mode on for a handset that
  has a SIM - it appears in the tuning log as `airplane ON (sim=READY)` immediately after
  `Can't find service: settings`, on every boot. Only a positive `ABSENT` counts now, so the
  failure mode is "the modem stays powered", which costs a little battery, rather than "the phone
  was taken off the air".
* **Two consecutive `ABSENT` readings are required** before the radio is cut. One reading during a
  modem reset is not worth taking a phone off the air for, and the check runs hourly, so
  waiting costs nothing.
* **The module does not act before the settings service is up**, because `settings put` fails
  silently before then and leaves a half-applied state.
* **`wifi` is removed from `airplane_mode_radios`.** Airplane mode normally switches Wi-Fi off
  too. On a headless server that is fatal: after a reboot the framework applies airplane mode
  before anything can re-enable Wi-Fi, and the phone comes up with no network at all.
* **It reverts itself.** After enabling airplane mode it waits up to 60 s for an address *and* a
  successful ping, and restores the previous state if neither arrives. Nobody is holding this
  phone, so the revert has to be local.
* **The log says why.** `airplane ON - no SIM fitted (modem reports ABSENT)` and
  `airplane OFF - SIM fitted (modem reports LOADED, LycaMobile)`. The earlier bare
  `airplane ON (sim=READY)` read as if the policy were inverted, which is exactly how it was
  misread.

`gsm.sim.state` stays readable with the radio cut - verified on this handset - which is what
makes the check safe to evaluate in either direction.

### Keep-awake

```
AWAKEN_POLICY = always | charging | off
```

Holds a kernel wakeup source so the handset does not deep-suspend and drop off the network.
Reasoning and costs: [../docs/KEEP-AWAKE.md](../docs/KEEP-AWAKE.md).

### CPU clocks

Ceilings and governor, re-asserted every minute. The defaults in `tuning.conf` are the stock
values for this handset's DVFS segment, so the mechanism is in place and changes nothing.

`tuning-uc.conf` is the **underclock** drop-in: big cluster capped at 2,000,000 kHz instead of
2,203,000. It works exactly as advertised - throughput falls 9.3 %, which is the clock ratio to
0.15 %, and the hardware PLL readback confirms 1,999,000 kHz against 2,202,000. On light load it
buys no thermal headroom (28.6-29.2 °C either way), which is why the default is stock; if you run
something that pins the big cores it becomes a real lever.

There is deliberately **no overclock config** - not because the overclock is slower, but because
it is *nothing*. Under `B24G` the driver reports 2.4 GHz through cpufreq while its own DVFS
interface reports 2,202,000 kHz, so the PLL never moves, throughput is unchanged (929.6 against
927.9 events/s), and the core voltage is 43.75 mV higher. Do not put `CPU_BIG_MAX=2400000` in this
file and assume it did something useful. Details, and a correction to an earlier wrong figure:
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

Reads worked; only writes were denied. `sepolicy.rule` grants write on exactly those labels -
`vendor_sysfs_battery_supply`, `sysfs_devices_system_cpu`, `proc_battery_cmd` and
`sysfs_batteryinfo` - to `ksu`, `droidspacesd`, `init` and `vendor_init`, rather than allowing
sysfs broadly or running the phone permissive. SELinux stays **Enforcing**.

The rules are applied by KernelSU at boot from the module's `sepolicy.rule`. To change them
without rebooting, `ksud sepolicy apply <file>` works on a live device, which is how the ACC
switch was proven before anything was made permanent.

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

## SMS to Telegram

Every SMS the handset receives is posted to a Telegram bot. There are **two
independent implementations**, and only one should be enabled at a time or every
message arrives twice.

### The script (`sms-telegram/`)

Split across the two sides, because each has something the other lacks:

| where | what | why there |
|---|---|---|
| phone, KernelSU module | copies `mmssms.db` into the container's spool whenever it changes | the container cannot see `/data/data` |
| container, systemd timer | reads the copy with `sqlite3` and posts with `curl` | the phone's only HTTP client is busybox `wget`, which prints *"TLS certificate validation not implemented"* |

Two decisions worth recording:

* **The database, not `content query`.** A message body can contain newlines,
  commas, quotes, tabs and anything else, and `content query` prints rows as
  `Row: N column=value` with the value pasted in raw. Parsing that from mksh is a
  losing game. The container reads the SQLite file directly, so a body is never
  parsed at all.
* **The database is copied into the container's own rootfs**, which is a directory
  on `/data`. That needs no bind mount and no container restart. The copy is
  written as `.part` and renamed, so the container never opens a half-written file.

State lives in `/var/lib/sms-telegram/last_id`, a high-water mark on the message
`_id`. Two edge cases it handles, both of which it got wrong first:

* **An empty inbox has `max(_id) = 0`.** Testing `last = 0` to mean "first run"
  meant every pass looked like a first run and the mark never settled. The test is
  the state file's existence.
* **`_id` can go backwards.** A factory reset or a restore-from-backup restarts it
  at 1, and a stale high-water mark would then compare every new message as
  already seen and skip it forever. If the snapshot's maximum is *below* the mark,
  the mark is reset.

Delivery failures do not advance the mark, so a message that fails to send is
retried on the next pass rather than lost.

### The app (SmsForwarder)

Installed as `cn.ppps.forwarder` and configured with a Telegram Bot sender plus an
SMS rule. It is the more battle-tested of the two, so it is the one enabled; the
script sits ready as the backup.

Configuring it needed two things that are worth knowing:

* **`sender_list` can never be empty.** `ConvertersSenderList.stringToObject()` does
  `value.split(",").map { it.trim().toLong() }`, and `"".split(",")` is `[""]`, so an
  empty string throws `NumberFormatException` and the Rules screen crashes. The
  column is `NOT NULL` too, so NULL is not an option either - it must contain at
  least one sender id.
* **The sender dropdown renders in a separate `PopupWindow`**, which `uiautomator
  dump` does not capture, so it cannot be driven by scripted taps. The sender row
  was created through the app's own form; the rule row was written directly into
  the SQLite database in the shape the app's schema expects.

Credit where it is due: [pppscn/SmsForwarder](https://github.com/pppscn/SmsForwarder).