# Container memory guard

A memory ceiling for the whole `bagda` container, sized so the container keeps **90% of the
phone's RAM** while a runaway is still stopped instead of taking the handset down.

```sh
sh install.sh      # inside the container, as root
```

It installs `/usr/local/sbin/saipan-memguard.sh` plus two units, and — importantly on cgroup
v2 — **removes** `"cgroup-parent"` from `/etc/docker/daemon.json` if an older install put it
there, because on v2 that setting stops Docker from starting at all.

| unit | what it does |
|---|---|
| `saipan-memguard.service` | oneshot; applies the caps before `docker.service` (needed on v1, harmless on v2) |
| `saipan-memguard-watch.service` | the long-running part: keeps the caps applied and keeps `oom_score_adj` at a killable value |

## The bug that mattered more than the cap

The cap is the easy half. This is the half that panicked the phone.

`/sys/fs/pstore/dmesg-ramoops-0` ends with:

```
Kernel panic - not syncing: Out of memory and no killable processes...
 (7)[10025:unattended-upgr]
```

`unattended-upgrades` — `apt`'s automatic updater, in the container — grew until the kernel
could not find a victim. `mm/oom_kill.c` panics unconditionally in that situation:

```c
if (!oc->chosen) {
        dump_header(oc, NULL);
        pr_warn("Out of memory and no killable processes...\n");
        if (!is_sysrq_oom(oc) && !is_memcg_oom(oc))
                panic("Out of memory and no killable processes...\n");
}
```

`panic_on_oom` is **0** on this device, so this was not a tunable being ignored. And the reason
there was no victim is visible in the same dump: **every task in it has `oom_score_adj = -1000`**.
That is `OOM_SCORE_ADJ_MIN` — not a candidate at all.

It is there on purpose. Droidspaces, `src/utils.c`:

```c
/* Set oom_score_adj to -1000 (unkillable).  Best-effort, no error return. */
void ds_oom_protect(void) { ... fprintf(f, "-1000\n"); }
```

and everything in the container inherits it. The instinct — don't let Android reap my
container — has a fatal interaction with a kernel OOM. **A cap over unkillable tasks does not
fail safe:** measured, the workload stayed alive 30 s with usage pinned at exactly the limit and
zero kills, i.e. the cap wedged it and the panic still came later.

So the guard resets `oom_score_adj` to 0 and lets the cgroup cap be the protection instead.

### Measured, identical 64 MB cgroup, identical workload, one variable

| `oom_score_adj` | result |
|---|---|
| `0` | killed after **5 s**; `oom_kill 1`; `Memory cgroup out of memory: Kill process 19180 (hog3) score 1003` |
| `-1000` | **alive after 30 s**; usage pinned at `67108864` (= the limit exactly); zero kills; no dmesg line |

This is also why an earlier version of [`../../docs/CGROUP-V2.md`](../../docs/CGROUP-V2.md)
wrongly concluded that cgroup v2 "caps but does not kill": every test ran under `adb shell`,
which is itself at `-1000`.

## What it does now

| | |
|---|---|
| cgroup | v2 — the container is one isolated subtree, `/sys/fs/cgroup/droidspaces/bagda` |
| memory cap | 90% of RAM — **3457220608** bytes |
| swap cap | 90% of swap — **2592911360** bytes |
| covers | **every** process in the container, not just Docker's |
| `oom_score_adj` | forced to 0 on every container process (except the two `[ds-monitor]` helpers, which are outside the container's PID namespace and tiny) |
| log | `/var/log/saipan-memguard.log` |

On cgroup v2 nothing has to be *moved*: the container already lives in one subtree, so the cap
is inherited by construction. The v1 path is still in the script (`memory.use_hierarchy` plus a
sweep that drags systemd's slices back in) because the handset ran v1 until recently, but v1 is
no longer what this device uses.

**Sizing: 90% of RAM for memory, 90% of swap for swap.** On v1 the equivalent single knob was
memory+swap at 90% of RAM+swap; splitting it the same way keeps the combined ceiling identical.
The swap half is not optional — a memory-only cap is satisfied by swapping, measured: a 256 MB
memory cap held at 255 MB while a 1024 MB allocation carried on, because zram absorbed it.

## Verified end to end

With the container capped at 256 MB and `memory.swap.max` at 0, a hog inside the container
reached 128 MB and was killed by the kernel:

```
oom_kill: 7 -> 8
Memory cgroup out of memory: Kill process 16592 (python3) score 613 or sacrifice child
Killed process 16592 (python3) total-vm:177852kB, anon-rss:163212kB
```

The container stayed `running` and `portainer` was untouched.

**And the same test with the hog left at `-1000` is the cautionary one:** `oom_kill` went 0 → 6
in six seconds and the victims were `portainer` and `containerd`, not the hog. An unkillable
workload does not just survive a cap — it gets its neighbours killed.

## Caveats

* **`oom_score_adj` is reset, not configured.** Anything that specifically wants to be
  unkillable (a supervisor holding a lock, say) will have that undone within one interval.
* The two `[ds-monitor]` processes keep `-1000`. They are outside the container's PID
  namespace so the guard cannot see them, and they are far too small to be OOM candidates —
  but if the cgroup ever OOMed with the monitor pair as the *only* members, the memcg OOM
  killer would find nothing to kill. It would then not panic (`is_memcg_oom()`), it would just
  spin, which is the failure mode described above.
* `MEMGUARD_PCT`, `MEMGUARD_INTERVAL`, `MEMGUARD_CGROUP` and `MEMGUARD_LOG` override the
  defaults.
