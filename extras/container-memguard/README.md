# Container memory guard

A memory ceiling for the Docker containers on this handset, sized so containers keep **90% of
the phone's RAM** while a runaway is still stopped short of starving Android.

```sh
sh install.sh      # inside the container, as root; restarts Docker once
```

It installs `/usr/local/sbin/saipan-memguard.sh` and a `saipan-memguard.service` ordered
`Before=docker.service`, then adds `"cgroup-parent": "/saipan-guard"` to
`/etc/docker/daemon.json` (backing it up to `daemon.json.bak-memguard`).

## Why it is not a one-liner

Writing a limit onto `/docker` looks like it should work and does nothing at all. Four things
had to be measured before the cap actually bound:

**`memory.use_hierarchy` defaults to 0.** With it off, cgroup v1 limits apply only to a
cgroup's *own* charges, not its descendants. A child reached **1008 MB under a 256 MB parent
cap with `failcnt` 0** - the parent's limit was never consulted. Containers live in
`/docker/<id>` *beneath* `/docker`, so a cap there constrains nothing.

**It can only be set on a childless cgroup**, per `mm/memcontrol.c`:

```c
if ((!parent_memcg || !parent_memcg->use_hierarchy) && (val == 1 || val == 0)) {
        if (!memcg_has_children(memcg))
                memcg->use_hierarchy = val;
        else
                retval = -EBUSY;
}
```

`/docker` has children the moment a container runs, and stopping Docker and removing them
still left the write refused. So the guard uses its own cgroup, created before dockerd starts,
and Docker is pointed at it with `cgroup-parent`.

**A memory cap alone is not a ceiling, because of zram.** A memory-only cap is satisfied by
swapping, so the process carries on: a **256 MB memory cap held at 255 MB while a 1024 MB
allocation continued happily**. `memory.memsw.limit_in_bytes` is the one that bites, and swap
accounting is enabled on this kernel.

**Write order matters.** `memory.limit <= memory.memsw.limit` must hold at every moment, so
lowering means writing memory first and raising means writing memsw first. A fixed order
silently fails one of the two directions.

## What it does

| | |
|---|---|
| guard cgroup | `/sys/fs/cgroup/memory/saipan-guard`, `use_hierarchy=1` |
| memory cap | 90% of RAM - **3297 MB** on this handset |
| memory+swap cap | 90% of RAM+swap - **5769 MB** |
| covers | every container, via Docker `cgroup-parent` |
| log | `/var/log/saipan-memguard.log` |

## Verified

With the guard temporarily dropped to 192 MB, a container trying to write 900 MB was stopped
at **233 MB** (`memory.failcnt` 8082) and the kernel logged

```
Memory cgroup out of memory: Kill process 26782 (portainer) score 282 or sacrifice child
```

That is a **memory cgroup OOM kill**: the kernel took a container process rather than taking
the phone down. Nothing rebooted, and the framework was never involved.

For contrast, an *unguarded* ramp allocated **3840 MB - more than the handset's 3663 MB of
physical RAM** - with `MemAvailable` at 32 MB, and the kernel's OOM killer never fired once.
Android's own ActivityManager did the work by killing and restarting GMS, the launcher, the
IME and SmsForwarder. Linux plus zram **thrashes rather than failing fast**, which is the whole
argument for imposing a ceiling here.

## Caveats

* **Docker restarts once during install**, so running containers are recreated. Their data
  lives in volumes and is unaffected.
* The cap covers **Docker workloads**. Other processes in the container (a service, or `apt`)
  are not under it, because they live in `system.slice` - a sibling of the guard cgroup, and
  `system.slice` is itself already non-hierarchical. Capping *those* means per-service leaf
  caps, which is a separate piece of work. The runaway that originally panicked this phone was
  `unattended-upgrades` running `apt` in the container, and that trigger is disabled; the
  Docker cap covers the workloads that are actually run here.
* `MEMGUARD_PCT` and `MEMGUARD_CGROUP` override the sizing and location if needed.
* This is cgroup **v1**. Moving to v2 would let Droidspaces' own `memory_limit=` do the job,
  and needs the device-cgroup BPF backport described in
  [`../../docs/SERVER-SETUP.md`](../../docs/SERVER-SETUP.md) §2.2.
