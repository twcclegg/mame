#!/bin/bash
# license:BSD-3-Clause
#
# End-to-end plumbing test: real MAME + ark3d_capture.lua + ark3d_dump, with
# placeholder ROM files (no real ROM needed or used).
#
#   make -C visionos/dioramas/arkanoid/Tests synth dump
#   visionos/dioramas/arkanoid/Tests/run_e2e.sh [path/to/mame]
#
# MAME must include the arkanoid driver, e.g. a Linux build made with
#   make SOURCES=src/mame/taito/arkanoid.cpp
#
# Checks that the capture script finds the shares, regions and save items the
# app uses, that the capture format round-trips, and that the decoder sees the
# injected synthetic scene through MAME's memory.  It does NOT check the
# decoder against Arkanoid's real graphics: the program ROMs are zeros, so the
# game never runs.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MAME="${1:-$HERE/../../../../mame}"
OUT="${OUT:-$HERE/build}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$OUT/ark3d_synth" "$WORK"
(cd "$WORK" && ARK3D_OUT="$WORK/cap.bin" ARK3D_INJECT="$WORK/inject.bin" ARK3D_LOG=0 \
	"$MAME" arkanoid -rompath "$WORK" -video none -sound none -nothrottle -seconds_to_run 2 \
	-skip_gameinfo -autoboot_script "$HERE/../lua/ark3d_capture.lua" > "$WORK/mame.log" 2>&1) || {
	cat "$WORK/mame.log"; echo "FAIL: MAME run"; exit 1; }

"$OUT/ark3d_dump" "$WORK/cap.bin" > "$WORK/summary.txt"
frames=$(wc -l < "$WORK/summary.txt")
last=$(tail -1 "$WORK/summary.txt")
echo "$frames frames captured; last: $last"

fail=0
expect() { grep -qF -- "$1" <<<"$last" || { echo "FAIL: expected '$1'"; fail=1; }; }
[ "$frames" -ge 60 ] || { echo "FAIL: only $frames frames"; fail=1; }
expect "bricks   3"
expect "vaus  112.0 w 32.0"
expect "balls 1 (108,154)"
expect "capsuleS"
expect "enemy"
expect "laser"

"$OUT/ark3d_dump" "$WORK/cap.bin" -f 60 > "$WORK/detail.txt"
grep -q "^   0 #\.\.\.\.\.\.\.\.\.\.\.\. " "$WORK/detail.txt" || { echo "FAIL: brick (0,0)"; fail=1; }
grep -q "^  10 \.\.\.\.\.#\.\.\.\.\.\.\. " "$WORK/detail.txt" || { echo "FAIL: brick (5,10)"; fail=1; }
grep -q "^  11 \.\.\.\.\.\.\.\.\.\.\.\.\. " "$WORK/detail.txt" || { echo "FAIL: dark cell (7,11) taken for a brick"; fail=1; }

[ $fail -eq 0 ] && echo "PASS" || exit 1
