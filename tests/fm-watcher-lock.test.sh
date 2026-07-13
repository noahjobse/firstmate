#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

# Restart can only signal a holder it can positively attribute to this home, and
# that reads the target's own environment through /proc. Where /proc is absent
# (macOS) the arm deliberately refuses to kill, so the restart-behavior tests
# below have nothing to assert and skip instead of failing.
home_attribution_available() {
  [ -r "/proc/$$/environ" ]
}


test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is re-arm-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'resume supervision' "$err" >/dev/null || fail "guard banner missing the harness-aware fix command"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, resume supervision' "$err" >/dev/null || fail "guard did not order supervision repair after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) fresh watcher, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  [ ! -s "$err" ] || fail "guard warned with a fresh watcher and no queued wakes: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (re-arm-after-drain) and stays silent when fresh"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Stay alive so the held lock names a live pid for the whole window;
        # otherwise a late contender could legitimately reclaim a dead-pid lock.
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
  ' _ "$LIB" "$lockdir")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i lock_pid
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  # The honest arm forks the fresh watcher as a tracked child and waits on it, so
  # the lock now names that child, not the arm invocation. The property is the
  # same: the stale reused-pid lock is replaced by a genuinely live watcher, which
  # the arm confirms before reporting it. Wait for that confirmation, not just for
  # the lock pid to appear (identity and beacon land a beat later).
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$live" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not replace stale reused-pid lock with a live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$out" >/dev/null || fail "restart did not report the fresh watcher it confirmed"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$pid" "$lock_pid" "$live" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart refuses to signal a reused pid"
}

test_watch_restart_reports_healthy_peer_without_attaching() {
  local dir state fakebin out peer identity armpid status
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  node -e 'process.on("SIGTERM", () => {}); setTimeout(() => {}, 300000)' &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  # The peer ignores TERM on purpose, so restart always burns its full bounded
  # stop-wait (50 x 0.1s) before it forks and confirms the stand-down child.
  # The budget must clear that floor with room to spare or a loaded machine times
  # the arm out before it can report healthy.
  wait_for_exit "$armpid" 200
  status=$?
  [ "$status" -eq 0 ] || fail "restart did not exit zero after reporting healthy peer (status $status): $(cat "$out")"
  grep -qF "watcher: healthy pid=$peer" "$out" || fail "restart did not report the healthy peer: $(cat "$out")"
  ! grep -qF 'watcher: attached' "$out" || fail "restart attached to a peer watcher instead of preserving restart ownership contract"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  pass "watch restart reports a healthy peer without attaching to it"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 50 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not record its own pid in the lock"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies, the attached arm must exit 0 (cycle ended).
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after seed died (status $status)"
  pass "arm attaches to a live fresh watcher and exits only when that cycle ends"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1; i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    [ -z "$dead_pid" ] || [ "$lock_pid" != "$dead_pid" ] || fail "arm ($row) did not replace the dead-pid lock with a live watcher"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts+confirms a fresh watcher on a clean lock and self-heals a dead-pid lock (never healthy off a dead pid)"
}

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$lock_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  pass "arm cleans child watcher and temp output on HUP"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod +x "$check_file"
  rc=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate arm wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer beater identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  (
    sleep 1
    touch "$state/.last-watcher-beat"
  ) &
  beater=$!
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=4 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$beater" 2>/dev/null || true
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies, the attached arm must exit 0 (same as pre-fork attach).
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 0 ] || fail "attached arm did not exit zero after peer died (status $status): $(cat "$armout")"
  pass "arm attaches to a peer watcher after child stands down and exits when peer dies"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED - no live watcher with a fresh beacon' "$armout" >/dev/null || fail "arm did not print the FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_pid_identity_is_locale_invariant() {
  # The watcher records its process identity under one locale; arm/guard/turn-end
  # re-read it under the machine's ambient locale. ps's lstart date format follows
  # LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR) would differ only
  # in the date portion and reject a genuinely live watcher. The fix pins LC_ALL=C
  # inside fm_pid_identity, so its output must be byte-identical regardless of the
  # caller's exported LC_ALL/LC_TIME. That invariant holds on any host because the
  # pin is internal, so this stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live baseline via_lc_all via_lc_time
  sleep 300 &
  live=$!
  baseline=$(LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

test_pid_identity_is_stable_across_reads() {
  # The identity is a fingerprint of ONE live process instance, so the same live pid
  # must fingerprint byte-identically every time or the lock's own holder eventually
  # reads as a reused pid and supervision reports itself down while a watcher is
  # running. ps's lstart is recomputed from a boot-time estimate on every invocation
  # and drifts by a second on a clock-adjusting host (WSL2), so the identity must not
  # be derived from it where the kernel's own start ticks are readable.
  local live baseline current i
  sleep 300 &
  live=$!
  baseline=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  [ -n "$baseline" ] || fail "fm_pid_identity produced no identity for a live pid"
  i=0
  while [ "$i" -lt 20 ]; do
    current=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
    [ "$current" = "$baseline" ] \
      || fail "fm_pid_identity is not stable across reads of one live pid (got '$current', want '$baseline')"
    sleep 0.1
    i=$((i + 1))
  done
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "fm_pid_identity is byte-stable across repeated reads of one live pid"
}

test_lock_metadata_is_staged_before_the_lock_is_published() {
  # The lock must never be observable in a half-written state. A holder stages its
  # identity into the OWNER DIR, and only then does the symlink publish it, so no
  # reader can see a lock that names a live pid but carries no identity (which
  # every consumer reads as "no watcher"), and no late write can land in another
  # holder's owner dir and tear the lock apart. Proven by having the stage hook
  # look for the lock path at the moment it runs: it must still be ABSENT.
  local dir state lockdir obs out
  dir=$(make_case lock-stage-atomic)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  obs="$dir/lock-visible-when-staged"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    LIB=$1; LOCK=$2; OBS=$3
    . "$LIB"
    stage_meta() {
      local ownerdir=$1
      if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
        printf "visible\n" > "$OBS"
      else
        printf "absent\n" > "$OBS"
      fi
      printf "staged-fingerprint\n" > "$ownerdir/pid-identity"
    }
    fm_lock_try_acquire "$LOCK" stage_meta || exit 7
    printf "staged_at=%s identity=%s\n" "$(cat "$OBS")" "$(cat "$LOCK/pid-identity" 2>/dev/null)"
  ' _ "$LIB" "$lockdir" "$obs") || fail "staged acquire failed: $out"
  case "$out" in
    *"staged_at=absent"*) ;;
    *) fail "lock was already published when its metadata was staged: $out" ;;
  esac
  case "$out" in
    *"identity=staged-fingerprint"*) ;;
    *) fail "published lock does not carry the staged identity: $out" ;;
  esac
  pass "lock metadata is staged into the owner dir before the lock is published"
}

