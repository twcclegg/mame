#!/bin/bash
# license:BSD-3-Clause
#
# Build MAME as a static library for visionOS (OSD=ios, the libmame.h
# callback API from ToddLa/mame / MAME4iOS) and package it as
# build/libmame/libmame.xcframework for a native host app.
#
#   visionos/make-libmame.sh [sim|device|all] [extra make args...]
#
# e.g.
#   visionos/make-libmame.sh all SUBTARGET=tiny
#   visionos/make-libmame.sh sim SOURCES=src/mame/pacman/pacman.cpp
#
# Uses its own build directory (build/libmame) so it doesn't mix object
# files with the SDL3 visionOS build.

set -euo pipefail

MAME_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MAME_DIR"

WHAT="${1:-all}"
[ $# -gt 0 ] && shift
case "$WHAT" in
	sim)    KINDS="sim" ;;
	device) KINDS="device" ;;
	all)    KINDS="device sim" ;;
	*)      echo "usage: $0 [sim|device|all] [make args...]" >&2; exit 1 ;;
esac

BUILDDIR=build/libmame
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)"
XCF_ARGS=()

for kind in $KINDS; do
	if [ "$kind" = sim ]; then
		target=visionos-sim-libmame; toolchain=visionos-sim-clang
	else
		target=visionos-libmame;     toolchain=visionos-clang
	fi

	echo "=== building $target"
	make "$target" BUILDDIR="$BUILDDIR" -j"$JOBS" "$@"

	bindir="$BUILDDIR/$toolchain/bin"
	out="$BUILDDIR/$toolchain/libmame.a"

	# The main project archive (lib<target><subtarget>.a) sits directly in
	# bin/; every other project's archive is under bin/Release (drivers and
	# the OSD under bin/Release/<target>_<subtarget>).
	libs=()
	while IFS= read -r -d '' lib; do libs+=("$lib"); done < <(
		find "$bindir" -name '*.a' -print0)
	[ ${#libs[@]} -gt 0 ] || { echo "no archives found under $bindir" >&2; exit 1; }

	echo "=== combining ${#libs[@]} archives into $out"
	rm -f "$out"
	xcrun libtool -static -no_warning_for_no_symbols -o "$out" "${libs[@]}"

	XCF_ARGS+=(-library "$out" -headers "$BUILDDIR/headers")
done

# Public header for the host app, plus a module map so Swift can
# `import libmame` directly.
rm -rf "$BUILDDIR/headers"
mkdir -p "$BUILDDIR/headers"
cp src/osd/ios/libmame.h "$BUILDDIR/headers/"
cat > "$BUILDDIR/headers/module.modulemap" <<'EOF'
module libmame {
	header "libmame.h"
	export *
}
EOF

xcf="$BUILDDIR/libmame.xcframework"
rm -rf "$xcf"
xcodebuild -create-xcframework "${XCF_ARGS[@]}" -output "$xcf"
echo
echo "Built $xcf"
echo "Host app also needs: -lc++, and the UIKit, AudioToolbox and AVFoundation frameworks (plus whatever it uses itself, e.g. Metal, GameController)."
