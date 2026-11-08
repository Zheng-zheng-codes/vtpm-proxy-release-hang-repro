#!/usr/bin/env bash
# ============================================================================
# vtpm-hang-trigger-patched.sh — trigger script for the PATCHED kernel
#
# Same as vtpm-hang-trigger.sh, but the KIMG default points at the patched
# build: 7.3.0-kernsight-kasan #3 (Stefan Berger's patch
# "tpm: tpm_vtpm_proxy: Set STATE_OPENED_FLAG before inode is created",
# kept in ../patch-ab-test-20261107/). A/B result: the hang still
# reproduces on the patched kernel (1/1 run, t=414s / t=453s) — the patch
# does not change the outcome.
#
# !!! PATHS YOU MUST REVIEW / EDIT — same as the main script !!!
# The KIMG default below is the ORIGINAL TEST HOST's container-visible
# path (/workspace/... = host dir /data/zhengzheng/kernsight). On any
# other machine override it, e.g.:
#   MODE=container KIMG=/workspace/your/bzImage bash vtpm-hang-trigger-patched.sh
#   MODE=native    KIMG=$PWD/arch/x86/boot/bzImage GIMG=... KEY=... \
#                  SYZDIR=... bash vtpm-hang-trigger-patched.sh
# All other options/behavior are identical to vtpm-hang-trigger.sh and are
# passed through (-k, PORT=, PANIC=1, MONITOR_MIN=, MODE=...).
# ============================================================================
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export KIMG=${KIMG:-/workspace/vtpm-patched-test/bzImage-patched-7.3}  # <- EDIT on other machines
exec bash "$DIR/vtpm-hang-trigger.sh" "$@"
