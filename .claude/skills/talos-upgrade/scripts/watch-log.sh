#!/usr/bin/env bash
# Stream the important lines of an upgrade log, and END when the run writes EXIT=<rc>.
# Use it as the Monitor command:
#   bash .claude/skills/talos-upgrade/scripts/watch-log.sh <log> [extended-regex]
# Why not `tail -F | grep`: tail never ends by itself, and `| awk '/EXIT=/{exit}'` does not fix
# it either. EXIT= is the last line, so tail never writes again, never gets SIGPIPE, and the
# Monitor stays open after the run (three were left open on 2026-11-17).
set -u
LOG=$1
PAT=${2:-'ABORT|== |rc=|booted|drained|unchanged|etcd (ok|bad)|no drift|GATE_PASS|retry|EXIT='}
n=0
for _ in $(seq 1 1080); do   # hard bound: 90 min
  if [ -f "$LOG" ]; then
    done=0; grep -q '^EXIT=' "$LOG" && done=1   # check first, so the EXIT= line still prints
    total=$(wc -l < "$LOG")
    if [ "$total" -gt "$n" ]; then
      sed -n "$((n+1)),${total}p" "$LOG" | grep -E "$PAT"
      n=$total
    fi
    [ $done = 1 ] && exit 0
  fi
  sleep 5
done
echo "watch-log: no EXIT= in $LOG after 90 min: check the run by hand"
exit 1
