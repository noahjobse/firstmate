# 2026-07-12 - torn watcher lock: the turn-end guard manufactured the outage it reported

Date: 2026-07-12.
Version: `ad9f3a7` (fix: harden away-mode daemon lifecycle (#490)).
Home: primary firstmate home `/home/noah/projects/firstmate`, tmux backend, claude harness.

## Symptom

Two failure modes, reported as if they were separate bugs.

1. False positive.
   `bin/fm-turnend-guard.sh` fired its Stop-hook banner at the end of nearly every turn of a healthy session, and a plain `bin/fm-watch-arm.sh` reported `watcher: FAILED - no live watcher with a fresh beacon`, while a watcher was alive, held the lock, and had beaten seconds earlier.
   The banner contradicted itself: it claimed no live watcher held the lock while reporting a beacon from 6 seconds ago.

2. True outage.
   Repeatedly, no `fm-watch.sh` process was alive at all, `state/.watch.lock/pid` was unreadable although the lock dir existed, and the beacon was 30-50s stale.
   Nothing recovered supervision on its own.

## Root cause

One cause, both modes: **the watcher lock's identity metadata was published non-atomically, and was written through the lock path after the claim.**

`bin/fm-watch.sh` claimed the singleton lock with `fm_lock_try_acquire` (which publishes `pid` inside the owner dir the lock symlink names) and only afterwards wrote `fm-home`, `watcher-path`, and `pid-identity` through `$WATCH_LOCK/...`:

```sh
# bin/fm-watch.sh, before the fix
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
```

That produces two bad lock states, and every consumer of `fm_watcher_lock_matches_pid` (the turn-end guard, `fm-guard.sh`, `fm-watch-arm.sh`) reads both of them as "no live watcher holds this home's lock":

- **Incomplete lock.** Between the claim and those writes, the lock is visible with a live `pid` but no `pid-identity`. `fm_watcher_lock_matches_pid` requires a non-empty recorded identity, so a live, lock-holding, beating watcher reads as absent.
- **Torn lock.** The writes go through the lock symlink, not into the writer's own owner dir. If the symlink is re-pointed at another owner dir in that window, the late writes land in a *different* holder's owner dir, leaving a lock whose `pid` names one process and whose `pid-identity` fingerprints another. A torn lock never heals: the mismatch is permanent for the life of that lock.

The escalation from mode 1 to mode 2 ran through the repair path itself.
`bin/fm-watch-arm.sh --restart` treated an identity mismatch on a live lock pid as "a reused pid, not our watcher" and took the clear-the-lock branch (`clear_stale_recorded_watcher_lock` -> `fm_lock_remove_path`).
Against a torn lock that pid *is* our watcher, so restart yanked the lock out from under a live watcher **without stopping it**.
The orphaned watcher kept running while a fresh child claimed the freed lock; the orphan self-evicted or died, the two raced over lock creation and teardown, and the result was the observed empty/dangling lock dir, duplicate watchers, and windows with no watcher at all.

The guard's banner then pushed the operator to restart again, which is what churned supervision.
The guard was not merely crying wolf: **the restart it demanded was the thing taking supervision down.**

## Evidence

`ps -o lstart=` was first suspected of drifting. It does not; it is stable for a fixed pid:

```
$ P=$(cat /home/noah/projects/firstmate/state/.watch.lock/pid); bash lstart-drift.sh "$P"
lock pid=252311
pid=252311
btime (kernel boot epoch, from /proc/stat): 1783890250
starttime ticks (/proc/252311/stat field 22): 929381

 1  now=17:40:55  ps_lstart=[Sun Jul 12 17:39:03 2026]  btime=1783890250
 2  now=17:40:57  ps_lstart=[Sun Jul 12 17:39:03 2026]  btime=1783890250
...
12  now=17:41:18  ps_lstart=[Sun Jul 12 17:39:03 2026]  btime=1783890250
```

A read-only probe registered as an extra Stop hook, evaluating the primary's live lock at the instant a turn ended, caught the torn lock directly.
The recorded identity and the live `ps` identity for the *same* lock pid disagree by 11 seconds, so they are two different processes:

```
===== 17:38:09 STOP HOOK =====
--- primary lock state:
    pid=[241566]
    fm-home=[/home/noah/projects/firstmate]
    watcher-path=[/home/noah/projects/firstmate/bin/fm-watch.sh]
    pid-identity=[Sun Jul 12 17:35:56 2026 bash /home/noah/projects/firstmate/bin/fm-watch.sh]
    ps identity=[Sun Jul 12 17:36:07 2026 bash /home/noah/projects/firstmate/bin/fm-watch.sh]
    beat_age=16s
    watcher procs: 241566
--- predicate:
    fm_watcher_healthy: NO
```

The mechanism reproduces end to end in an isolated sandbox home.
Step 1 shows the incomplete lock (live `pid`, empty `pid-identity`); step 3 shows the tear:

```
== step 1: process A claims the lock (as fm_lock_try_acquire does) ==
   lock -> .watch.lock.owner.kXyGOG  pid=269194
   lock as seen by a consumer right now:
     pid=[269194] pid-identity=[]

== step 2: a 'repair' yanks the lock and B claims it ==
   lock -> .watch.lock.owner.SzVwf0  pid=269229  (B's subshell)

== step 3: A, still alive, now runs its post-claim metadata writes ==

== result: the lock is TORN ==
   pid          = 269229
   pid-identity = Sun Jul 12 17:43:44 2026 bash .../tear.sh
   ps for pid   = Sun Jul 12 17:43:44 2026 sleep 30
   lock pid is ALIVE: yes
   fm_watcher_lock_matches_pid: NO   <-- live holder misreported as absent
   fm_watcher_healthy: NO   <-- guard fires / arm reports FAILED
```

## Fix

- `bin/fm-wake-lib.sh`: `fm_lock_try_create`/`fm_lock_try_acquire` take an optional stage function (`fm_lock_stage_owner_meta`) that writes a holder's identity into the owner dir **before** the symlink publishes the lock. A lock is therefore never observable half-written, and a holder never writes lock metadata through the lock path, so a late write can no longer land in a stranger's owner dir. A staging failure is reported as its own outcome (return `2`, `FM_LOCK_STAGE_FAILED`), never as contention: nobody holds the lock, so a caller must fail loudly instead of standing down. `fm_lock_claim` no longer rewrites a pid its own owner dir already carries, so no reader can catch a published lock inside a truncate window. Adds `fm_pid_runs_command`, `fm_pid_env_value`, `fm_pid_home_readable`, and `fm_pid_home_matches`.
- `bin/fm-watch.sh`: stages `fm-home`, `watcher-path`, and `pid-identity` at claim time; the post-claim writes through `$WATCH_LOCK` are gone. A staging failure exits non-zero with `watcher: FAILED - could not stage the watcher lock identity`, never `watcher: already running`.
- `bin/fm-supervise-daemon.sh`: the daemon's singleton lock had the same post-claim write and now stages its identity the same way, and reports a staging failure as its own error rather than as another daemon already running.
- `bin/fm-watch-arm.sh`: `--restart` stops a live holder that is demonstrably running this watcher script (`fm_pid_runs_command`) **and** is positively attributed to this home (`fm_pid_home_matches`, read from the target's own environment), even when the lock's identity does not vouch for it. The attribution is not optional: `bin/fm-watch.sh` is the same script in every home, secondmates included, so a stale pid this home recorded and the OS since recycled onto a sibling home's watcher would match on command path alone and restart would kill that home's supervision - the hazard `AGENTS.md` names as `pkill -f bin/fm-watch.sh`. A live watcher whose home cannot be read (no `/proc`) is neither signalled nor has its lock cleared; it is surfaced through the honest `FAILED` report. Clearing the lock is reserved for a holder that really is not our watcher (a genuinely reused pid, or a watcher belonging to another home). This also self-heals a torn lock written by a pre-fix firstmate.

The predicate is not weakened. A killed watcher still reads unhealthy and still raises the banner.

## Regression coverage

`tests/fm-watcher-lock.test.sh`:

- `test_lock_metadata_is_staged_before_the_lock_is_published` - the stage hook observes the lock path as still absent when it runs, and the published lock carries the staged identity. Fails on the pre-fix code.
- `test_restart_stops_a_live_watcher_behind_a_torn_lock` - the outage. Fails on the pre-fix code with `not ok - restart left the live watcher running behind a torn lock (orphaned watcher = the real outage)`.
- `test_watch_lock_names_its_own_watcher_from_a_clean_environment` - both directions of the predicate with `FM_HOME` unset and the environment cleared (`env -i`), which is how the harness Stop hook invokes the guard. This one passes on the pre-fix code too: it guards the environment-dependent path, but it is not what caught this bug.
- `test_restart_never_kills_a_sibling_homes_watcher` - a real watcher living in another home, its pid recorded (recycled) in this home's lock behind a mismatched identity. Restart must repair this home without signalling it. Fails with `not ok - restart killed a SIBLING home's watcher off a recycled pid (cross-home kill)` against a `--restart` that trusts the command-path match alone.
- `test_watch_fails_loudly_when_lock_staging_fails` - with staging forced to fail, the watcher must exit non-zero and say so. Fails with `not ok - watcher exited zero when it could not stage its lock identity: watcher: already running` against a `--restart`-era watcher that read its own staging failure as contention and stood down with supervision unarmed.
