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

Two causes, and the first one alone is sufficient for both modes.

**Primary: the pid fingerprint drifted against its own process.**
`fm_pid_identity` fingerprinted a pid with `ps -o lstart=`, which is not a stable value.
`lstart` is DERIVED: the kernel's `btime` (boot epoch, from `/proc/stat`) plus the process's own `starttime` ticks.
`starttime` never moves, but `btime` is recomputed and jitters by about a second on this WSL2 host, roughly every 30 seconds.
Every jump shifts the derived `lstart` of every live process at once.
So a stored `lstart` fingerprint goes stale against the very process it fingerprints, with no second writer and no lock race at all: within about 30 seconds a live watcher's own lock reads as a reused pid.
That alone produces mode 1 (the false-positive banner and `watcher: FAILED`) and then mode 2, because `--restart` reads the mismatch as a recycled pid and yanks the lock out from under a live watcher.
This was suspected first, tested over too short a window, wrongly recorded here as refuted, and re-measured and CONFIRMED on 2026-07-13 (see Evidence).

**Co-cause: the lock's identity metadata was published non-atomically, and was written through the lock path after the claim.**
This is the genuine two-writer tear, and it is real and separately reproducible; it is not what the drifting fingerprint explains.

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

### `lstart` drift: suspected, under-tested, then confirmed

`ps -o lstart=` was suspected of drifting on 2026-07-12 and recorded here as refuted, on 12 samples over about 24 seconds in which `btime` never moved:

```
 1  now=17:40:55  ps_lstart=[Sun Jul 12 17:39:03 2026]  btime=1783890250
...
12  now=17:41:18  ps_lstart=[Sun Jul 12 17:39:03 2026]  btime=1783890250
```

That was an underpowered test, not a refutation.
`btime` jumps roughly every 30 seconds on this host, so a 24-second window can easily contain zero jumps.

Re-measured on 2026-07-13 against one fixed, never-restarting pid, 90 reads over 90 seconds, `btime` moved three times and `ps lstart` moved in lockstep with it:

```
btime  1783964089 -> 1783964090 -> 1783964091 -> 1783964092
ps lstart  13:08:05 -> 13:08:06 -> 13:08:07 -> 13:08:08
```

The discriminator, across a single `btime` jump (`1783964093 -> 1783964094`) on that same never-restarting pid: `ps lstart` MOVED while the shipped `/proc` start-ticks fingerprint was UNCHANGED.

```
ps lstart        13:10:10  ->  13:10:11        (moved)
fm_pid_identity  571766 sleep 200  ->  571766 sleep 200   (unchanged)
```

`starttime` (`/proc/<pid>/stat` field 22) is boot-relative, so no `btime` recomputation can perturb it.
An `lstart` fingerprint invalidates itself; a start-ticks fingerprint does not.

### The two-writer tear

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

