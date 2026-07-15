#!/usr/bin/env bash
# fm-afk-launch.sh - the single owner of the away-mode daemon TERMINAL lifecycle:
# launch it in a NON-VISIBLE tracked terminal per backend, record its exact id,
# tear it down by that exact id, and reconcile a leaked one after a crash.
#
# Why this exists (docs/herdr-backend.md "Away-mode daemon terminal launch"):
# bin/fm-afk-start.sh execs the supervise daemon in the FOREGROUND of whatever
# terminal it is already in. Harnesses with a native in-pane tracked-background
# tool (claude, grok) run it there directly and it is fine. A harness with NO
# native background mechanism (pi) has to manufacture a terminal, and doing that
# by SPLITTING the captain's active pane visibly shrinks it - the regression this
# script fixes. Instead this creates a non-visible tracked terminal (a herdr tab/
# workspace with --no-focus, or a detached tmux session) that never touches the
# captain's active tab, and NEVER uses shell `&` (which herdr/codex can reap).
#
# Correct supervisor targeting: the daemon finds the captain pane to inject into
# from its OWN inherited env (discover_supervisor_target). Running it in a
# separate terminal would make it discover its OWN pane, so this captures the
# captain pane FIRST (from the pane this script runs in) and passes it in as
# FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND explicitly.
#
# Usage:
#   fm-afk-launch.sh start     Capture the captain pane, then (unless the daemon
#                              is already running) launch the daemon in a fresh
#                              non-visible terminal for the detected backend and
#                              record it. Idempotent: an already-running daemon
#                              just refreshes state/.afk; a recorded-but-dead
#                              terminal is reconciled (closed by id) first.
#   fm-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#   fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
#                              cleanup flushes WHILE state/.afk is still present,
#                              wait for it, close the recorded terminal by exact
#                              id, then clear state/.afk last.
#   fm-afk-launch.sh reconcile Close a recorded-but-dead daemon terminal by exact
#                              id and drop the record (recovery after a crash).
#
# Supported backends: herdr, tmux. Others (zellij, orca, cmux) have no verified
# non-visible-launch primitive here yet and refuse loudly.
#
# Every subcommand reads the daemon lock through the THREE-state
# daemon_lock_state_resolved, never a boolean: a live holder that is positively
# attributed to this home (it runs this home's daemon script and its own
# environment resolves to this home and state dir) is the running daemon even when
# its recorded identity predates the identity-format change, while a live holder
# that can be neither identified nor attributed is never evicted, never signalled,
# and never started beside. That refusal exits NON-ZERO and names the lock and the
# remedy - fail closed must not mean fail silent (AGENTS.md section 8;
# docs/incidents/2026-07-12-torn-watcher-lock.md). A refused `stop` therefore
# leaves state/.afk in place, because away mode was not exited.
#
# Test seam: FM_AFK_LAUNCH_ENTRY overrides the command run in the created
# terminal (default bin/fm-afk-start.sh), so a topology test can run a harmless
# placeholder instead of a real daemon. FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND
# override the captured captain pane/backend (an isolated lab pane in tests).
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_LAUNCH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_LAUNCH_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LAUNCH_RECORD="$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal"
FM_AFK_LAUNCH_LOCK="$FM_AFK_LAUNCH_STATE/.afk-launch.lock"
FM_AFK_LAUNCH_WS_LABEL="firstmate-afk-daemon"

# shellcheck source=bin/fm-backend.sh
. "$FM_AFK_LAUNCH_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-supervisor-target-lib.sh"
# fm-afk-start.sh provides the daemon-lock liveness helpers and
# fm_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-start.sh"
set +e

fm_afk_launch_log() { printf 'fm-afk-launch: %s\n' "$*" >&2; }