test_watch_lock_names_its_own_watcher_from_a_clean_environment() {
  # The turn-end guard runs from a harness Stop hook, not the operator's shell, so
  # the predicate must hold with FM_HOME unset and the environment stripped. A live
  # watcher must read healthy; a killed one must not. Both directions, one test.
  local dir state fakebin out pid i probe
  dir=$(make_case lock-clean-env)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the probe shell's own positional args
  probe='. "$1"; if fm_watcher_healthy "$2/state" "$3" 300 "$2"; then echo healthy; else echo unhealthy; fi'
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "watcher did not take the lock"
  # env -i: no FM_HOME, no FM_STATE_OVERRIDE, nothing inherited from this shell.
  [ "$(env -i PATH="$PATH" bash -c "$probe" _ "$LIB" "$dir" "$WATCH")" = healthy ] \
    || fail "live watcher read as absent from a cleared environment (the Stop-hook case)"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(env -i PATH="$PATH" bash -c "$probe" _ "$LIB" "$dir" "$WATCH")" = unhealthy ] \
    || fail "killed watcher still read as healthy - the guard would go silent with supervision off"
  pass "watcher lock reads healthy for a live watcher and unhealthy for a killed one with FM_HOME unset"
}

test_restart_stops_a_live_watcher_behind_a_torn_lock() {
  # The outage regression. A TORN lock - pid naming a live watcher, pid-identity
  # fingerprinting some other process - makes fm_watcher_lock_matches_pid fail.
  # Restart must still recognise the live holder as this home's watcher and STOP
  # it. It must never take the clear-the-lock branch, which would yank the lock
  # from a watcher that keeps running: that leaves an orphaned watcher racing a
  # fresh one over a lock neither owns, which is how a false alarm became a real
  # supervision outage.
  local dir state fakebin out armout pid armpid i lock_pid stranger
  home_attribution_available || {
    echo "skip: restart's home attribution needs /proc (Linux); on macOS restart neither stops nor clears a live holder behind a legacy torn lock"
    return 0
  }
  dir=$(make_case restart-torn-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A long poll keeps the seed watcher alive well past the restart, so "it exited"
  # can only mean restart stopped it, never that it self-evicted on its own.
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=30 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "seed watcher did not take the lock"
  # Tear the lock exactly as an interleaved late write did: keep the live pid, but
  # replace the identity with a stranger's.
  sleep 300 &
  stranger=$!
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$stranger" > "$state/.watch.lock/pid-identity"
  kill "$stranger" 2>/dev/null || true
  wait "$stranger" 2>/dev/null || true
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -qE 'watcher: (started|healthy) pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$pid" \
    || fail "restart left the live watcher running behind a torn lock (orphaned watcher = the real outage)"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$pid" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not leave a live watcher holding the lock (got '$lock_pid')"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_lock_matches_pid "$2/state" "$3" "$4" "$2"' \
    _ "$LIB" "$dir" "$WATCH" "$lock_pid" \
    || fail "lock rebuilt by restart is still not self-consistent (pid does not match its own identity)"
  kill "$armpid" "$lock_pid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "restart stops a live watcher behind a torn lock instead of orphaning it"
}

test_restart_never_kills_a_sibling_homes_watcher() {
  # The cross-home hazard. bin/fm-watch.sh is the SAME script in every firstmate
  # home, so a stale pid THIS home recorded, recycled by the OS onto a SIBLING
  # home's live watcher, matches on command path alone. Restart must positively
  # attribute the pid to this home before signalling it: the sibling's supervision
  # must survive, and this home must still repair itself.
  local dir sibling state fakebin armout sibling_pid armpid i lock_pid
  home_attribution_available || {
    echo "skip: restart's home attribution needs /proc (Linux); on macOS an unattributable holder is never signalled at all"
    return 0
  }
  dir=$(make_case restart-sibling-home)
  sibling=$(make_case restart-sibling-home-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # A real watcher, living in ANOTHER home, holding that home's own lock.
  PATH="$fakebin:$PATH" FM_HOME="$sibling" FM_POLL=30 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$sibling/watch.out" &
  sibling_pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$sibling/state/.watch.lock/pid" 2>/dev/null || true)" = "$sibling_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$sibling/state/.watch.lock/pid" 2>/dev/null || true)" = "$sibling_pid" ] \
    || fail "sibling home's watcher did not take its own lock"
  # THIS home's lock records that pid (recycled), with an identity that no longer
  # matches it - the exact shape that makes the command-path match the only arm left.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$sibling_pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$sibling_pid" \
    || fail "restart killed a SIBLING home's watcher off a recycled pid (cross-home kill)"
  [ "$(cat "$sibling/state/.watch.lock/pid" 2>/dev/null || true)" = "$sibling_pid" ] \
    || fail "restart disturbed the sibling home's own lock"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  { [ -n "$lock_pid" ] && [ "$lock_pid" != "$sibling_pid" ] && kill -0 "$lock_pid" 2>/dev/null; } \
    || fail "restart did not repair this home's supervision with its own live watcher (got '$lock_pid')"
  grep -F "watcher: started pid=$lock_pid" "$armout" >/dev/null \
    || fail "restart did not report the fresh watcher it confirmed"
  kill "$armpid" "$lock_pid" "$sibling_pid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true
  wait "$sibling_pid" 2>/dev/null || true
  pass "restart repairs this home without killing a sibling home's watcher"
}

test_watch_fails_loudly_when_lock_staging_fails() {
  # A staging failure is OUR failure, not contention: no lock exists and no watcher
  # is running. The watcher must never report it as "already running" and exit 0,
  # which would leave supervision unarmed while the caller believed it was live.
  local dir state fakebin out status
  dir=$(make_case watch-stage-fail)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # ps missing makes fm_pid_identity - and so the watcher's stage hook - fail.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "watcher exited zero when it could not stage its lock identity: $(cat "$out")"
  ! grep -qF 'watcher: already running' "$out" \
    || fail "staging failure was reported as another watcher already running: $(cat "$out")"
  grep -qF 'watcher: FAILED' "$out" || fail "staging failure was not reported loudly: $(cat "$out")"
  [ ! -e "$state/.watch.lock" ] || fail "failed staging left a lock behind"
  pass "watcher fails loudly when it cannot stage its lock identity"
}

test_lock_acquire_fails_closed_on_an_unwritable_state_dir() {
  # An unwritable (or full) state dir fails before any staging: mktemp cannot make
  # the owner dir. That must be the SAME own-failure outcome as a stage failure
  # (rc 2, no holder pid), never "someone else holds the lock" - and it must never
  # descend into the steal path, whose lock lives in the same unwritable dir and
  # would recurse (lock.steal -> lock.steal.steal -> ...) without bound.
  local dir state out rc
  [ "$(id -u)" -ne 0 ] || { echo "skip: running as root, an unwritable dir is still writable"; return 0; }
  dir=$(make_case lock-unwritable-state)
  state="$dir/state"
  chmod 500 "$state"
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the probe shell's own positional args
  out=$(timeout 20 env FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2/.contend.lock"
    printf "rc=%s held=[%s] staged_failed=[%s]\n" "$?" "${FM_LOCK_HELD_PID:-}" "${FM_LOCK_STAGE_FAILED:-}"
  ' _ "$LIB" "$state" 2>&1)
  rc=$?
  chmod 700 "$state"
  [ "$rc" -eq 0 ] || fail "acquire on an unwritable state dir did not terminate cleanly (rc=$rc): $out"
  case "$out" in
    *"rc=2 held=[] staged_failed=[1]"*) ;;
    *) fail "unwritable state dir was not reported as an own failure: $out" ;;
  esac
  case "$out" in
    *"recursion"*|*"FUNCNEST"*) fail "acquire recursed on an unwritable state dir: $out" ;;
  esac
  pass "lock acquire fails closed (rc 2, no holder) on an unwritable state dir instead of recursing"
}

