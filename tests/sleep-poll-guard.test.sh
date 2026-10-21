#!/bin/bash
# sleep-poll-guard: the eight smoke cases from the hook header.
H="$(cd "$(dirname "$0")/.." && pwd)/hooks/sleep-poll-guard.sh"
fail=0
check() {  # $1=expected exit (2 block, 0 allow)  $2=command
  jq -nc --arg c "$2" '{tool_input:{command:$c}}' | bash "$H" 2>/dev/null; r=$?
  [ "$r" = "$1" ] && echo "ok   exit $r  $2" || { echo "FAIL exit $r (want $1)  $2"; fail=1; }
}
check 2 'sleep 590; tail -3 enrich.log'
check 2 'cmd && sleep 60; tail x.log'
check 2 'psql -f q.sql > /tmp/o 2>&1 & echo launched; sleep 25; tail -6 /tmp/o'
check 0 'until curl -sf localhost:8080; do sleep 2; done'
check 0 'for i in $(seq 1 60); do out=$(cmd); case "$out" in *ok*) break;; esac; sleep 15; done'
check 0 'for i in 1 2 3; do sleep 10; tail -1 x.log; done'
check 0 'sleep 3; echo hi'
check 0 'tail -3 enrich.log'
exit $fail