# Every read of the daemon lock here goes through daemon_lock_state_resolved's THREE
# states, never a boolean and never the unresolved daemon_lock_state. A boolean
# collapses 2 (a LIVE holder this version cannot identify) into "no daemon running",
# which is how the launcher came to close a live daemon's terminal, spawn a second one
# beside it, and then wait for a daemon that never arrives - and how stop came to skip
# the SIGTERM that flushes buffered escalations while state/.afk is still present.
# Reading the UNRESOLVED state is the mirror-image bug: a live daemon whose legacy
# fingerprint predates the identity-format change is trivially attributable, so
# refusing it would hard-fail every /afk refresh and away-mode recovery behind advice
# to remove a lock its own live daemon holds. Refusing an unattributable holder is
# right; refusing SILENTLY is not, so every refusal names the lock and the remedy.
fm_afk_launch_refuse_ambiguous_lock() {  # <refused-action>
  fm_afk_launch_log "$(fm_afk_ambiguous_lock_message "$1")"
}

# The launcher lock's three states, mirroring daemon_lock_state: 0 held by a live
# launcher we positively identify, 1 no live holder (reclaimable), 2 a LIVE holder
# whose recorded identity is in a format this version cannot read (it started
# before an in-place update, or ps cannot fingerprint it). The acquire loop REMOVES
# a lock it reads as unowned, so ambiguity must never read as unowned: evicting a
# live launcher's lock runs two launchers at once. It must not read as ordinary
# contention either - waiting for a holder that may never let go is the silent wedge
# fm_afk_launch_lock_acquire refuses to enter.
fm_afk_launch_lock_state() {
  local pid expected rc=0
  [ -d "$FM_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  [ -n "$pid" ] || return 1
  fm_pid_alive "$pid" || return 1
  expected=$(cat "$FM_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null || true)
  # A LIVE holder with no readable identity is ambiguous, never reclaimable. Today's
  # launcher stages its fingerprint before the lock publishes, so it cannot produce
  # this lock; a lock left by an older launcher can, and reading it as unowned would
  # evict a live launcher and run two at once.
  [ -n "$expected" ] || return 2
  fm_pid_matches_identity "$pid" "$expected" || rc=$?
  return "$rc"
}

# Stage hook for the launcher lock: fm_lock_try_create calls this with the owner
# dir BEFORE the lock symlink publishes it, so the lock a contender reads always
# carries both a pid and its identity. Publishing the lock first and writing the
# identity through it afterwards is the torn-lock shape of
# docs/incidents/2026-07-12-torn-watcher-lock.md: a contender that lands in that
# window reads an identity-less lock and, once its patience for an incomplete lock
# runs out, evicts a live launcher.
fm_afk_launch_stage_lock_meta() {
  local ownerdir=$1
  fm_pid_identity "${BASHPID:-$$}" > "$ownerdir/pid-identity" 2>/dev/null || return 1
  [ -s "$ownerdir/pid-identity" ]
}

fm_afk_launch_remove_reclaimable_lock() {
  fm_lock_exists "$FM_AFK_LAUNCH_LOCK" || return 0
  if fm_lock_remove_path "$FM_AFK_LAUNCH_LOCK" 2>/dev/null; then
    return 0
  fi
  fm_lock_exists "$FM_AFK_LAUNCH_LOCK" || return 0
  fm_afk_launch_log "launcher lock $FM_AFK_LAUNCH_LOCK is reclaimable but could not be removed; remove $FM_AFK_LAUNCH_LOCK and retry."
  return 1
}

fm_afk_launch_lock_acquire() {
  local i incomplete=0 pid lock_state create_rc
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  for i in $(seq 1 200); do
    create_rc=0
    fm_lock_try_create "$FM_AFK_LAUNCH_LOCK" '' fm_afk_launch_stage_lock_meta || create_rc=$?
    if [ "$create_rc" -eq 0 ]; then
      return 0
    fi
    if [ "$create_rc" -eq 2 ]; then
      fm_afk_launch_log "cannot create the launcher lock $FM_AFK_LAUNCH_LOCK (state dir unwritable or full, or ps unavailable)"
      return 1
    fi
    # Only a lock published by an older launcher can be observed half-written; wait
    # it out rather than judging it, and never let that patience expire into an
    # eviction - an incomplete lock with a live holder reads as ambiguous below.
    if [ ! -s "$FM_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$FM_AFK_LAUNCH_LOCK/pid-identity" ]; then
      incomplete=$((incomplete + 1))
      if [ "$incomplete" -lt 20 ]; then
        sleep 0.05
        continue
      fi
    else
      incomplete=0
    fi
    lock_state=0
    fm_afk_launch_lock_state || lock_state=$?
    if [ "$lock_state" -eq 2 ]; then
      pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
      fm_afk_launch_log "launcher lock $FM_AFK_LAUNCH_LOCK is held by live pid=${pid:-unknown} whose identity this version cannot read; refusing to evict it. If pid ${pid:-unknown} is not an away-mode launcher, remove $FM_AFK_LAUNCH_LOCK and retry."
      return 1
    fi
    if [ "$lock_state" -ne 0 ]; then
      fm_afk_launch_remove_reclaimable_lock || return 1
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  fm_afk_launch_log "timed out waiting for launcher lock $FM_AFK_LAUNCH_LOCK"
  return 1
}

fm_afk_launch_lock_release() {
  local pid
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "${BASHPID:-$$}" ] || return 0
  fm_lock_remove_path "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || true
}

fm_afk_launch_usage() {
  sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${FM_AFK_LAUNCH_ENTRY:-$FM_ROOT/bin/fm-afk-start.sh}"
}

fm_afk_launch_record_write() {  # <backend> <target> <extra>
  local pending
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_flag_write() {
  local pending="$FM_AFK_LAUNCH_STATE/.afk.pending.$$"
  date '+%s' > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_AFK_LAUNCH_STATE/.afk" || { rm -f "$pending"; return 1; }
}

# Read the recorded terminal into FM_AFK_REC_BACKEND/FM_AFK_REC_TARGET. The third
# field (a herdr workspace id, kept for the record's own documentation) is not
# needed to close by id, so it is discarded. Returns 1 when no record exists.
fm_afk_launch_record_read() {
  local extra record
  FM_AFK_REC_BACKEND=""; FM_AFK_REC_TARGET=""; extra=""
  [ -f "$FM_AFK_LAUNCH_RECORD" ] || return 1
  record=$(cat "$FM_AFK_LAUNCH_RECORD" 2>/dev/null) || record=""
  IFS=$'\t' read -r FM_AFK_REC_BACKEND FM_AFK_REC_TARGET extra \
    < "$FM_AFK_LAUNCH_RECORD" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$FM_AFK_REC_BACKEND" ] || [ -z "$FM_AFK_REC_TARGET" ]; then
    fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_AFK_REC_BACKEND" in
    herdr) [ -n "$extra" ] ;;
    tmux) : ;;
    none) [ "$FM_AFK_REC_TARGET" = - ] && [ "$extra" = native ] ;;
    *) return 2 ;;
  esac || { fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

fm_afk_launch_record_validate_if_present() {
  local result
  fm_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

# Close a recorded terminal by EXACT id (never a broad sweep). The
# recorded workspace id (herdr) needs no separate close: closing the pane takes
# its single-tab dedicated workspace with it.
fm_afk_launch_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2
  case "$backend" in
    herdr)
      fm_backend_source herdr || return 1
      local session=${target%%:*} pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    tmux)
      # target is the dedicated daemon session name - kill exactly it.
      tmux kill-session -t "$target" 2>/dev/null
      ;;
    none)
      return 0
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_afk_launch_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 session pane out result code
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>&1)
      result=$?
      [ "$result" -ne 0 ] || return 1
      code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null) || return 1
      [ "$code" = pane_not_found ]
      ;;
    tmux)
      out=$(tmux has-session -t "$target" 2>&1)
      result=$?
      [ "$result" -eq 1 ] || return 1
      printf '%s' "$out" | grep -Eq "can't find session"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_close_recorded() {
  local close_result=0
  fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" || close_result=$?
  if fm_afk_launch_terminal_absent "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET"; then
    rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

fm_afk_launch_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    herdr)
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane get "$pane" >/dev/null 2>&1
      ;;
    tmux)
      tmux has-session -t "$target" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 i lock_state
  if [ -n "${FM_AFK_LAUNCH_ENTRY:-}" ]; then
    fm_afk_launch_terminal_alive "$backend" "$target"
    return
  fi
  for i in $(seq 1 100); do
    lock_state=0
    daemon_lock_state_resolved || lock_state=$?
    [ "$lock_state" -eq 0 ] && return 0
    if [ "$lock_state" -eq 2 ]; then
      # The daemon we just launched stands down on this lock rather than doubling
      # up, so waiting out the loop would only wait for the terminal to die.
      fm_afk_launch_refuse_ambiguous_lock 'wait for a daemon to come up behind it'
      return 1
    fi
    fm_afk_launch_terminal_alive "$backend" "$target" || return 1
    sleep 0.05
  done
  return 1
}