test_unwritable_state_dir_with_a_live_holder_is_contention() {
  # The other half of the own-failure contract, and the one that can kill a
  # watcher. An unwritable (or full) state dir fails OUR writes while an existing
  # holder's lock sits right there, so a live healthy watcher plus a full disk must
  # read as contention (rc 1, that holder's pid), NEVER as "we could not build a
  # lock and nothing is running". Reporting that as an own failure is what makes
  # the watcher print "supervision is NOT armed", the arm report FAILED, and the
  # repair path (--restart) stop a perfectly healthy watcher because the disk
  # filled up.
  local dir state fakebin out out2 pid i status
  [ "$(id -u)" -ne 0 ] || { echo "skip: running as root, an unwritable dir is still writable"; return 0; }
  dir=$(make_case unwritable-state-live-holder)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  out2="$dir/watch2.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=30 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] || fail "seed watcher did not take the lock"
  chmod 500 "$state"
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the probe shell's own positional args
  out=$(timeout 20 env FM_HOME="$dir" bash -c '
    . "$1"
    fm_lock_try_acquire "$2/state/.watch.lock"
    printf "rc=%s held=[%s] staged_failed=[%s]\n" "$?" "${FM_LOCK_HELD_PID:-}" "${FM_LOCK_STAGE_FAILED:-}"
    fm_watcher_healthy "$2/state" "$3" 300 "$2" && printf "healthy\n"
  ' _ "$LIB" "$dir" "$WATCH" 2>&1)
  case "$out" in
    *"rc=1 held=[$pid] staged_failed=[]"*) ;;
    *) fail "a live holder on an unwritable state dir was not reported as contention: $out" ;;
  esac
  case "$out" in
    *healthy*) ;;
    *) fail "a live watcher on an unwritable state dir stopped reading healthy (the repair path would stop it): $out" ;;
  esac
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 timeout 20 "$WATCH" > "$out2" 2>&1
  status=$?
  chmod 700 "$state"
  [ "$status" -eq 0 ] || fail "watcher did not stand down for the live holder on an unwritable state dir (status=$status): $(cat "$out2")"
  grep -qF "watcher: already running pid $pid" "$out2" \
    || fail "watcher did not report the live holder it lost to: $(cat "$out2")"
  ! grep -qF 'watcher: FAILED' "$out2" \
    || fail "a live healthy watcher plus an unwritable state dir was reported as a failure to arm: $(cat "$out2")"
  is_live_non_zombie "$pid" || fail "the healthy holder did not survive the failed acquire"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "an unwritable state dir with a live holder reports contention, not 'nothing armed'"
}

