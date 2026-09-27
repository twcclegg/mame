#!/bin/bash
# license:BSD-3-Clause
#
# Wrap a visionOS MAME binary (from `make visionos` / `make visionos-sim`)
# into a signed .app bundle.
#
#   visionos/bundle.sh sim                          # ad-hoc signed, for the simulator
#   visionos/bundle.sh device --identity "Apple Development: ..." \
#                             --profile path/to/profile.mobileprovision
#
# Options:
#   --binary PATH      MAME binary (default: first executable in build/<toolchain>/bin)
#   --bundle-id ID     CFBundleIdentifier (default: $MAME_BUNDLE_ID or org.mamedev.mame.visionos);
#                      must match the provisioning profile for device builds
#   --identity NAME    codesigning identity (device builds; see `security find-identity -p codesigning`)
#   --profile PATH     provisioning profile (device builds)
#   --sdl PATH         SDL3.xcframework (default: $SDL_XCFRAMEWORK_PATH or /Library/Frameworks/SDL3.xcframework)
#   --min-os VERSION   MinimumOSVersion (default: $VISIONOS_MIN_VERSION or 2.0)
#   --no-hash          don't bundle hash/ (software lists; ~100 MB)
#   --out DIR          output directory (default: build/visionos)

set -euo pipefail

MAME_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MAME_DIR"

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: $0 sim|device [options]"
KIND="$1"; shift
case "$KIND" in
	sim)    TOOLCHAIN=visionos-sim-clang; PLATFORM=XRSimulator; DT_PLATFORM=xrsimulator ;;
	device) TOOLCHAIN=visionos-clang;     PLATFORM=XROS;        DT_PLATFORM=xros ;;
	*)      die "first argument must be 'sim' or 'device'" ;;
esac

BINARY=""
BUNDLE_ID="${MAME_BUNDLE_ID:-org.mamedev.mame.visionos}"
IDENTITY=""
PROFILE=""
SDL_XCFRAMEWORK="${SDL_XCFRAMEWORK_PATH:-/Library/Frameworks/SDL3.xcframework}"
MIN_OS="${VISIONOS_MIN_VERSION:-2.0}"
WITH_HASH=1
OUT_DIR="build/visionos"

while [ $# -gt 0 ]; do
	case "$1" in
		--binary)    BINARY="$2"; shift 2 ;;
		--bundle-id) BUNDLE_ID="$2"; shift 2 ;;
		--identity)  IDENTITY="$2"; shift 2 ;;
		--profile)   PROFILE="$2"; shift 2 ;;
		--sdl)       SDL_XCFRAMEWORK="$2"; shift 2 ;;
		--min-os)    MIN_OS="$2"; shift 2 ;;
		--no-hash)   WITH_HASH=0; shift ;;
		--out)       OUT_DIR="$2"; shift 2 ;;
		*)           die "unknown option $1" ;;
	esac
done

# --- locate inputs ----------------------------------------------------------

if [ -z "$BINARY" ]; then
	for f in "build/$TOOLCHAIN/bin"/*; do
		if [ -f "$f" ] && [ -x "$f" ]; then BINARY="$f"; break; fi
	done
fi
[ -n "$BINARY" ] && [ -f "$BINARY" ] || die "no MAME binary found in build/$TOOLCHAIN/bin (run make visionos / make visionos-sim first, or pass --binary)"
EXECUTABLE="$(basename "$BINARY")"

SDL_SLICE=""
for d in "$SDL_XCFRAMEWORK"/xros-*; do
	[ -d "$d/SDL3.framework" ] || continue
	case "$d" in
		*simulator*) if [ "$KIND" = sim ]; then SDL_SLICE="$d"; fi ;;
		*)           if [ "$KIND" = device ]; then SDL_SLICE="$d"; fi ;;
	esac
done
[ -n "$SDL_SLICE" ] || die "no visionOS $KIND slice in $SDL_XCFRAMEWORK"

if [ "$KIND" = device ]; then
	[ -n "$IDENTITY" ] || die "device builds need --identity"
	[ -n "$PROFILE" ] && [ -f "$PROFILE" ] || die "device builds need --profile"
fi

VERSION="$(sed -n 's/^#define BARE_BUILD_VERSION "\(.*\)"/\1/p' build/generated/version.cpp 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="0.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# --- assemble ---------------------------------------------------------------

APP="$OUT_DIR/MAME-$KIND.app"
echo "Bundling $BINARY -> $APP"
rm -rf "$APP"
mkdir -p "$APP/Frameworks"

cp "$BINARY" "$APP/$EXECUTABLE"
cp -R "$SDL_SLICE/SDL3.framework" "$APP/Frameworks/"

sed -e "s|@EXECUTABLE@|$EXECUTABLE|" \
    -e "s|@BUNDLE_ID@|$BUNDLE_ID|" \
    -e "s|@VERSION@|$VERSION|" \
    -e "s|@BUILD@|$BUILD|" \
    -e "s|@PLATFORM@|$PLATFORM|" \
    -e "s|@DT_PLATFORM@|$DT_PLATFORM|" \
    -e "s|@MIN_OS@|$MIN_OS|" \
    visionos/Info.plist.in > "$APP/Info.plist"
plutil -lint "$APP/Info.plist" >/dev/null
plutil -convert binary1 "$APP/Info.plist"

# Read-only support files.  sdlopts.cpp points MAME's search paths at the
# bundle for these, and at Documents for everything writable.
cp -R bgfx "$APP/bgfx"
cp -R plugins "$APP/plugins"
cp -R artwork "$APP/artwork"
cp -R ctrlr "$APP/ctrlr"
cp -R visionos/ini "$APP/ini"
if [ "$WITH_HASH" = 1 ]; then
	cp -R hash "$APP/hash"
fi
if compgen -G "language/*/strings.mo" >/dev/null; then
	mkdir -p "$APP/language"
	for mo in language/*/strings.mo; do
		mkdir -p "$APP/$(dirname "$mo")"
		cp "$mo" "$APP/$mo"
	done
fi

# --- sign -------------------------------------------------------------------

if [ "$KIND" = sim ]; then
	codesign --force --sign - --timestamp=none "$APP/Frameworks/SDL3.framework"
	codesign --force --sign - --timestamp=none "$APP"
else
	cp "$PROFILE" "$APP/embedded.mobileprovision"
	ENTITLEMENTS="$OUT_DIR/entitlements.plist"
	security cms -D -i "$PROFILE" > "$OUT_DIR/profile.plist"
	plutil -extract Entitlements xml1 -o "$ENTITLEMENTS" "$OUT_DIR/profile.plist"
	codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Frameworks/SDL3.framework"
	codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo
echo "Built $APP"
if [ "$KIND" = sim ]; then
	cat <<EOF
Run it in the simulator:
  xcrun simctl boot "Apple Vision Pro"   # if not already booted
  open -a Simulator
  xcrun simctl install booted "$APP"
  xcrun simctl launch --console-pty booted $BUNDLE_ID pacman
ROMs go in the app's Documents/roms:
  cp pacman.zip "\$(xcrun simctl get_app_container booted $BUNDLE_ID data)/Documents/roms/"
EOF
else
	cat <<EOF
Install and run it on the device:
  xcrun devicectl list devices
  xcrun devicectl device install app --device <id> "$APP"
  xcrun devicectl device process launch --console --device <id> $BUNDLE_ID pacman
ROMs go in the app's Documents/roms (Files app, or Finder file sharing).
EOF
fi
