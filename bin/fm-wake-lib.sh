#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.
# A lock holder that carries identity metadata (the watcher, the away-mode daemon)
# passes a stage function to fm_lock_try_create/fm_lock_try_acquire so that
# identity is written into the owner dir BEFORE the lock symlink publishes it; a
# holder must never write lock metadata through the lock path afterwards. See
# fm_lock_stage_owner_meta and docs/incidents/2026-07-12-torn-watcher-lock.md.
# The acquire helpers distinguish three outcomes: 0 held, 1 lost to another holder
# (FM_LOCK_HELD_PID), and 2 when this holder could not build a lock at all and no
# live holder exists (FM_LOCK_STAGE_FAILED) - which is our own failure, not
# contention, and callers must fail loudly on it rather than stand down.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# The kernel's own start time for a pid: boot-relative clock ticks, /proc/<pid>/stat
# field 22. comm (field 2) is parenthesised and may itself contain spaces or ')',
# so fields are counted from after the LAST ')'. Absent where /proc is (macOS).
fm_pid_start_ticks() {
  local pid=$1
  [ -r "/proc/$pid/stat" ] || return 1
  awk '{ s = $0; sub(/^.*\) /, "", s); n = split(s, f, " "); if (n < 20) exit 1; print f[20] }' \
    "/proc/$pid/stat" 2>/dev/null
}

fm_pid_identity() {
  local pid=$1 start cmd
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  # Pin LC_ALL=C so ps's output is locale-invariant: the identity is written under
  # one locale but re-read under the machine's ambient locale, which would
  # otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  cmd=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || return 1
  [ -n "$cmd" ] || return 1
  # The start half must be byte-stable across reads, or a live watcher's own lock
  # reads as a reused pid and supervision reports itself down. `ps -o lstart=` is
  # NOT byte-stable: it is DERIVED, from the kernel's btime plus the process's
  # starttime ticks. starttime never moves, but btime is recomputed and jitters by
  # ~1s (measured on this WSL2 host, roughly every 30s), and every jump shifts the
  # derived lstart of every live process - so an lstart fingerprint goes stale
  # against its OWN process, with no second writer, and reports a live watcher as a
  # reused pid. That drift is the primary cause of the false alarms and the
  # lock-yank outage in docs/incidents/2026-07-12-torn-watcher-lock.md.
  # /proc/<pid>/stat field 22 is boot-relative and immune, so it is the fix, not an
  # optimisation: do not "simplify" this back to lstart.
  # lstart survives only as the fallback where /proc does not exist, and it is an
  # ACTIVELY DRIFTING primitive there, not an equivalent one. On a host with no
  # /proc AND a jittering btime, this class of false alarm is NOT fixed.
  start=$(fm_pid_start_ticks "$pid") \
    || start=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) \
    || return 1
  start=$(printf '%s' "$start" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -n "$start" ] || return 1
  printf '%s %s\n' "$start" "$cmd" | sed 's/^[[:space:]]*//'
}

# Whether THIS host exposes start ticks at all, asked of a pid that is certainly
# alive and certainly ours. Host capability and one pid's readability are separate
# questions: a pid whose /proc entry is missing has either exited or is hidden
# from us, and neither means the host produces lstart identities.
fm_host_identity_format() {
  # $$ and not fm_current_pid: fm_current_pid reports the pid of whatever subshell
  # evaluates it, and a command substitution's subshell has already exited by the
  # time its /proc entry is read, which would report a Linux host as lstart-only.
  if fm_pid_start_ticks "$$" >/dev/null 2>&1; then
    printf 'ticks\n'
  else
    printf 'lstart\n'
  fi
}