test_contention_after_a_failed_steal_mutex_reports_no_own_failure() {
  # The steal mutex is acquired through fm_lock_try_acquire itself, so an
  # unwritable state dir sets FM_LOCK_STAGE_FAILED inside that recursion. If a live
  # holder then claims the primary lock, the outer call returns contention - and
  # must NOT hand the caller an own-failure flag as well: rc 1 always means someone
  # else holds it, and only rc 2 means we could not build a lock. The probe forces
  # the race deterministically by making the primary pid read dead once (so we
  # descend into the steal path) and live afterwards (so a fresh holder appears).
  local dir state out
  [ "$(id -u)" -ne 0 ] || { echo "skip: running as root, an unwritable dir is still writable"; return 0; }
  dir=$(make_case contention-after-failed-steal)
  state="$dir/state"
  mkdir -p "$state/.race.lock"
  printf '4242\n' > "$state/.race.lock/pid"
  touch -d '-30 seconds' "$state/.race.lock" 2>/dev/null || touch -t 200001010000 "$state/.race.lock"
  chmod 500 "$state"
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the probe shell's own positional args
  out=$(timeout 20 env FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    alive_calls=0
    fm_pid_alive() {
      alive_calls=$((alive_calls + 1))
      [ "$alive_calls" -gt 1 ]
    }
    fm_lock_try_acquire "$2/.race.lock"
    printf "rc=%s held=[%s] staged_failed=[%s]\n" "$?" "${FM_LOCK_HELD_PID:-}" "${FM_LOCK_STAGE_FAILED:-}"
  ' _ "$LIB" "$state" 2>&1)
  chmod 700 "$state"
  case "$out" in
    *"rc=1 held=[4242] staged_failed=[]"*) ;;
    *) fail "contention after a failed steal mutex did not report a clean contention outcome: $out" ;;
  esac
  pass "contention never returns with an own-failure flag left over from the steal mutex"
}

