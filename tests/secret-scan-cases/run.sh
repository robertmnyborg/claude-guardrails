#!/bin/bash
# each clean line must exit 0, each dirty line must exit 1
# dirty cases are stored ROT13-encoded and reversed per line so the planted fake secrets do not trip push protection
D=$(cd "$(dirname "$0")" && pwd)
S=${1:-$D/../../bin/secret-scan}
fail=0
while IFS= read -r l; do printf '%s\n' "$l" | "$S" --stdin 2>/dev/null; r=$?; [ $r -eq 0 ] && echo "ok   clean  $r" || { echo "FAIL clean  $r: ${l:0:40}"; fail=1; }; done < $D/clean.txt
n=0; while IFS= read -r l; do n=$((n+1)); printf '%s\n' "$l" | "$S" --stdin 2>/dev/null; r=$?; [ $r -eq 1 ] && echo "ok   dirty  $r (#$n)" || { echo "FAIL dirty  $r (#$n)"; fail=1; }; done < <(rev "$D/dirty.enc" | tr "A-Za-z" "N-ZA-Mn-za-m")
exit $fail
