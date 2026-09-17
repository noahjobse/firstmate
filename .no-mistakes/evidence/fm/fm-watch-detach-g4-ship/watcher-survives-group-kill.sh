#!/usr/bin/env bash
# End-to-end demonstration (real bin/fm-watch-arm.sh + real bin/fm-watch.sh):
# a group-wide SIGKILL to the arm no longer takes the confirmed watcher down.
set -u
ROOT=/home/noah/.no-mistakes/worktrees/59b283f7eae9/01M2R0AHVASW7D8WFV8FB60C6Q
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
dir=$(mktemp -d); home="$dir/home"; state="$dir/state"; fakebin="$dir/fakebin"
mkdir -p "$home/data" "$fakebin"; armout="$dir/arm.out"
# minimal tmux stub so the real watcher/arm run headless
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fakebin/tmux"

set -m   # launch the arm as leader of its OWN fresh process group, like a harness bg task
PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$WATCH_ARM" > "$armout" 2>&1 &
armpid=$!
set +m

for i in $(seq 1 100); do grep -q '^watcher: started ' "$armout" 2>/dev/null && break; sleep 0.1; done
watcher_pid=$(grep -o '^watcher: started pid=[0-9]*' "$armout" | head -1 | grep -o '[0-9]*$')
armpgid=$(ps -o pgid= -p "$armpid" | tr -d ' ')
watchpgid=$(ps -o pgid= -p "$watcher_pid" | tr -d ' ')
beat="$state/.last-watcher-beat"
before=$(stat -c %Y "$beat")

echo   "arm confirmation line : $(grep '^watcher: started' "$armout")"
echo   "arm  pid=$armpid  pgid=$armpgid"
echo   "watcher pid=$watcher_pid  pgid=$watchpgid"
if [ "$armpgid" != "$watchpgid" ]; then
  echo "=> watcher is in its OWN process group (detached): $armpgid != $watchpgid"
else
  echo "=> watcher SHARES the arm's process group (NOT detached)"
fi
echo   "beacon mtime before kill: $before"

echo   ">>> sending SIGKILL to the arm's WHOLE process group (-$armpgid), as a misfiring memory guard would"
kill -KILL -- "-$armpgid" 2>/dev/null
for i in $(seq 1 50); do kill -0 "$armpid" 2>/dev/null || break; sleep 0.1; done
wait "$armpid" 2>/dev/null || true
echo   "arm alive after group kill : $(kill -0 "$armpid" 2>/dev/null && echo yes || echo no)"
echo   "watcher alive after group kill (pid $watcher_pid): $(kill -0 "$watcher_pid" 2>/dev/null && echo yes || echo no)"

sleep 2
after=$(stat -c %Y "$beat")
echo   "beacon mtime after 2s   : $after"
if [ "$after" != "$before" ]; then echo "=> surviving watcher is STILL beating its liveness beacon"; fi

# cleanup the surviving watcher
kill -TERM "$watcher_pid" 2>/dev/null || true; sleep 0.5; kill -KILL "$watcher_pid" 2>/dev/null || true
rm -rf "$dir"