test_owner_dir_leaves_nothing_behind_when_a_stage_hook_writes_extra_files() {
  # A stage hook may stage any filename into its owner dir. If discard only cleared
  # a fixed name list, an extra file would defeat the rmdir and strand a
  # <lock>.owner.XXXXXX dir in the state dir on every acquire - and a state dir that
  # slowly fills is exactly how the contention case above (a full disk with a live
  # watcher) comes about in the first place.
  local dir state out strays
  dir=$(make_case owner-dir-stage-extra)
  state="$dir/state"
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the probe shell's own positional args
  out=$(timeout 20 env FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    stage_extra() { printf "x\n" > "$1/unknown-metadata"; }
    stage_fail() { printf "x\n" > "$1/unknown-metadata"; return 1; }
    fm_lock_try_acquire "$2/.extra.lock" stage_extra || { echo "acquire-failed"; exit 1; }
    fm_lock_release "$2/.extra.lock"
    fm_lock_try_acquire "$2/.extra.lock" stage_fail && { echo "staging-failure-not-reported"; exit 1; }
    echo ok
  ' _ "$LIB" "$state" 2>&1)
  [ "$out" = ok ] || fail "stage-hook probe did not behave as expected: $out"
  [ ! -e "$state/.extra.lock" ] || fail "a released lock (and a failed staging) left a lock behind"
  strays=$(find "$state" -maxdepth 1 -name '*.owner.*' | wc -l)
  [ "$strays" -eq 0 ] || fail "$strays owner dir(s) leaked into the state dir after a stage hook wrote an unknown filename"
  pass "owner dirs are cleared generically, so a stage hook's own filenames leak nothing"
}

test_watch_fails_loudly_when_the_state_dir_is_unwritable() {
  # Same cause, seen from the watcher: no lock exists and nothing was armed, so it
  # must exit non-zero and say so, never "already running".
  local dir state fakebin out status
  [ "$(id -u)" -ne 0 ] || { echo "skip: running as root, an unwritable dir is still writable"; return 0; }
  dir=$(make_case watch-unwritable-state)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  chmod 500 "$state"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 timeout 20 "$WATCH" > "$out" 2>&1
  status=$?
  chmod 700 "$state"
  [ "$status" -ne 124 ] || fail "watcher hung (unbounded recursion?) on an unwritable state dir: $(cat "$out")"
  [ "$status" -ne 0 ] || fail "watcher exited zero when it could not create its lock: $(cat "$out")"
  ! grep -qF 'watcher: already running' "$out" \
    || fail "an unwritable state dir was reported as another watcher already running: $(cat "$out")"
  grep -qF 'watcher: FAILED' "$out" || fail "unwritable state dir was not reported loudly: $(cat "$out")"
  [ ! -e "$state/.watch.lock" ] || fail "failed acquire left a lock behind"
  pass "watcher fails loudly when an unwritable state dir prevents it from creating its lock"
}

test_pid_runs_command_matches_only_the_program_being_run() {
  # The restart arm signals what this vouches for, so it must mean "this pid is
  # EXECUTING that script", not "that path appears somewhere in its arguments" - a
  # tail or editor on bin/fm-watch.sh must never be mistaken for the watcher.
  local dir tail_pid sleeper_pid probe
  dir=$(make_case pid-runs-command)
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the probe shell's own positional args
  probe='. "$1"; if fm_pid_runs_command "$2" "$3"; then echo match; else echo nomatch; fi'
  tail -f "$WATCH" > /dev/null 2>&1 &
  tail_pid=$!
  sleep 0.2
  [ "$(FM_STATE_OVERRIDE="$dir/state" bash -c "$probe" _ "$LIB" "$tail_pid" "$WATCH")" = nomatch ] \
    || fail "a process merely reading $WATCH matched as running it (it would be SIGTERMed off a recycled pid)"
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_POLL=30 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" 2>&1 &
  sleeper_pid=$!
  sleep 0.5
  [ "$(FM_STATE_OVERRIDE="$dir/state" bash -c "$probe" _ "$LIB" "$sleeper_pid" "$WATCH")" = match ] \
    || fail "the real watcher process did not match its own script path"
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  pass "fm_pid_runs_command matches the program being run, not a path in the arguments"
}

test_pid_runs_command_matches_a_program_path_containing_spaces() {
  # A home whose path contains a space still runs the same watcher. Word-splitting
  # the command line truncates such a path, so the arm would read a LIVE watcher as
  # not running its script, fall through to clearing the lock, and yank it out from
  # under that watcher - the outage in docs/incidents/2026-07-12-torn-watcher-lock.md.
  local dir spaced watcher live_pid probe
  dir=$(make_case pid-runs-command-spaces)
  spaced="$dir/a home with spaces"
  watcher="$spaced/fm-watch.sh"
  mkdir -p "$spaced"
  cat > "$watcher" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$watcher"
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the probe shell's own positional args
  probe='. "$1"; if fm_pid_runs_command "$2" "$3"; then echo match; else echo nomatch; fi'
  "$watcher" &
  live_pid=$!
  sleep 0.3
  [ "$(FM_STATE_OVERRIDE="$dir/state" bash -c "$probe" _ "$LIB" "$live_pid" "$watcher")" = match ] \
    || fail "a live watcher whose path contains a space did not match its own script path"
  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  tail -f "$watcher" > /dev/null 2>&1 &
  live_pid=$!
  sleep 0.2
  [ "$(FM_STATE_OVERRIDE="$dir/state" bash -c "$probe" _ "$LIB" "$live_pid" "$watcher")" = nomatch ] \
    || fail "a process merely reading the spaced watcher path matched as running it"
  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  pass "fm_pid_runs_command matches a program path containing spaces, still not one named in arguments"
}

test_wake_append_fails_fast_when_the_state_dir_is_unwritable() {
  # The queue lock cannot be created at all on an unwritable (or full) state dir.
  # That is permanent, not contention, so waiting on it would block forever and no
  # wake would ever be queued or surfaced - a silent total supervision failure. It
  # must fail promptly and loudly instead.
  local dir state out rc
  [ "$(id -u)" -ne 0 ] || { echo "skip: running as root, an unwritable dir is still writable"; return 0; }
  dir=$(make_case wake-append-unwritable-state)
  state="$dir/state"
  chmod 500 "$state"
  # shellcheck disable=SC2016  # single quotes are deliberate: $1 is the probe shell's own positional arg
  out=$(timeout 15 env FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_append signal fm-x "signal: fm-x"
    printf "rc=%s\n" "$?"
  ' _ "$LIB" 2>&1)
  rc=$?
  chmod 700 "$state"
  [ "$rc" -ne 124 ] || fail "fm_wake_append hung on an unwritable state dir instead of failing: $out"
  [ "$rc" -eq 0 ] || fail "the wake-append probe did not terminate cleanly (rc=$rc): $out"
  case "$out" in
    *"rc=0"*) fail "fm_wake_append reported success though no wake could be queued: $out" ;;
  esac
  case "$out" in
    *"NOT queued"*) ;;
    *) fail "fm_wake_append did not report the failure loudly: $out" ;;
  esac
  pass "fm_wake_append fails loudly and promptly when the state dir is unwritable"
}