# Which format fm_pid_identity produces for <pid>: "ticks" where the kernel
# exposes that pid's start ticks (/proc), "lstart" on a host with no /proc at all.
# Returns non-zero, printing nothing, when the host DOES expose start ticks but
# this pid's stat cannot be read - the pid exited under us, or its /proc entry is
# hidden - because that is an unknown format, not an lstart one. Inferring
# "lstart" there would make a ticks identity look like a legacy one and send the
# caller a manual-remediation instruction for a holder that is simply gone.
fm_pid_identity_format() {
  local pid=$1
  if fm_pid_start_ticks "$pid" >/dev/null 2>&1; then
    printf 'ticks\n'
    return 0
  fi
  [ "$(fm_host_identity_format)" = lstart ] || return 1
  printf 'lstart\n'
}

# Whether the start half of a RECORDED identity is in the format this host
# currently produces, in three states: 0 it is, 1 it is a legacy format this code
# no longer produces, 2 the format cannot be determined for this pid. This is not
# a dual-format compare - an identity in the other format is never accepted as a
# match, only reported as unreadable - so a caller can tell a different process
# apart from a holder this code cannot identify at all.
fm_identity_is_current_format() {
  local pid=$1 identity=$2 head format
  [ -n "$identity" ] || return 1
  format=$(fm_pid_identity_format "$pid") || return 2
  head=${identity%%[[:space:]]*}
  case "$format" in
    ticks)
      case "$head" in
        ''|*[!0-9]*) return 1 ;;
      esac
      ;;
    *)
      case "$head" in
        ''|*[!0-9]*) ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 0
}

# Check a live pid against a lock's recorded identity, in three states:
#   0 the pid IS the holder that recorded this identity;
#   1 the pid is provably NOT that holder (it is dead, or a different live process);
#   2 the holder cannot be identified - the recorded identity is in a format this
#     code no longer produces (written by a holder that started before an in-place
#     update), or ps cannot fingerprint the live pid.
# Ambiguity must never be read as "dead". That assumption is what evicted a live
# watcher in docs/incidents/2026-07-12-torn-watcher-lock.md, so every consumer
# picks the fail-closed direction for what it is about to do: a caller about to
# EVICT a lock or start a second supervisor treats 2 as still held, and a caller
# about to SIGNAL the pid treats 2 as not ours.
# A pid that exits mid-check reports 1, not 2: every read below can fail simply
# because the process went away between the aliveness check and the read, and a
# holder that is merely DEAD is provably not the holder. Only a pid still alive
# after a failed read is genuinely unidentifiable.
fm_pid_matches_identity() {
  local pid=$1 identity=$2 current
  [ -n "$identity" ] || return 1
  fm_pid_alive "$pid" || return 1
  if ! fm_identity_is_current_format "$pid" "$identity"; then
    fm_pid_alive "$pid" || return 1
    return 2
  fi
  if ! current=$(fm_pid_identity "$pid"); then
    fm_pid_alive "$pid" || return 1
    return 2
  fi
  [ "$current" = "$identity" ]
}

# A path as the filesystem sees it, so two spellings of one directory compare
# equal. An unresolvable path falls back to its literal form with trailing slashes
# trimmed, so normalisation can only make a comparison more accurate; it never
# makes two genuinely different paths compare equal.
fm_path_canonical() {
  local path=$1 resolved
  [ -n "$path" ] || return 1
  if resolved=$(cd -P "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$resolved"
    return 0
  fi
  while [ "$path" != "/" ] && [ "$path" != "${path%/}" ]; do
    path=${path%/}
  done
  printf '%s\n' "$path"
}

# The same normalisation for a FILE path: its directory as the filesystem sees it,
# plus the file's own name. The script path recorded in a lock is compared against
# the path the reader was invoked with, and those two spellings of one script (a
# symlinked bin dir, a trailing-slash-differing invocation) must compare equal or
# a live watcher reads as a stranger.
fm_path_canonical_file() {
  local path=$1 dir base
  [ -n "$path" ] || return 1
  base=$(basename -- "$path")
  dir=$(fm_path_canonical "$(dirname -- "$path")") || return 1
  [ "$dir" = / ] && dir=
  printf '%s/%s\n' "$dir" "$base"
}

fm_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

fm_pid_is_interpreter_word() {
  case "$(basename "$1")" in
    env|sh|bash|dash|ksh|zsh) return 0 ;;
  esac
  return 1
}

