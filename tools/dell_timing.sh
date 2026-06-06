#!/usr/bin/env bash
# =============================================================================
# dell_timing.sh -- run tools/timing_triage.tcl against the latest FITTED design
# on the `dell` build box and print which paths fail timing + whether they are in
# the CDR (atapi / EXP1 / system573 / cd_top) path.
#
# This does NOT re-fit -- it reads the existing output_files/db netlist via
# quartus_sta (seconds, not the ~40 min full build). Run it after a build to
# confirm/deny that a timing violation lands in CDR-relevant logic.
#
# Findings on build 9bccb89 (2026-06-03): the core-clock violations are NOT in
# the CDR path -- general[0] setup is gpu_poly->spu (clk_2x->clk_1x ADPCM), and
# general[2] hold is dma->DMAfifoOut / memorymux->sdram (clk_1x->clk_3x). The
# atapi/EXP1/system573/cd_top logic all closes with +5..+16 ns of slack. So a
# timing violation is NOT the CD drive-check failure cause. See the commit that
# added this script for the full path dump + reasoning.
#
# Usage:  tools/dell_timing.sh
# =============================================================================
set -euo pipefail
REPO='~/System573_MiSTer'
IMG='raetro/quartus:17.0'

# shellcheck disable=SC2029  # we intentionally expand REPO/IMG locally
ssh dell "cd $REPO && \
  git pull --ff-only >/dev/null 2>&1 || true; \
  docker run --rm -v \"\$PWD\":/work -w /work --entrypoint quartus_sta \
    $IMG -t tools/timing_triage.tcl 2>&1 | grep -E '^(NEG|CDR|====)'"
