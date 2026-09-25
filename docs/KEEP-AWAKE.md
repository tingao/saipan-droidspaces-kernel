# Keeping the phone awake, so the container and its tunnel survive

**Symptom.** Whatever the phone serves disappears "after a while" and comes back the moment
somebody touches the screen. Nothing has crashed: `docker ps` is healthy once you get back in,
and the container never restarted.

**Cause.** The handset deep-suspends. When it does, the Wi-Fi driver's suspend path fails - the
same class of failure I hit on the Galaxy S8+ and the S21 - and the radio stops passing traffic.
While suspended the container is frozen too, so a network connector cannot keep its heartbeats
alive and every published hostname stops answering until something wakes the screen.

**Fix.** Hold a kernel wakeup source, so the kernel never suspends:

```sh
echo saipan-awake > /sys/power/wake_lock      # hold
echo saipan-awake > /sys/power/wake_unlock    # release
```

`/sys/power/wake_lock` is labelled `sysfs_wake_lock` and is already writable on this device -
unlike the charge band and the cpufreq nodes, it needs no SELinux rule. The
`extras/saipan-tuning` KernelSU module holds it for you.

> The lock is **not** tied to the writing process. The script exits immediately and the wakeup
> source stays active until the name is written to `wake_unlock`. That is why a one-shot boot
> script is enough, and why you cannot test it by checking whether a process is still running.

## What I inherited and what I verified here

The mechanism is not specific to this handset - I found it on the S8+ and the S21 first, and
this phone behaves the same way. Being precise about what is measured on *this* device, since
these write-ups are worth less if they blur together:

| | |
|---|---|
| verified here | the wakeup source is held and survives a cold boot (`cat /sys/power/wake_lock` → `saipan-awake`) |
| verified here | the container stays reachable over the network with the screen off, which is the actual requirement |
| inherited, not re-derived here | the specific Wi-Fi driver suspend failure. I did not reproduce it from a clean state on this phone - I applied the fix from the start, because I already knew the class of problem. |

If you want to see it for yourself, release the lock and leave the phone alone:

```sh
su -c 'echo saipan-awake > /sys/power/wake_unlock'
su -c 'dmesg | grep -c "PM: suspend entry"'      # sample this over time
```

A **gap** in samples taken over time is the proof - a suspended kernel cannot run your sampler.
Do not judge by the battery percentage: with the charge band holding the pack in a fixed range,
the gauge sits still whether the phone slept or not.

## The policy knob

`AWAKEN_POLICY` in `extras/saipan-tuning/tuning.conf`:

| value | behaviour |
|---|---|
| `always` | always hold the lock - maximum uptime, standby drain rises |
| `charging` | hold only while on external power (what I run) |
| `off` | never hold it - stock behaviour |

`charging` is the right default for a phone that lives on a cable. Mine reads charger and USB
online and holds the lock; the battery still reports `Discharging` most of the time, which is
not a contradiction - the charge band is holding the pack at 80 % so the device runs off the
battery while the cable keeps it topped up.

## Costs

* Standby drain rises from roughly nothing (suspended) to about **1-3 %/h**. Free on the cable;
  it turns "days" into "hours" unplugged.
* Temperatures sit a few degrees higher, because the SoC no longer idles in suspend.
* Revert: set `AWAKEN_POLICY=off` and reboot, or release the lock immediately with the command
  above.

## The other half: the container must not be able to sleep the phone

Worth knowing before it bites you. Inside the container, systemd-logind sees the handset's
lid/power/idle events, and with hardware access enabled a `systemd-suspend.service` there
suspends the **whole phone**. On the S8+ this only failed with `Device or resource busy` by
luck.

`extras/container-no-suspend.sh` closes it: logind is told to ignore every switch and idle
action, and every sleep target is masked.

```sh
sh /path/to/container-no-suspend.sh
```

On a headless server phone the local revert path is the whole point - a suspend that succeeds
takes the box off the air until somebody physically touches it.

## The display is allowed to sleep, and that is deliberate

An early version of `extras/saipan-tuning` set `stay_on_while_plugged_in=7` and a
`screen_off_timeout` of 2147483647 ms. That was wrong, and it is worth saying plainly why:
what keeps this handset serving is the kernel wakeup source taken in `service.sh`, which keeps
CPU and radio alive **whether or not the panel is lit**. The panel was doing no work, and a
phone left face-up with its screen on for days is how you get image retention.

Both settings are now `0` and `60000` (one minute), re-asserted by the watchdog because
`service.sh` often runs before the settings service is up and its `settings put` then fails
silently.

**Measured on saipan, so nobody has to re-litigate it:** pausing and resuming the charge path
the way ACC does - writing `1` then `0` to `/proc/mtk_battery_cmd/en_power_path` - does **not**
wake the display here. Four toggles with the screen asleep produced zero `power_screen_state`
events, and `dumpsys battery` still reported `AC powered: true` in the paused, resumed and
paused-again states.

This ROM does carry the trap (`mWakeUpWhenPluggedOrUnpluggedConfig=true`), so the check was
worth running: on the S8+ and S21 the same ACC behaviour made the kernel report the charger
offline, Android saw an unplug, and the screen lit for about ten minutes several times an hour.
Saipan's MTK charger driver keeps reporting the AC source regardless of `en_power_path`, so the
wake-on-plug path is never reached and no overlay to force `config_unplugTurnsOnScreen=false`
is needed. That is fortunate - mounting an RRO for it is what took `system_server` down on the
S21.

## Two things this is often confused with

* **The battery percentage is not evidence of anything.** See above.
* **A paused charge path does not look like an unplugged charger.** While ACC is holding inside
  its band on saipan, `/sys/class/power_supply/usb/online` reads `0` and
  `/sys/class/power_supply/battery/status` still reads `Charging`, yet Android reports
  `AC powered: true`. None of those four readings disagree with each other, and none of them
  means the cable is data-only or the charger is dead. An earlier revision of this file claimed
  `online=1` with `Discharging`; that was never measured on this device and is wrong.
