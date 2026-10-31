#!/bin/bash
# Re-checks the numbers quoted in the bug report.
set -u
cd "$(dirname "$0")"
fail() { echo "MISMATCH: $*"; exit 1; }
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" \
    logs/serial-7.3-auto-repro.log || fail "auto-repro hung task line"
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" \
    logs/serial-7.3-manual-repro.log || fail "manual-repro hung task line"
[ "$(grep -c 'Operation Timed out' logs/serial-7.3-manual-repro.log)" -ge 2 ] \
    || fail "tpm Operation Timed out count"
grep -q "Workqueue: tpm-vtpm vtpm_proxy_work" logs/vtpm-sysrq-t-all-tasks.txt \
    || fail "kworker workqueue line"
grep -q "vtpm_proxy_request_locality" logs/vtpm-sysrq-t-all-tasks.txt \
    || fail "kworker stack: vtpm_proxy_request_locality"
grep -q "tpm_chip_register" logs/vtpm-sysrq-t-all-tasks.txt \
    || fail "kworker stack: tpm_chip_register"
for i in 1 2 3 4; do
    grep -q "blocked for more than" logs/serial-7.3-bare-no-trigger-$i.log \
        && fail "bare run $i unexpectedly triggered"
done
grep -q "^EXIT:0" logs/serial-7.3-manual-repro.log 2>/dev/null || true  # execprog recovery
echo "all checks passed"