# True when the command line's leading program IS <command>: either the whole line
# or the line up to the first argument. Compared as a prefix of the untokenised
# line, so a program path containing spaces still matches - word-splitting the
# line would truncate such a path and silently report a live watcher as not
# running its own script.
fm_cmdline_leading_program_is() {
  local cmdline=$1 command=$2
  [ "$cmdline" = "$command" ] && return 0
  case "$cmdline" in
    "$command "*) return 0 ;;
  esac
  return 1
}

fm_cmdline_drop_leading_word() {
  local cmdline=$1 word
  word=${cmdline%%[[:space:]]*}
  cmdline=${cmdline#"$word"}
  while [ "$cmdline" != "${cmdline#[[:space:]]}" ]; do
    cmdline=${cmdline#[[:space:]]}
  done
  printf '%s' "$cmdline"
}

# True when <pid> is EXECUTING <command>, i.e. the path is the program being run
# (argv[0], or the script argument of an interpreter, since a shebang script runs
# as `bash /path/script`). A free substring match over the command line would also
# accept a process that merely NAMES the path in its arguments (an editor, a grep,
# a tail), and callers signal what this vouches for - so the match is anchored to
# the leading program, never the arguments.
fm_pid_runs_command() {
  local pid=$1 command=$2 cmdline word depth=0
  [ -n "$command" ] || return 1
  cmdline=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || return 1
  [ -n "$cmdline" ] || return 1
  # Peel at most two interpreter words: a shebang script runs as `bash /path`, and
  # `#!/usr/bin/env bash` runs as `env bash /path` on some systems. Anything else
  # leading the line (grep, tail, an editor) is not executing the script.
  while :; do
    fm_cmdline_leading_program_is "$cmdline" "$command" && return 0
    [ "$depth" -lt 2 ] || return 1
    word=${cmdline%%[[:space:]]*}
    [ -n "$word" ] || return 1
    fm_pid_is_interpreter_word "$word" || return 1
    cmdline=$(fm_cmdline_drop_leading_word "$cmdline")
    [ -n "$cmdline" ] || return 1
    depth=$((depth + 1))
  done
}

# Read one variable out of another process's OWN environment. Linux-only: where
# /proc is unavailable (macOS) or the environ is unreadable, this fails, and
# callers must treat that as "cannot attribute" rather than as a match.
fm_pid_env_value() {
  local pid=$1 name=$2 environ entry
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "$name" ] || return 1
  environ="/proc/$pid/environ"
  [ -r "$environ" ] || return 1
  while IFS= read -r -d '' entry; do
    case "$entry" in
      "$name"=*)
        printf '%s\n' "${entry#"$name"=}"
        return 0
        ;;
    esac
  done < "$environ"
  return 1
}

# Positively attribute a live pid to a firstmate home, resolving the home the way
# this library resolves its own (FM_HOME, then FM_ROOT_OVERRIDE, then FM_ROOT,
# then the default root of the script the process runs). Callers use this before
# signalling a process they matched only by command path: bin/fm-watch.sh is
# SHARED by every home, secondmates included, so a command match alone cannot
# distinguish this home's watcher from a sibling's - the cross-home hazard
# AGENTS.md warns about with `pkill -f bin/fm-watch.sh`. A process whose home
# cannot be positively read (no /proc) is unattributable and must never be
# signalled.
# Whether a process's home can be read at all here. False means unattributable
# (no /proc, or a foreign-owner environ we may not read), never "different home".
fm_pid_home_readable() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$pid/environ" ]
}

fm_pid_resolved_home() {
  local pid=$1 default_root=${2:-$FM_WAKE_DEFAULT_ROOT} name value
  for name in FM_HOME FM_ROOT_OVERRIDE FM_ROOT; do
    if value=$(fm_pid_env_value "$pid" "$name"); then
      [ -n "$value" ] || continue
      printf '%s\n' "$value"
      return 0
    fi
  done
  # The environ is readable and carries no home override, so the process runs in
  # the default home of the script it executes - which the caller has already
  # matched against this home's own script path.
  printf '%s\n' "$default_root"
}

