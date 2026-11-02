#!/bin/bash
# Re-checks the numbers quoted in the bug report.
set -u
cd "$(dirname "$0")"
fail() { echo "MISMATCH: $*"; exit 1; }
# reproducer file must be the version used by the logged runs
[ "$(sha256sum repro/repro.kernsight.prog | cut -d' ' -f1)" = "b9740e789ed936ed615ea52351dae844af99f268174055d2251f3960b68c2975" ] \
    || fail "repro.kernsight.prog sha256"
grep -q "parsed 50 programs" logs/execprog-verify4.out || fail "parsed-50 line"
grep -q "parsed 49 programs" logs/execprog-twostep-step1.out || fail "parsed-49 line (two-step)"
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" logs/serial-twostep.log \
    || fail "two-step hung task line"
grep -q "in-flight: .*vtpm_proxy_work" logs/dmesg-sysrq-twostep.txt \
    || fail "two-step dump: in-flight work"
# hung-task reports in the three reproduction logs
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" logs/serial-7.3-auto-repro.log \
    || fail "auto-repro hung task line"
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" logs/serial-7.3-manual-repro.log \
    || fail "manual run 1 hung task line"
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" logs/serial-verify4.log \
    || fail "manual run 2 (verify4) hung task line"
grep -q "blocked for more than 163 seconds" logs/serial-verify4.log || fail "163 s report"
grep -q "state:D stack:26264 pid:10857 tgid:10857 ppid:10246" logs/serial-verify4.log \
    || fail "verify4 task header fields"
grep -q "locks held by kworker/3:2/1235: 2, on CPU#3" logs/serial-verify4.log \
    || fail "verify4 worker fields"
# tpm timeout lines while blocked
[ "$(grep -c 'Operation Timed out' logs/serial-7.3-manual-repro.log)" -ge 2 ] \
    || fail "manual run 1 tpm timeout count"
[ "$(grep -c 'Operation Timed out' logs/serial-verify4.log)" -ge 1 ] \
    || fail "verify4 tpm timeout count"
# run 1 dump: full kworker stack + backlog + blocked release
D=logs/vtpm-sysrq-t-all-tasks.txt
grep -q "Workqueue: tpm-vtpm vtpm_proxy_work" $D || fail "run1 dump: kworker workqueue line"
grep -q "vtpm_proxy_request_locality" $D || fail "run1 dump: kworker stack"
grep -q "vtpm_proxy_fops_release" $D || fail "run1 dump: blocked release stack"
grep -q "inactive: .*vtpm_proxy_work" $D || fail "run1 dump: workqueue backlog"
# verify3 dump: backlog + close_range entry path (kworker stack rotated out of the log buffer)
D=logs/dmesg-sysrq-verify3.txt
grep -q "in-flight: .*vtpm_proxy_work for 75s" $D || fail "verify3 dump: in-flight work"
grep -q "inactive: .*vtpm_proxy_work" $D || fail "verify3 dump: workqueue backlog"
grep -q "vtpm_proxy_fops_release" $D || fail "verify3 dump: blocked release stack"
grep -q "ORIG_RAX: 00000000000001b4" $D || fail "verify3 close_range path"
# verify4 dump: backlog + do_exit entry path
D=logs/dmesg-sysrq-verify4.txt
grep -q "in-flight: .*vtpm_proxy_work for 109s" $D || fail "verify4 dump: in-flight work"
grep -q "inactive: .*vtpm_proxy_work" $D || fail "verify4 dump: workqueue backlog"
grep -q "vtpm_proxy_fops_release" $D || fail "verify4 dump: blocked release stack"
grep -aq "do_exit" $D || fail "verify4 do_exit path"
# bare runs recorded no hang
for i in 1 2 3 4; do
    grep -q "blocked for more than" logs/serial-7.3-bare-no-trigger-$i.log \
        && fail "bare run $i unexpectedly recorded a hang"
done
# factorial experiment: sequence parsed, no hang in the two negative arms
grep -q "parsed 50 programs" logs/controlled/execprog-A-2.out || fail "factorial A-2 parsed line"
grep -q "parsed 50 programs" logs/controlled/execprog-B-2.out || fail "factorial B-2 parsed line"
for i in 1 2; do
    grep -q "blocked for more than" logs/controlled/serial-A-$i.log && fail "factorial A-$i unexpectedly hung"
    grep -q "blocked for more than" logs/controlled/serial-B-$i.log && fail "factorial B-$i unexpectedly hung"
done
# manifest must not contain itself
grep -q "MANIFEST.sha256" MANIFEST.sha256 && fail "MANIFEST contains itself"
echo "all checks passed"
