#!/bin/bash
# Re-checks the numbers quoted in the bug report.
# Scope: (a) semantic checks on the original campaign evidence (repro/,
# logs/) and the follow-up evidence (patch-ab-test-20261107/,
# tcg-topology-20261109/), and (b) an integrity check of every tracked
# file via MANIFEST.sha256 (regenerate it whenever files change).
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
# (these four logs + the auto-repro log = the 4/4 positive cell of the
#  2x2 experiment; the two negative arms are checked in their own
#  section below)
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" logs/serial-7.3-auto-repro.log \
    || fail "auto-repro hung task line"
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" logs/serial-7.3-manual-repro.log \
    || fail "manual run 1 hung task line"
grep -q "INFO: task syz.0.33.*blocked for more than 143 seconds" logs/serial-verify3.log \
    || fail "manual replay B (verify3) hung task line"
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
# qemu argument templates retain the full device detail
grep -q "if=virtio,format=qcow2" cmdline/qemu-args-full-layout.txt \
    || fail "full-layout template: scratch drive format"
grep -q "size=1G" cmdline/qemu-args-full-layout.txt \
    || fail "full-layout template: pmem size"
grep -q "hung_task_panic=1" cmdline/qemu-args-full-layout.txt \
    || fail "full-layout template: campaign cmdline"
grep -q "hung_task_panic=0" cmdline/cmdline-7.3-retest.txt \
    || fail "retest cmdline: hung_task_panic=0"
# manifest must not contain itself
grep -q "MANIFEST.sha256" MANIFEST.sha256 && fail "MANIFEST contains itself"

# follow-up investigations (2026-11)
grep -q "INFO: task syz.0.26:10773 blocked for more than 143 seconds" \
    patch-ab-test-20261107/serial-7.3-patched.log \
    || fail "patched A/B hung task line"
grep -q "INFO: task syz.0.26:10732 blocked for more than 143 seconds" \
    patch-ab-test-20261107/serial-7.3-unpatched-ctrl.txt \
    || fail "unpatched control A/B hung task line"
grep -q "INFO: task syz.0.26:10737 blocked for more than 143 seconds" \
    patch-ab-test-20261107/serial-7.4-rc1.log \
    || fail "v7.4-rc1 hung task line"
grep -q "llc-sibling CPU #0 is not on the same node" \
    tcg-topology-20261109/serial-tcg-hit.log \
    || fail "TCG topology warning line"
grep -q "Kernel panic - not syncing: kernel: panic_on_warn set" \
    tcg-topology-20261109/serial-tcg-hit.log \
    || fail "TCG panic line"
grep -q "llc-sibling CPU #0 is not on the same node" \
    tcg-topology-20261109/serial-tcg-fixed-topology.log \
    && fail "TCG fixed-topology boot still warns"
# integrity of every tracked file (MANIFEST excludes itself and .git/)
sha256sum -c MANIFEST.sha256 --quiet || fail "MANIFEST verification"
echo "all checks passed"

# minimal C reproducer evidence
grep -q "INFO: task vtpm-hang-minim:9364 blocked for more than 143 seconds" \
    minimal-c-repro/serial-minimal-c.log \
    || fail "minimal C hung task line"
grep -q "vtpm_proxy_fops_release+0xa8" \
    minimal-c-repro/serial-minimal-c.log \
    || fail "minimal C release stack line"
grep -q "all 4 server fds closed (total 0s)" \
    minimal-c-repro/explicit-close-log.txt \
    || fail "explicit-close no-block evidence"
grep -q "INFO: task vtpm-hang-minim:9397 blocked for more than 143 seconds" \
    minimal-c-repro/serial-N32-run2.log \
    || fail "N=32 run 1 hung task line"
grep -q "blocked for more than 286 seconds" \
    minimal-c-repro/serial-N32-run3.log \
    || fail "N=32 still-blocked-at-286s line"
grep -q "blocked for more than" \
    minimal-c-repro/serial-N32-run3.log \
    || fail "N=32 rerun hung task line"