fm_pid_resolved_state() {
  local pid=$1 home=$2 name value
  for name in FM_STATE_OVERRIDE STATE; do
    if value=$(fm_pid_env_value "$pid" "$name"); then
      [ -n "$value" ] || continue
      printf '%s\n' "$value"
      return 0
    fi
  done
  printf '%s/state\n' "$home"
}

# Two supervision domains can share a home root and still be separate: the legacy
# FM_STATE_OVERRIDE points them at different state dirs, so each holds its own
# .watch.lock. Attribution therefore compares the target's resolved STATE as well
# as its home; a process whose lock lives elsewhere is a different domain and must
# never be signalled from here.
# Both sides are canonicalised because they arrive spelled differently: FM_HOME is
# whatever the captain's environment says, trailing slash and symlinks included,
# while the no-override fallback returns the physically resolved
# FM_WAKE_DEFAULT_ROOT. A raw string compare therefore fails a home against its
# OWN watcher, and the caller then treats a live, attributable watcher as a
# stranger and yanks its lock instead of stopping it.
fm_pid_home_matches() {
  local pid=$1 home=$2 state=${3:-$STATE} default_root=${4:-$FM_WAKE_DEFAULT_ROOT} pid_home
  [ -n "$home" ] || return 1
  fm_pid_alive "$pid" || return 1
  fm_pid_home_readable "$pid" || return 1
  pid_home=$(fm_pid_resolved_home "$pid" "$default_root")
  [ "$(fm_path_canonical "$pid_home")" = "$(fm_path_canonical "$home")" ] || return 1
  [ "$(fm_path_canonical "$(fm_pid_resolved_state "$pid" "$pid_home")")" = "$(fm_path_canonical "$state")" ]
}

# 0 when the lock positively vouches for <pid> as this home's watcher, 2 when the
# recorded identity cannot be identified (fm_pid_matches_identity), 1 otherwise.
# Callers that vouch for a watcher (fm_watcher_healthy) accept only 0, so an
# unidentifiable holder is never reported healthy; callers that would evict or
# signal read the distinction and fail closed.
fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ -n "$lock_path" ] || return 1
  [ "$(fm_path_canonical "$lock_home")" = "$(fm_path_canonical "$home")" ] || return 1
  [ "$(fm_path_canonical_file "$lock_path")" = "$(fm_path_canonical_file "$watch_path")" ] || return 1
  [ -n "$lock_identity" ] || return 1
  fm_pid_matches_identity "$pid" "$lock_identity"
}

FM_WATCHER_HEALTHY_PID=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid age
  FM_WATCHER_HEALTHY_PID=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  return 0
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

# An owner dir is this holder's private staging area, and a stage hook may put any
# filename in it, so its contents are cleared generically rather than by a fixed
# name list. A leftover file would defeat the rmdir and strand a
# <lock>.owner.XXXXXX dir in the state dir on every acquire, and a state dir that
# slowly fills is exactly what turns an ordinary lock failure into a supervision
# outage. The pattern guard keeps the recursive remove aimed only at dirs
# fm_lock_owner_dir minted; anything else falls back to the conservative path.
fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  case "${ownerdir##*/}" in
    *.owner.??????)
      if [ -d "$ownerdir" ] && [ ! -L "$ownerdir" ]; then
        rm -rf "$ownerdir" 2>/dev/null || true
        return 0
      fi
      ;;
  esac
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  # On the try_create path the owner dir is already published behind the lock
  # symlink and fm_lock_prepare_owner already recorded this pid. Rewriting it
  # would truncate a file readers reach through the lock, and a reader landing in
  # that window would see an empty pid - which every consumer reads as "no live
  # holder". Holders never write into a published owner dir; only a late claimant
  # of an owner dir it prepared itself (and has not published) writes here.
  if [ "$back" != "$mypid" ]; then
    if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
      fm_lock_discard_owner "$ownerdir"
      return 1
    fi
    back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  fi
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

