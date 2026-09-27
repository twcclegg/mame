# MAME for visionOS

Experimental visionOS port. It uses the `sdl3` OSD and presents MAME as a flat
window in the Shared Space. Background and the longer-term plan are in
[RESEARCH.md](RESEARCH.md).

**Status:** the build scripts and source changes were written on Linux. GENie
generates the visionOS projects correctly, and the touched OSD files
syntax-check with visionOS defines, but **nothing has been compiled against the
visionOS SDK yet**. Expect to fix compile and link errors on the first Mac build.

Target hardware: Apple Vision Pro (M2). There's no JIT on visionOS, so the build
always uses the C DRC backend (`NOASM=1`).

## Prerequisites

- A Mac with Xcode and the visionOS SDK and simulator installed (`xcrun --sdk xros --show-sdk-path` should print a path).
- Python 3 (MAME's build needs it).
- **SDL3.xcframework with visionOS slices.** The default location is `/Library/Frameworks/SDL3.xcframework`; override it with `SDL_XCFRAMEWORK_PATH=...`. It needs `xros-arm64` and `xros-arm64*-simulator` directories. If the release framework lacks them, build it yourself:

  ```sh
  git clone --depth 1 --branch release-3.2.x https://github.com/libsdl-org/SDL.git
  cd SDL
  xcodebuild archive -project Xcode/SDL/SDL.xcodeproj -scheme SDL3 \
      -destination "generic/platform=visionOS" \
      -archivePath build/SDL3-xros SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  xcodebuild archive -project Xcode/SDL/SDL.xcodeproj -scheme SDL3 \
      -destination "generic/platform=visionOS Simulator" \
      -archivePath build/SDL3-xrsimulator SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  xcodebuild -create-xcframework \
      -framework build/SDL3-xros.xcarchive/Products/Library/Frameworks/SDL3.framework \
      -framework build/SDL3-xrsimulator.xcarchive/Products/Library/Frameworks/SDL3.framework \
      -output build/SDL3.xcframework
  ```
  The scheme name and archive paths are untested. Check them against the SDL checkout.

## Build

Start with a tiny driver set. A full MAME build takes a long time to link.

```sh
# simulator
make visionos-sim SUBTARGET=tiny SDL_XCFRAMEWORK_PATH=$PWD/../SDL/build/SDL3.xcframework -j$(sysctl -n hw.ncpu)
visionos/bundle.sh sim --sdl ../SDL/build/SDL3.xcframework

# device (needs a development identity and a provisioning profile for the bundle id)
make visionos SUBTARGET=tiny SDL_XCFRAMEWORK_PATH=... -j$(sysctl -n hw.ncpu)
visionos/bundle.sh device --sdl ... --bundle-id <your.bundle.id> \
    --identity "Apple Development: ..." --profile path/to/profile.mobileprovision
```

- `SUBTARGET=tiny` builds the drivers listed in `scripts/target/mame/tiny.lua`. For one specific driver, use `SOURCES=src/mame/pacman/pacman.cpp` instead.
- The binary goes to `build/visionos[-sim]-clang/bin/`, and `bundle.sh` produces `build/visionos/MAME-{sim,device}.app`. It prints the `simctl` / `devicectl` commands to install and launch the app.
- `VISIONOS_MIN_VERSION` (default `2.0`) sets the deployment target.

## Running

- Command-line arguments pass through `simctl launch` / `devicectl ... launch`, for example `... launch booted <bundle id> pacman`.
- Writable data lives in the app's **Documents** folder, which the Files app and Finder file sharing can see: `roms/`, `cfg/`, `nvram/`, `ini/` and so on. MAME's working directory is Documents.
- Read-only support files are loaded from the app bundle: `bgfx/`, `plugins/`, `hash/`, `artwork/`, `ctrlr/`, `language/` and the default `ini/mame.ini` (from `visionos/ini/`). A `mame.ini` in Documents overrides the bundled one.
- The default video is `accel` (SDL_Renderer on Metal). To try bgfx, add `-video bgfx` and optionally `-bgfx_screen_chains crt-geom` or `xbr`.
- Game controllers work through SDL's gamepad support. MAME already maps its UI to the gamepad: A selects, B goes back, and Guide opens the menu. Guide may be reserved by the system, which needs checking.

## What changed for the port

| Area | Files |
|---|---|
| Toolchains `visionos-clang` / `visionos-sim-clang` | `scripts/toolchain.lua` |
| `targetos=visionos`, make targets | `scripts/genie.lua`, `makefile` |
| SDL3 framework and UIKit link, defines (`SDLMAME_VISIONOS`, `SDLMAME_DARWIN`) | `scripts/src/osd/sdl3.lua`, `sdl3_cfg.lua` |
| Defaults: no OpenGL, MIDI or Qt; bgfx Metal only; expat and FLAC Darwin settings | `scripts/src/osd/modules.lua`, `scripts/src/3rdparty.lua` |
| Output directory for the binary | `scripts/src/main.lua` |
| bx detects visionOS (`BX_PLATFORM_VISIONOS`, rides the iOS paths) | `3rdparty/bx/include/bx/platform.h` |
| bgfx Metal: no `supportsFeatureSet` on visionOS | `3rdparty/bgfx/src/renderer_mtl.{h,mm}` |
| bgfx gets a `CAMetalLayer` from an SDL Metal view | `src/osd/modules/render/drawbgfx.cpp` |
| Sandbox paths (Documents plus bundle) | `src/osd/sdl3/sdlopts.cpp` |
| No fontconfig, no text-input keyboard, no pty, `mmap` fd | `sdlmain.cpp`, `window.cpp`, `font_sdl3.cpp`, `posixptty.cpp`, `osdlib_unix.cpp`, `osdsync.cpp` |
| App bundle and signing | `visionos/bundle.sh`, `visionos/Info.plist.in`, `visionos/ini/mame.ini` |

## Things to verify on the first build
1. **SDL's UIKit backend and scenes.** visionOS may require a scene manifest (`UIApplicationSceneManifest`). If the app launches to nothing, compare against SDL's `Xcode/SDLTest` Info.plist for visionOS.
2. **Main loop.** MAME's blocking loop under SDL's `UIApplicationMain` wrapper (SDL pumps the run loop in `SDL_PumpEvents`).
3. **bgfx on Metal.** Whether `SDL_Metal_CreateView` works without `SDL_WINDOW_METAL`, and whether bgfx's iOS Metal path compiles for xros.
4. **Deprecation or availability errors** in bgfx and bx under the xros SDK. The bgfx project builds with `-Werror`, so availability warnings may break it.
5. **No JIT.** `drc_cache` should log "Using W^X mode" and never actually execute from the cache with `drcbe_c`.
6. **Audio.** The SDL3 audio backend (AVAudioSession), and whether it needs an audio session category set.
