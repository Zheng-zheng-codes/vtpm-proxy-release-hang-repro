#!/usr/bin/env bash
# ============================================================================
# vtpm-hang-trigger-patched.sh — 跑【带补丁】内核的 vTPM hang 触发脚本
#
# 内核: 7.3.0-kernsight-kasan #3 (已应用 Stefan Berger 的补丁
#       "tpm: tpm_vtpm_proxy: Set STATE_OPENED_FLAG before inode is created")
# 参考: A/B 测试结论 —— 补丁内核同样触发 hang (1/1, t=414s), 补丁不修复本现象
#
# 其余参数/行为与 vtpm-hang-trigger.sh 完全一致, 直接透传:
#   bash vtpm-hang-trigger-patched.sh        # 容器模式, 保留 VM
#   bash vtpm-hang-trigger-patched.sh -k     # 结束后自动关 VM
#   MODE=native KIMG=... GIMG=... KEY=... SYZDIR=... PROG=... bash ...
#   PORT=12750 PANIC=1 MONITOR_MIN=20 bash ...
# (native 模式下 KIMG 请指向你自己的补丁内核)
# ============================================================================
DIR=$(cd "$(dirname "$0")" && pwd)
export KERNEL=${KERNEL:-/workspace/vtpm-patched-test/bzImage-patched-7.3}
exec bash "$DIR/vtpm-hang-trigger.sh" "$@"
