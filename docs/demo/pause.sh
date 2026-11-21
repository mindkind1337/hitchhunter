#!/bin/bash
# pause.sh <ms> [server folder]: pause a TEST server's whole FXServer process for <ms> (SIGSTOP, then SIGCONT), so
# its server, network and sync threads all stall at once. The process is picked by its working directory (the
# server folder, default: the current one), never by name alone. Never on a server with players.
MS=${1:-600}
DIR=$(cd "${2:-.}" && pwd)
PIDS=""
for p in $(pgrep -u "$(id -u)" -f 'FXServer'); do
    [ "$(readlink "/proc/$p/cwd")" = "$DIR" ] || continue
    grep -q 'FXServer' "/proc/$p/cmdline" || continue
    PIDS="$PIDS $p"
done
[ -n "$PIDS" ] || { echo "no FXServer running in $DIR"; exit 1; }
echo "pausing$PIDS for $MS ms"
kill -STOP $PIDS; sleep "$(awk "BEGIN{print $MS/1000}")"; kill -CONT $PIDS