# A lock must never be visible in a half-written state. Any identity metadata a
# holder wants the lock to carry (fm-home, watcher-path, pid-identity) is staged
# into the owner dir by this hook BEFORE the lock symlink publishes it, so the
# lock a reader sees is always complete and self-consistent. The alternative -
# claiming the lock and then writing metadata through the lock path - is what
# produced the torn locks in docs/incidents/2026-07-12-torn-watcher-lock.md: a
# late write lands in whichever owner dir the symlink names at that instant,
# which may be a different holder's, leaving a lock whose pid names one process
# and whose pid-identity fingerprints another. Holders must therefore write lock
# metadata ONLY through a stage function, never through the lock path.
fm_lock_stage_owner_meta() {
  local ownerdir=$1 stage_fn=${2:-}
  [ -n "$stage_fn" ] || return 0
  "$stage_fn" "$ownerdir"
}

# The one gate every own-failure path goes through, so rc 2 can only ever mean
# what it claims: we could not build a lock AND no lock exists. The failures that
# stop us from building a lock - an unwritable or full state dir - are exactly the
# ones that leave an existing holder's lock sitting untouched on disk, so a lock
# that is present makes this contention (rc 1), never our own failure. Reporting a
# held lock as "nothing is armed" is what lets a caller declare supervision dead
# and its repair path terminate a live, healthy watcher because the disk is full.
fm_lock_own_failure_rc() {
  local lockdir=$1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    return 1
  fi
  # shellcheck disable=SC2034 # Read by callers after the lock helpers return.
  FM_LOCK_STAGE_FAILED=1
  return 2
}

# Returns 0 when the lock is held, 2 when this holder could not build a lock of
# its own at all (an unwritable or full state dir, mktemp failing, ps unavailable
# to the stage hook) AND no lock exists, and 1 for every ordinary loss to another
# holder. An own failure is OUR problem, not contention, and callers must not
# report it as "someone else holds the lock": the lock does not exist and nothing
# is running, so a caller that mistook it for contention would exit quietly and
# leave supervision unarmed. The converse matters just as much: an existing lock
# is checked first, and every own-failure path re-checks through
# fm_lock_own_failure_rc, so a live holder is never downgraded to rc 2. Every
# own-failure exit sets FM_LOCK_STAGE_FAILED, and ONLY those: the three lock
# signals are cleared on entry so a direct caller cannot read a flag left behind
# by an earlier acquire.
fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} stage_fn=${3:-} ownerdir
  FM_LOCK_OWNER_DIR=
  FM_LOCK_HELD_PID=
  FM_LOCK_STAGE_FAILED=
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    return 1
  fi
  if ! ownerdir=$(fm_lock_owner_dir "$lockdir") || [ -z "$ownerdir" ]; then
    fm_lock_own_failure_rc "$lockdir"
    return
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    fm_lock_own_failure_rc "$lockdir"
    return
  fi
  if ! fm_lock_stage_owner_meta "$ownerdir" "$stage_fn"; then
    fm_lock_discard_owner "$ownerdir"
    fm_lock_own_failure_rc "$lockdir"
    return
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

# The one gate every contention path goes through. The steal mutex is acquired
# through this same function, so its own failures set FM_LOCK_STAGE_FAILED; a
# contention return that carried that flag onwards would hand the caller both
# signals at once and contradict the contract that ONLY own failures set it.
fm_lock_contention_rc() {
  local lockdir=$1 pid=${2:-}
  [ -n "$pid" ] || pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  # shellcheck disable=SC2034 # Read by callers after the lock helpers return.
  FM_LOCK_HELD_PID=$pid
  FM_LOCK_OWNER_DIR=
  FM_LOCK_STAGE_FAILED=
  return 1
}