fm_afk_launch_commit_terminal() {  # <backend> <target> <extra> [already-recorded]
  local backend=$1 target=$2 extra=$3 already_recorded=${4:-0}
  if [ "$already_recorded" -ne 1 ] && ! fm_afk_launch_record_write "$backend" "$target" "$extra"; then
    fm_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    fm_afk_launch_close_terminal "$backend" "$target"
    return 1
  fi
  if ! fm_afk_launch_wait_ready "$backend" "$target"; then
    fm_afk_launch_log "daemon did not become ready; closing $backend:$target"
    FM_AFK_REC_BACKEND=$backend
    FM_AFK_REC_TARGET=$target
    fm_afk_launch_close_recorded
    return 1
  fi
}

fm_afk_launch_herdr_recover_created() {  # <session> <label>
  local session=$1 label=$2 workspaces ws_count wsid panes pane_count pane i
  for i in $(seq 1 20); do
    workspaces=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || { sleep 0.05; continue; }
    ws_count=$(printf '%s' "$workspaces" | jq --arg want "$label" \
      '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$ws_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$ws_count" = 1 ] || return 1
    wsid=$(printf '%s' "$workspaces" | jq -r --arg want "$label" \
      '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
    [ -n "$wsid" ] || return 1
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || { sleep 0.05; continue; }
    pane_count=$(printf '%s' "$panes" | jq '[.result.panes[]?] | length' 2>/dev/null) || { sleep 0.05; continue; }
    if [ "$pane_count" = 0 ]; then
      sleep 0.05
      continue
    fi
    [ "$pane_count" = 1 ] || return 1
    pane=$(printf '%s' "$panes" | jq -r '.result.panes[0].pane_id // empty' 2>/dev/null) || return 1
    [ -n "$pane" ] || return 1
    printf '%s\t%s' "$wsid" "$pane"
    return 0
  done
  return 1
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {
  local read_result lock_state=0
  daemon_lock_state_resolved || lock_state=$?
  if [ "$lock_state" -eq 0 ]; then
    return 0
  fi
  if [ "$lock_state" -eq 2 ]; then
    # The recorded terminal may be the live holder's own; closing it would tear
    # down a running daemon we cannot even name.
    fm_afk_launch_refuse_ambiguous_lock 'reconcile the recorded daemon terminal'
    return 1
  fi
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_log "reconciling leaked daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET}"
    fm_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

fm_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$FM_AFK_LAUNCH_STATE/.afk" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-inject-wedged" || result=1
  if [ "$had_afk" -eq 1 ]; then
    cp "$backup/.afk" "$FM_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$backup/$artifact" ]; then
      cp -p "$backup/$artifact" "$FM_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    fm_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Launch the daemon in a non-visible herdr terminal in the CAPTAIN's session
# (so the daemon can inject into the captain pane, which lives there). A
# dedicated background workspace (--no-focus) holds exactly one tab/pane; it
# never touches the captain's active tab. Prints the record line on success.
fm_afk_launch_create_herdr() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session out wsid pane entry cmd label recovered create_result
  session=${captain_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$captain_target" ]; then
    fm_afk_launch_log "cannot derive herdr session from captain target '$captain_target'"
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || { fm_afk_launch_log "herdr server not ready for session '$session'"; return 1; }
  label=${FM_AFK_LAUNCH_LABEL:-"$FM_AFK_LAUNCH_WS_LABEL-$$-${RANDOM:-0}-$(date '+%s')"}
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  create_result=$?
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ "$create_result" -ne 0 ] && [ -n "$wsid" ] && [ -n "$pane" ]; then
    fm_afk_launch_log "herdr create failed after returning exact ids; closing $session:$pane"
    if fm_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
      FM_AFK_REC_BACKEND=herdr
      FM_AFK_REC_TARGET="$session:$pane"
      fm_afk_launch_close_recorded || true
    else
      fm_afk_launch_log "failed to persist exact id for failed herdr create"
    fi
    return 1
  fi
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    recovered=$(fm_afk_launch_herdr_recover_created "$session" "$label") || {
      fm_afk_launch_log "herdr create did not yield a recoverable exact workspace/pane id"
      return 1
    }
    IFS=$'\t' read -r wsid pane <<< "$recovered"
  fi
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write herdr "$session:$pane" "$wsid"; then
    fm_afk_launch_log "failed to persist herdr daemon terminal record; closing $session:$pane"
    fm_afk_launch_close_terminal herdr "$session:$pane"
    return 1
  fi
  if ! fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1; then
    fm_afk_launch_log "failed to run daemon in herdr pane $session:$pane; closing it"
    FM_AFK_REC_BACKEND=herdr
    FM_AFK_REC_TARGET="$session:$pane"
    fm_afk_launch_close_recorded || true
    return 1
  fi
  fm_afk_launch_commit_terminal herdr "$session:$pane" "$wsid" 1 || return 1
  fm_afk_launch_log "daemon launched in non-visible herdr workspace $wsid (pane $session:$pane), supervising $captain_target"
}

# Launch the daemon in a detached tmux session (never a split-window in the
# captain's window). tmux pane ids are server-global, so the daemon reaches the
# captain pane by its %id from this separate session.
fm_afk_launch_create_tmux() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 session entry cmd hash nonce
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(date '+%s')"
  session="fm-afk-daemon-$hash-$nonce"
  entry=$(fm_afk_launch_entry_cmd)
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q' \
    "$FM_HOME" "$captain_target" "$captain_backend" "$entry")
  if ! fm_afk_launch_record_write tmux "$session" ""; then
    fm_afk_launch_log "failed to persist planned tmux daemon session '$session'"
    return 1
  fi
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    fm_afk_launch_log "failed to create detached tmux daemon session '$session'"
    if ! rm -f "$FM_AFK_LAUNCH_RECORD"; then
      fm_afk_launch_log "failed to remove planned tmux daemon record after creation failure"
    fi
    return 1
  fi
  fm_afk_launch_commit_terminal tmux "$session" "" 1 || return 1
  fm_afk_launch_log "daemon launched in detached tmux session '$session', supervising $captain_target"
}

fm_afk_launch_start() {
  local captain_target captain_backend backup artifact had_afk=0 result lock_state=0
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 1
  fi
  # Capture the captain pane FIRST, before creating anything.
  captain_target=$(discover_supervisor_target) || {
    fm_afk_launch_log "could not resolve the captain supervisor pane (set FM_SUPERVISOR_TARGET)"; return 1; }
  captain_backend=$(discover_supervisor_backend) || {
    fm_afk_launch_log "could not resolve the captain supervisor backend (set FM_SUPERVISOR_BACKEND)"; return 1; }

  mkdir -p "$FM_AFK_LAUNCH_STATE"

  daemon_lock_state_resolved || lock_state=$?
  if [ "$lock_state" -eq 2 ]; then
    fm_afk_launch_refuse_ambiguous_lock 'start a second daemon'
    return 1
  fi
  if [ "$lock_state" -eq 0 ]; then
    fm_afk_launch_record_validate_if_present || return 1
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! fm_afk_launch_reconcile; then
    result=1
  else
    if fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      result=0
    else
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$captain_backend" in
      herdr) fm_afk_launch_create_herdr "$captain_target" "$captain_backend"; result=$? ;;
      tmux)  fm_afk_launch_create_tmux "$captain_target" "$captain_backend"; result=$? ;;
      *)
        fm_afk_launch_log "no non-visible daemon-launch primitive for backend '$captain_backend' yet (supported: herdr, tmux)"
        result=1
        ;;
    esac
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native() {
  local backup artifact had_afk=0 result=0 lock_state=0
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 1
  fi
  daemon_lock_state_resolved || lock_state=$?
  if [ "$lock_state" -eq 2 ]; then
    fm_afk_launch_refuse_ambiguous_lock 'start a second daemon'
    return 1
  fi
  if [ "$lock_state" -eq 0 ]; then
    fm_afk_launch_record_validate_if_present || return 1
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  fm_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    elif ! fm_afk_launch_flag_write; then
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_record_write none - native || result=1
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_stop() {
  local pid pid_identity current_identity result=0 read_result lock_state=0
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate). A live
  # holder must therefore never be left unsignalled just because its lock identity
  # is unreadable - it would be hard-killed with the terminal instead, losing the
  # flush. But the recorded pid alone cannot authorise a kill: the OS may have
  # recycled it onto an unrelated process. So an unidentifiable holder is signalled
  # only when daemon_lock_state_resolved positively attributes it to this home - it
  # is executing THIS home's daemon script and its own environment resolves to this
  # home and state dir, the same attribution bin/fm-watch-arm.sh requires before it
  # signals a watcher. Anything less is refused loudly, never killed or skipped.
  pid=""
  pid_identity=""
  daemon_lock_state_resolved || lock_state=$?
  if [ "$lock_state" -eq 2 ]; then
    fm_afk_launch_refuse_ambiguous_lock 'stop the daemon behind it'
    return 1
  fi
  if [ "$lock_state" -eq 0 ]; then
    # daemon_lock_pid reports a vanished pid file as EMPTY output on rc 0, not as a
    # failure, so an empty read must be handled exactly like a failed one: silently
    # skipping the fingerprint check and the SIGTERM on an empty pid would tear the
    # terminal down and clear state/.afk having said nothing.
    pid=$(daemon_lock_pid 2>/dev/null) || pid=""
    if [ -z "$pid" ]; then
      fm_afk_launch_log "away-mode daemon lock vanished while stopping; the daemon has already exited, continuing teardown"
    fi
  fi
  # A daemon that exits between the lock read above and these reads is the GOAL
  # state, not ambiguity: it has already run its own flush. Aborting here would skip
  # the terminal close and leave state/.afk set, half-exiting away mode with nothing
  # said - the fail-silent stand-down AGENTS.md section 8 forbids. So a pid that is
  # no longer alive drops through to teardown with a log, and only a LIVE pid we
  # cannot fingerprint (ps unavailable) is refused, loudly.
  if [ -n "$pid" ] && ! pid_identity=$(fm_pid_identity "$pid" 2>/dev/null); then
    if fm_pid_alive "$pid"; then
      fm_afk_launch_log "cannot fingerprint live away-mode daemon pid=$pid; refusing to signal it. If pid $pid is not the away-mode daemon, remove $FM_AFK_LOCK and retry."
      return 1
    fi
    fm_afk_launch_log "away-mode daemon pid=$pid already exited; continuing teardown"
    pid=""
  fi
  if [ -n "$pid" ]; then
    if ! kill -TERM "$pid" 2>/dev/null && fm_pid_alive "$pid"; then
      fm_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
      fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    }
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  # (2) Close the daemon's own terminal by exact id.
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_close_recorded || result=1
  fi
  # (3) Clear the away-mode flag LAST.
  if ! rm -f "$FM_AFK_LAUNCH_STATE/.afk"; then
    fm_afk_launch_log "failed to clear away-mode flag"
    result=1
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_log "away mode stopped; daemon terminal torn down and .afk cleared"
  else
    fm_afk_launch_log "away mode stopped; terminal teardown remains recorded for retry"
  fi
  return "$result"
}

fm_afk_launch_main() {
  local result
  fm_afk_launch_lock_acquire || return 1
  trap fm_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "${1:-start}" in
    start) fm_afk_launch_start ;;
    start-native) fm_afk_launch_start_native ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_lock_release || result=1
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