test_wake_drain_fails_loudly_when_the_state_dir_is_unwritable() {
  # Same cause, seen from the drain: it must not block forever at the top of a
  # wake-handling turn.
  local dir state out status
  [ "$(id -u)" -ne 0 ] || { echo "skip: running as root, an unwritable dir is still writable"; return 0; }
  dir=$(make_case wake-drain-unwritable-state)
  state="$dir/state"
  chmod 500 "$state"
  out=$(FM_STATE_OVERRIDE="$state" timeout 15 "$DRAIN" 2>&1)
  status=$?
  chmod 700 "$state"
  [ "$status" -ne 124 ] || fail "fm-wake-drain hung on an unwritable state dir: $out"
  [ "$status" -ne 0 ] || fail "fm-wake-drain exited zero though it could not lock the queue: $out"
  case "$out" in
    *FAILED*) ;;
    *) fail "fm-wake-drain did not report the failure loudly: $out" ;;
  esac
  pass "fm-wake-drain fails loudly when an unwritable state dir prevents locking the queue"
}

test_pid_home_matches_separates_state_override_domains() {
  # Two domains can share a home root and differ only by FM_STATE_OVERRIDE, each
  # with its own .watch.lock. They are different supervision domains and must not
  # be able to signal each other.
  local dir peer_pid probe
  dir=$(make_case home-state-override)
  mkdir -p "$dir/state-a" "$dir/state-b"
  # shellcheck disable=SC2016  # single quotes are deliberate: $1/$2 are the probe shell's own positional args
  probe='. "$1"; if fm_pid_home_matches "$2" "$3" "$4"; then echo match; else echo nomatch; fi'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state-a" sleep 30 &
  peer_pid=$!
  sleep 0.2
  if [ -r "/proc/$peer_pid/environ" ]; then
    [ "$(bash -c "$probe" _ "$LIB" "$peer_pid" "$dir" "$dir/state-a")" = match ] \
      || fail "a process in the same home and state dir was not attributed to it"
    [ "$(bash -c "$probe" _ "$LIB" "$peer_pid" "$dir" "$dir/state-b")" = nomatch ] \
      || fail "a process in a DIFFERENT state-override domain was attributed to this one (cross-domain kill)"
  else
    echo "skip: home attribution needs /proc (Linux)"
  fi
  kill "$peer_pid" 2>/dev/null || true
  wait "$peer_pid" 2>/dev/null || true
  pass "fm_pid_home_matches treats a different FM_STATE_OVERRIDE as a different home"
}