- `bin/fm-wake-lib.sh`, **the primary fix**: the pid fingerprint's start half changes from `ps -o lstart=` to the kernel's boot-relative start ticks (`/proc/<pid>/stat` field 22). This is what stops a live watcher's own lock from reading as a reused pid, so it is the cure for both failure modes, not an optimisation and not defense in depth. Do not remove it, and do not "simplify" the fingerprint back to `lstart`. Where `/proc` does not exist, `lstart` remains as the fallback, and it remains an ACTIVELY DRIFTING primitive there, not an equivalent one: on a host with no `/proc` and a jittering `btime`, this class of false alarm is NOT fixed. Accepted transition: because the format changes, every lock written by a pre-update firstmate is unreadable to the new code, so a still-running pre-update watcher reads as unidentifiable until one `bin/fm-watch-arm.sh --restart` cycle replaces it. On Linux that self-heals through the attributed restart below; the captain has accepted this one-time bark.
- `bin/fm-wake-lib.sh`, **the co-fix** for the genuine two-writer tear: `fm_lock_try_create`/`fm_lock_try_acquire` take an optional stage function (`fm_lock_stage_owner_meta`) that writes a holder's identity into the owner dir **before** the symlink publishes the lock. A lock is therefore never observable half-written, and a holder never writes lock metadata through the lock path, so a late write can no longer land in a stranger's owner dir. Any failure to build a lock of our own - a failed stage hook, but equally an unwritable or full state dir that defeats `mktemp` in `fm_lock_owner_dir` or the pid write in `fm_lock_prepare_owner` - is reported as its own outcome (return `2`, `FM_LOCK_STAGE_FAILED`), never as contention: nobody holds the lock, so a caller must fail loudly instead of standing down. Returning that outcome before the steal path also bounds the recursion: `fm_lock_try_acquire` used to fall through to stealing on a state dir it could not write, and the steal mutex lives in that same dir, so it recursed into itself without bound. `fm_lock_claim` no longer rewrites a pid its own owner dir already carries, so no reader can catch a published lock inside a truncate window. Adds `fm_pid_runs_command` (anchored to the program being run, so a process that merely names the watcher path in its arguments is never mistaken for it), `fm_pid_env_value`, `fm_pid_home_readable`, and `fm_pid_home_matches` (which compares the target's resolved `STATE` as well as its home, so two domains separated only by `FM_STATE_OVERRIDE` cannot signal each other).
- `bin/fm-watch.sh`: stages `fm-home`, `watcher-path`, and `pid-identity` at claim time; the post-claim writes through `$WATCH_LOCK` are gone. Failing to create the lock exits non-zero with `watcher: FAILED`, for every cause, and `watcher: already running` is printed only when a lock actually exists.
- `bin/fm-supervise-daemon.sh`: the daemon's singleton lock had the same post-claim write and now stages its identity the same way, and reports its own failure to create the lock as an error rather than as another daemon already running.
- `bin/fm-watch-arm.sh`: `--restart` stops a live holder that is demonstrably running this watcher script (`fm_pid_runs_command`) **and** is positively attributed to this home (`fm_pid_home_matches`, read from the target's own environment), even when the lock's identity does not vouch for it. The attribution is not optional: `bin/fm-watch.sh` is the same script in every home, secondmates included, so a stale pid this home recorded and the OS since recycled onto a sibling home's watcher would match on command path alone and restart would kill that home's supervision - the hazard `AGENTS.md` names as `pkill -f bin/fm-watch.sh`. A live watcher whose home cannot be read (no `/proc`) is neither signalled nor has its lock cleared; it is surfaced through the honest `FAILED` report. Clearing the lock is reserved for a holder that really is not our watcher (a genuinely reused pid, or a watcher belonging to another home). This also self-heals a torn lock written by a pre-fix firstmate.

- `bin/fm-wake-lib.sh`, `bin/fm-afk-start.sh`, `bin/fm-afk-launch.sh`: every consumer of that fingerprint now fails closed on ambiguity through `fm_pid_matches_identity`, which separates "this pid is provably NOT the holder" (return `1`, reclaimable) from "this holder cannot be identified at all" (return `2`: a live pid whose recorded identity is in the format the previous version wrote, or a `ps` that cannot fingerprint it). Treating an ambiguous identity as a dead holder is exactly the assumption that evicted a live watcher here, so a caller that would EVICT a lock or start a second supervisor treats `2` as still held, and a caller that would SIGNAL the pid treats `2` as not ours unless it can attribute the process independently. Without that split, the away-mode daemon's singleton lock inherits the accepted watcher bark as something far worse: a daemon started before an in-place update would read as dead, `bin/fm-afk-start.sh` would remove its lock, and the following `exec` would run a SECOND daemon beside the live one, injecting every escalation twice.
- `bin/fm-afk-launch.sh`: the launcher reads all three states too, on both the daemon lock and its own launcher lock. Routing a three-state result through a boolean made `2` falsy, so the two halves of `/afk` disagreed about the same lock: `start` closed the recorded terminal and spawned a new daemon that immediately stood down, then waited for it forever, and `stop` left a live holder unsignalled so its cleanup trap never flushed buffered escalations while `state/.afk` was still present. `stop` now signals an unidentifiable holder when, and only when, that pid is independently attributed to this home (it is executing this home's daemon script and its own environment resolves to this home and state dir), which is the same bar `bin/fm-watch-arm.sh` requires before it signals a watcher.
- **Fail-closed must not mean fail-silent** (now a standing rule in `AGENTS.md` section 8). Refusing to act on an ambiguous lock is correct, but a silent refusal turns a recycled pid behind a stale lock into an away mode that can never start again, with nothing told to anyone: an unrecoverable silent failure is strictly worse than the bug it replaced. So every refusal here exits non-zero and names the exact lock path to remove.
- `bin/fm-wake-lib.sh`: `fm_pid_home_matches` canonicalises both sides of the home and state comparison (`fm_path_canonical`). `FM_HOME` arrives spelled however the environment spells it - a trailing slash, a path through a symlink - while the no-override fallback returns the physically resolved root, so a raw string compare failed a home against its own watcher and sent `--restart` down the clear-the-lock branch. Canonicalising can only make attribution more accurate: an unresolvable path falls back to its literal form, so nothing new becomes signal-able.

The predicate is not weakened. A killed watcher still reads unhealthy and still raises the banner.

## Known limitation (macOS)

Attributing a pid to a home reads that process's own environment through `/proc`, so it works on Linux only.
On macOS a live holder behind a **legacy** torn lock (one written by a pre-fix firstmate) cannot be attributed, so `--restart` neither stops it nor clears its lock: the home reports `FAILED` until that watcher is stopped by hand once.
Refusing to signal an unattributable process is deliberate - the alternative is killing a sibling home's supervision.
Torn locks can no longer form now that identity publishes atomically, so this affects only a lock already on disk from an older version.

## Regression coverage

`tests/fm-watcher-lock.test.sh`:

- `test_lock_metadata_is_staged_before_the_lock_is_published` - the stage hook observes the lock path as still absent when it runs, and the published lock carries the staged identity. Fails on the pre-fix code.
- `test_restart_stops_a_live_watcher_behind_a_torn_lock` - the outage. Fails on the pre-fix code with `not ok - restart left the live watcher running behind a torn lock (orphaned watcher = the real outage)`.
- `test_watch_lock_names_its_own_watcher_from_a_clean_environment` - both directions of the predicate with `FM_HOME` unset and the environment cleared (`env -i`), which is how the harness Stop hook invokes the guard. This one passes on the pre-fix code too: it guards the environment-dependent path, but it is not what caught this bug.
- `test_restart_never_kills_a_sibling_homes_watcher` - a real watcher living in another home, its pid recorded (recycled) in this home's lock behind a mismatched identity. Restart must repair this home without signalling it. Fails with `not ok - restart killed a SIBLING home's watcher off a recycled pid (cross-home kill)` against a `--restart` that trusts the command-path match alone.
- `test_watch_fails_loudly_when_lock_staging_fails` - with staging forced to fail, the watcher must exit non-zero and say so. Fails with `not ok - watcher exited zero when it could not stage its lock identity: watcher: already running` against a `--restart`-era watcher that read its own staging failure as contention and stood down with supervision unarmed.
- `test_lock_acquire_fails_closed_on_an_unwritable_state_dir` and `test_watch_fails_loudly_when_the_state_dir_is_unwritable` - the other half of the same fail-closed contract, which the stage-hook signal alone did not cover: an unwritable state dir must return the own-failure outcome and exit loudly, without recursing through the steal path.
- `test_pid_runs_command_matches_only_the_program_being_run` - a `tail -f` on `bin/fm-watch.sh` must not match as running it, or a recycled lock pid landing on such a process would be signalled by `--restart`.
- `test_pid_home_matches_separates_state_override_domains` - two domains sharing a home root but separated by `FM_STATE_OVERRIDE` are different homes and cannot cross-signal.
- `test_pid_identity_is_stable_across_reads` - one live pid must fingerprint byte-identically on every read, which is what the start-ticks fingerprint guarantees regardless of any boot-time recomputation.
- `test_pid_identity_is_derived_from_start_ticks_not_lstart` - the discriminator itself, pinned so a refactor cannot quietly regress the cure: the fingerprint's start half IS `/proc/<pid>/stat` field 22 and is not `lstart`, and an `lstart`-derived fingerprint moves across a `btime` shift while this one does not. Skips where `/proc` is absent.
- `test_watch_restart_clears_a_stale_lock_for_a_differently_spelled_home` - a home whose `FM_HOME` carries a trailing slash must still recognise and clear its OWN stale lock, or it can never re-arm behind one.
- `test_unwritable_state_dir_with_a_live_holder_is_contention` - a full or read-only state dir under a LIVE holder must report contention, never "nothing is armed", or the repair path would terminate a healthy watcher because the disk is full.
- `test_contention_after_a_failed_steal_mutex_reports_no_own_failure` - a contention return never carries `FM_LOCK_STAGE_FAILED` left over from the steal mutex's own failure; rc 1 and the own-failure flag are mutually exclusive.
- `test_try_create_clears_stale_lock_signals_on_entry` - the same contract for direct callers of the `fm_lock_try_create` primitive, which clears the three lock signals on entry rather than relying on `fm_lock_try_acquire` to have done it.
- `test_owner_dir_leaves_nothing_behind_when_a_stage_hook_writes_extra_files` - owner dirs are cleared generically on discard, so a stage hook writing any filename cannot strand `<lock>.owner.XXXXXX` dirs in the state dir - a slow path to the very full-state-dir condition above.

The two restart-behavior tests skip on a platform without `/proc`, where the arm deliberately refuses to signal an unattributable holder and so has nothing to assert.

`tests/fm-afk-launch.test.sh` and `tests/fm-daemon.test.sh` cover the same contract on the away-mode side, all skipping without `/proc`:

- `test_afk_start_treats_an_unreadable_daemon_identity_as_held` - a live holder with a legacy fingerprint keeps its lock, no second daemon is exec'd, and the stand-down is non-zero and names the lock.
- `unit_launch_lock_holds_on_unreadable_identity` - the launcher lock is never evicted from a live holder it cannot read, fails fast rather than waiting out a holder that may never let go, and still reclaims a dead one.
- `unit_legacy_daemon_lock_fails_loudly` - `start` and `stop` both refuse non-zero and name the lock; an unattributable live holder is never signalled, and a refused `stop` leaves `state/.afk` in place.
- `unit_legacy_daemon_lock_stops_an_attributed_daemon` - the other direction: a live holder attributed to this home IS stopped behind a legacy fingerprint, SIGTERMed while `state/.afk` is still present so its flush is not a no-op.

## Follow-on, 2026-07-13 - the `pgrep -f` miscount that reverted this fix

The day after this fix landed, supervision was reported as degraded on the primary: three watchers alive at once, an absent lock, and a silent turn-end guard, read together as a dangerous false negative.
The fix was merged and then reverted on that evidence.
Every part of the reading was an instrumentation artifact, and the fix was not at fault.

A watcher was counted with a command-line match:

```
$ pgrep -af 'bin/fm-watch.sh'
26311 claude --dangerously-skip-permissions You are a crewmate: ... `pgrep -af 'bin/fm-watch.sh'` ...
64500 bash /home/noah/projects/firstmate/bin/fm-watch.sh
```

A crewmate's command line contains its entire brief, and this crewmate's brief was about the watcher, so it quoted `bin/fm-watch.sh` and matched itself.
The trap is self-referential: any brief describing the watcher makes the agent reading it look like one.
Reading `comm` instead of the full command line separates them, and only one watcher was ever running:

```
$ ps -o comm= -p 26311
claude
$ ps -o comm= -p 64500
bash
```

The guard's silence was a second artifact, of probing it by hand.
`bin/fm-turnend-guard.sh` reads the Stop-hook JSON payload from stdin and exits 0 when it is empty, before it evaluates supervision at all, so running it from a terminal reports nothing regardless of state.
Against one identical state - one task in flight, no lock, no watcher, so supervision genuinely dead - the two invocations disagree:

```
$ bin/fm-turnend-guard.sh </dev/null ; echo "exit=$?"
exit=0
$ printf '{"stop_hook_active":false}' | bin/fm-turnend-guard.sh ; echo "exit=$?"
●  TURN WOULD END BLIND - SUPERVISION IS OFF
●  1 task(s) in flight, but no live watcher holds this home lock (last beat: 0s ago).
exit=2
```

Running the guard by hand is not a health probe, and its silence is never evidence that supervision is live.
`fm_watcher_healthy` is fail-closed on an absent lock by construction: it reads `state/.watch.lock/pid`, and an empty pid cannot be alive, so it returns unhealthy.
Both directions were verified against the deployed tree and this branch - a healthy watcher stays silent, and an absent lock, a lock with no pid file, a dead pid, and a stale beacon each fire the banner.

The lasting lesson is about the instrument, not the lock.
`AGENTS.md` section 8 already forbade `pkill -f bin/fm-watch.sh` because that pattern is unsafe for *killing* across homes; it now also forbids `pgrep -f` for *counting*, because the same pattern is unsafe for identification, and names the lock-plus-`comm` check that replaces it.
