#!/bin/bash
# Run every test; fail if any exits non-zero or prints FAIL.
D=$(cd "$(dirname "$0")" && pwd); rc=0
for t in "$D"/secret-scan-cases/run.sh "$D"/*.test.sh; do
  echo "== ${t#$D/}"; out=$(bash "$t" 2>&1); r=$?; echo "$out"
  { [ $r -ne 0 ] || grep -q '^FAIL' <<<"$out"; } && rc=1
done
[ $rc -eq 0 ] && echo "all tests passed" || echo "TESTS FAILED"
exit $rc