test_singleton_start
test_pid_identity_is_locale_invariant
test_pid_identity_is_stable_across_reads
test_lock_acquire_fails_closed_on_an_unwritable_state_dir
test_unwritable_state_dir_with_a_live_holder_is_contention
test_contention_after_a_failed_steal_mutex_reports_no_own_failure
test_owner_dir_leaves_nothing_behind_when_a_stage_hook_writes_extra_files
test_watch_fails_loudly_when_the_state_dir_is_unwritable
test_pid_runs_command_matches_only_the_program_being_run
test_pid_runs_command_matches_a_program_path_containing_spaces
test_wake_append_fails_fast_when_the_state_dir_is_unwritable
test_wake_drain_fails_loudly_when_the_state_dir_is_unwritable
test_pid_home_matches_separates_state_override_domains
test_lock_metadata_is_staged_before_the_lock_is_published
test_restart_never_kills_a_sibling_homes_watcher
test_watch_fails_loudly_when_lock_staging_fails
test_watch_lock_names_its_own_watcher_from_a_clean_environment
test_restart_stops_a_live_watcher_behind_a_torn_lock
test_stale_watch_lock_reclaimed
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_reports_healthy_peer_without_attaching
test_watcher_self_evicts_on_lock_takeover
test_arm_attaches_and_waits_for_live_fresh_watcher
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