# fm_lock_try_acquire <lockdir> [<stage_fn>]
# stage_fn, when given, stages this holder's identity metadata into the owner dir
# before the lock is published (see fm_lock_stage_owner_meta). It is deliberately
# NOT passed to the internal steal mutex below: that is a different lock with no
# identity of its own.
# Returns 0 held, 2 when this holder could not build a lock at all AND no live
# holder exists (FM_LOCK_STAGE_FAILED is set; a lock file may still sit on disk
# from a dead holder, but nothing is running), 1 lost to the holder in
# FM_LOCK_HELD_PID (FM_LOCK_STAGE_FAILED cleared). Own failures return before the
# steal path: stealing is pointless when we cannot create an owner dir, and
# recursing into the steal mutex on a state dir we cannot write would recurse
# without bound.
fm_lock_try_acquire() {
  local lockdir=$1 stage_fn=${2:-} pid steal cur rc steal_owner primary_owner create_rc steal_rc
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=
  FM_LOCK_STAGE_FAILED=

  fm_lock_try_create "$lockdir" '' "$stage_fn"
  create_rc=$?
  if [ "$create_rc" -eq 0 ]; then
    return 0
  fi
  if [ "$create_rc" -eq 2 ]; then
    return 2
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    fm_lock_contention_rc "$lockdir" "$pid"
    return
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    fm_lock_contention_rc "$lockdir" "$pid"
    return
  fi

  steal="$lockdir.steal"
  fm_lock_try_acquire "$steal"
  steal_rc=$?
  if [ "$steal_rc" -eq 2 ]; then
    # We reached the steal path because the primary lock exists with a dead
    # holder, and now cannot build the steal mutex either. Before calling that an
    # own failure, look once more for a live holder: a fresh watcher may have
    # claimed the lock while we were here, and rc 2 promises nothing is running.
    cur=$(cat "$lockdir/pid" 2>/dev/null || true)
    if fm_pid_alive "$cur"; then
      fm_lock_contention_rc "$lockdir" "$cur"
      return
    fi
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=
    FM_LOCK_OWNER_DIR=
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_STAGE_FAILED=1
    return 2
  fi
  if [ "$steal_rc" -ne 0 ]; then
    fm_lock_contention_rc "$lockdir"
    return
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    fm_lock_contention_rc "$lockdir" "$cur"
    return
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    fm_lock_contention_rc "$lockdir" "$cur"
    return
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    fm_lock_contention_rc "$lockdir"
    return
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    fm_lock_contention_rc "$lockdir"
    return
  fi

  fm_lock_remove_path "$lockdir" || true
  fm_lock_try_create "$lockdir" "$steal_owner" "$stage_fn"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    fm_lock_release "$steal"
    FM_LOCK_OWNER_DIR=
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    fm_lock_release "$steal"
    fm_lock_contention_rc "$lockdir"
    return
  fi
  fm_lock_release "$steal"
  return "$rc"
}

# Waits out contention (rc 1: another holder, which always ends), but never an own
# failure (rc 2: we cannot build a lock at all and no live holder exists, so no
# holder is coming to release anything). That condition is permanent, so
# retrying it would spin forever - and a caller blocked here queues nothing and
# surfaces nothing, which is a silent total supervision failure. Returns 2, with
# FM_LOCK_STAGE_FAILED set, so the caller can fail loudly instead.
fm_lock_acquire_wait() {
  local lockdir=$1 rc
  while :; do
    fm_lock_try_acquire "$lockdir"
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 2 ]; then
      printf 'fm_lock_acquire_wait: cannot create the lock %s (state dir unwritable or full, or ps unavailable)\n' "$lockdir" >&2
      return 2
    fi
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 clean_key clean_payload epoch seq seq_file status
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  status=0

  if ! fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; then
    printf 'fm_wake_append: could not lock the wake queue in %s; the %s wake was NOT queued\n' "$STATE" "$kind" >&2
    return 1
  fi
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}
