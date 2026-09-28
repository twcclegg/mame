# MAME for visionOS

Experimental visionOS port. It uses the `sdl3` OSD and presents MAME as a flat
window in the Shared Space. Background and the longer-term plan are in
[RESEARCH.md](RESEARCH.md).

**Status (2026-09-27): it plays a real game.** Arkanoid (World v1.0, fully
byte-verified romset) boots and runs in the visionOS 26.5 Simulator — title
screen, actual Level 1 gameplay, YM2149 sound, all rendering correctly as a
Metal-backed window in the Shared Space. Getting from "compiles" to "plays"
took two runtime fixes beyond the original build-only milestone:

1. **Use SDL ≥ 3.4.0, not `release-3.2.x`.** The 3.2.x branch has zero UIScene
   support in its UIKit backend. visionOS *requires* scene-lifecycle adoption
   and fatally traps apps that skip it (`EXC_BREAKPOINT` in
   `UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`, immediately
   on launch — see crash detail below). SDL added a proper
   `SDLUIKitSceneDelegate` at some point after 3.2.x; `release-3.4.16` (what
   Homebrew currently ships) has it and needs no further patching for this.
2. **`drawsdl3accel.cpp` claims `FLAG_SDL_NEEDS_OPENGL` it doesn't need**,
   which made `-video accel` (the default) fail window creation outright on
   any platform with no OpenGL at all. Fixed in this repo; see "What changed"
   below. This is a real, platform-agnostic MAME bug the visionOS port just
   happened to be the first to hit hard.

Also new: `visionos/ini/mame.ini` now defaults spinner/paddle/trackball
controls (`IPT_DIAL`/`IPT_PADDLE`/`IPT_TRACKBALL` — Arkanoid's paddle is a
dial) to the gaze pointer, since visionOS exposes gaze+pinch to windowed apps
as ordinary mouse motion. Not yet confirmed hands-on — this build machine has
no way to synthesize pointer input to test it programmatically.

Still open: device (hardware) launch is untested, `-video bgfx` specifically
hasn't been run on visionOS (though the underlying code path works, see
below), and gaze-as-paddle-input needs a person to actually try it — see
"Things confirmed vs. still open" below.

Target hardware: Apple Vision Pro (M2). There's no JIT on visionOS, so the build
always uses the C DRC backend (`NOASM=1`).

## Prerequisites

- A Mac with Xcode and the visionOS SDK and simulator installed (`xcrun --sdk xros --show-sdk-path` should print a path).
- Python 3 (MAME's build needs it).
- **SDL3.xcframework with visionOS slices, built from SDL ≥ 3.4.0.** Do not
  use `release-3.2.x` — it has no UIScene support and the app will crash
  instantly on launch (see Status above). The default xcframework location is
  `/Library/Frameworks/SDL3.xcframework`; override it with
  `SDL_XCFRAMEWORK_PATH=...`. It needs `xros-arm64` and `xros-arm64*-simulator`
  directories (add a `macos-arm64_x86_64` one too if you also want to run the
  same OSD natively on macOS for testing, as `Info.plist` there does not
  affect the visionOS slices). Confirmed against `release-3.4.16`:

  ```sh
  git clone --depth 1 --branch release-3.4.16 https://github.com/libsdl-org/SDL.git
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
  No local SDL patching needed at this version: the `SDL_CAMERA_DRIVER_COREMEDIA`
  build-config bug that affected `release-3.2.x` (it unconditionally enabled
  SDL's camera backend on visionOS even though its APIs are marked
  `unavailable(visionos)`) is already fixed upstream by 3.4.16.

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
- Game controllers work through SDL's gamepad support. MAME already maps its UI to the gamepad: A selects and B goes back. visionOS reserves the Guide/Home/PS button that MAME uses for the menu, so `visionos/ctrlr/visionos.cfg` (enabled by the bundled `mame.ini`) also opens the menu with **Select + Start**.

## Path B: libmame (`OSD=ios`) and the MAMEVision host app

A second, independent route: MAME built as a static library with the `ios` OSD
from [ToddLa/mame](https://github.com/ToddLa/mame) (the MAME side of MAME4iOS),
driven by a native SwiftUI app through the C callback API in
`src/osd/ios/libmame.h`. This is the planned base for spatial display (see
RESEARCH.md §1a). Nothing here has been compiled on a Mac yet.

```sh
# 1. libmame for device + simulator -> build/libmame/libmame.xcframework
visionos/make-libmame.sh all SUBTARGET=tiny        # or: sim SOURCES=src/mame/pacman/pacman.cpp

# 2. host app (needs XcodeGen: brew install xcodegen)
cd visionos/app && xcodegen && open MAMEVision.xcodeproj
#    run on the visionOS simulator; launch arguments go to MAME, e.g. "pacman"
```

- `make visionos-libmame` / `make visionos-sim-libmame` build the libraries. `make-libmame.sh` uses its own `BUILDDIR` (`build/libmame`), merges all the archives with `libtool` and packages them with `libmame.h` and a module map, so Swift can `import libmame`.
- The `ios` OSD was imported from ToddLa/mame at `fc040128` (MAME 0.288) and adapted to 0.289: `screen_type()` became `device_video_output_interface::is_vector()` / `screen_device::is_lcd()`, and `input.cpp` now includes `input.h`. bgfx isn't built for it.
- **New optional callback** `video_draw_pixels(const myosd_video_frame*)` in `libmame.h` (appended to the struct, so existing hosts are unaffected). MAME rasterizes the frame with its own software renderer (`rendersw.hxx`, the `-video soft` code) at the machine's **native resolution × an integer scale**, with non-square pixels where the game uses them. It reports the native size and the intended display aspect alongside the pixels. The host doesn't need a primitive renderer, and its scanline/mask shaders line up with real game pixels. The primitive-list `video_draw` path is unchanged, and it's the one to use for layered artwork later.
- Also fixed: an out-of-bounds write in `video.cpp` when the primitive list is empty; `libmame.h` wasn't self-contained (missing `<stddef.h>`); clipboard support is enabled on visionOS in `paste.mm`.
- Host app (`visionos/app/Sources`):
  - **Main window** (`ContentView`): lists ROM sets in Documents/roms (or opens MAME's own menu); while a game runs, shows it with an ornament for the **effect** and **Theater**. Launch arguments (e.g. `pacman`) skip the picker.
  - **Effects** (`Shaders.metal`, shared by both views): *Pixels* (nearest), *Sharp* (sharp-bilinear), *CRT* (sharp base, gaussian scanlines per native line, aperture mask at ≥3× scale).
  - **Theater** (`TheaterView`): an `ImmersiveSpace` (mixed or full) with a 4.5 m screen 5 m away. Each RealityKit update, a compute pass writes the newest frame with the chosen effect into a `LowLevelTexture` at an integer multiple of native resolution (capped at 2048 px, about the headset's resolution for that screen) and shown through an `UnlitMaterial`.
  - `MAMEEngine`: runs `myosd_main` on a 16 MB-stack thread, with Documents as the working directory; can relaunch after a game exits.
  - `FrameView`: MTKView presenter with a 4-texture ring, aspect-fit by the game's intended aspect.
  - `GameControllerInput`: GCExtendedGamepad to `myosd_input_state`. Select+Start opens the menu, Select+L1 exits (ESC) and Select+R1 pauses.
  - Sound uses libmame's built-in AudioQueue output.
  - **Lifecycle:** emulation pauses, and NVRAM is flushed, once every MAMEVision scene is in the background (window closed, headset off). It resumes when the app comes back. A pause you made in MAME itself is left alone.
  - Theater mode frames just the game screen (`MYOSD_ZOOM_TO_SCREEN`), cropping bezel artwork.
- **For per-game renderers** (see RESEARCH.md §7a):
  - `MAMEEngine.wantsGeometry` turns on libmame's `geometry_frame` callback. `GeometryStore` then holds each frame's camera-space 3D polygons, for drivers that export them (Sega Model 1 so far, via `src/emu/geomexport.h`).
  - `setSuppressNative3D(true)` leaves only the game's 2D layers in the video frame, so host-rendered 3D can be composited under the HUD.
- **Status (2026-09-28): it builds and runs.** `visionos/make-libmame.sh sim` produces `libmame.xcframework` cleanly, `xcodegen && xcodebuild` builds the SwiftUI host, and on the visionOS 26.5 Simulator it launches, its `ContentView` ROM picker correctly lists ROMs found in Documents/roms, and `arkanoid -skip_gameinfo` boots all the way to the real title screen (rendered through `video_draw_pixels` → the Metal compute shader → `LowLevelTexture`/`UnlitMaterial`), with the Pixels/Sharp/CRT effect picker and Theater toggle visible in the ornament. One real bug found and fixed:
  - **`ScreenUpdater` (`TheaterView.swift`) needed `@MainActor`.** RealityKit's `LowLevelTexture.replace(using:)` and `.init(descriptor:)` are `@MainActor`-isolated; `ScreenUpdater` wasn't, so Swift's actor-isolation checker rejected the calls at compile time. Marking the class `@MainActor` was sufficient — its only callers (`RealityView`'s content closure and its scene-update subscription) already run on the main actor, and `FrameStore` is separately `@unchecked Sendable`, so this doesn't introduce any cross-thread issue.
  - **Not a bug, but a gotcha:** a Debug-configuration build uses Xcode's "debug dylib" stub-executor launch mechanism (a tiny stub binary that `dlopen`s the real code from a companion `.debug.dylib`), which needs Xcode's own launch environment to find that dylib. Launching a Debug build directly via bare `xcrun simctl launch` (no Xcode attached) fails with `SIGABRT` in `abort_failed_to_open___debug_dylib`/`getDebugDylibHandle` — looks like an app crash but isn't one. Build `-configuration Release` (or pass `ENABLE_DEBUG_DYLIB=NO`) to launch outside Xcode.
  - Also: `xcodebuild -destination "generic/platform=visionOS Simulator"` fails to link (`missing architecture(s) ... x86_64`) since `libmame.xcframework` is arm64-only (this machine is Apple Silicon and the Simulator runtime doesn't need an x86_64 slice). Target a concrete device instead: `-destination "platform=visionOS Simulator,id=<udid>"`.
  - **Theater mode: now confirmed working end-to-end, after fixing a real bug.** Reaching it needs a tap on the "Theater" ornament button, and this build machine can't synthesize touch/pointer input, so it was driven instead via a test-only env var (`MAMEVISION_AUTO_THEATER=1`, gated off by default, see `ContentView.swift`) passed through `simctl launch` as `SIMCTL_CHILD_MAMEVISION_AUTO_THEATER=1`. First attempt failed outright: `project.yml` set `UIApplicationSupportsMultipleScenes: false`, but Theater mode's whole design is a *second* concurrent scene (an `ImmersiveSpace` alongside the main window) — visionOS logged "Unable to open an immersive space when the app does not support multiple scenes" and silently no-opped. Flipped to `true`; after that, `openImmersiveSpace` succeeds and the button correctly flips to "Exit Theater". The system log then shows **two** distinct plane meshes loading: the 4.5×3.375 m 4:3 placeholder from `init()`, then a second 2.53125×3.375 m one at aspect 0.75 — Arkanoid's actual vertical-monitor aspect ratio (MAME's own info screen reports its video as "(V)" for vertical) — meaning `ensureOutput()` ran against a real game frame, not just the placeholder, and rebuilt the screen mesh to the correct aspect. Zero faults in the log throughout.
  - Still unverified: colours in theater mode — RealityKit may treat the `bgra8Unorm` texture as linear; if it looks washed out or too dark, try `bgra8Unorm_srgb`.

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
| Lua's `os.execute()`: no `system()` on visionOS, same as iOS | `scripts/src/3rdparty.lua` (`LUA_USE_IOS` instead of `LUA_USE_POSIX`; `luaconf.h` already defines the latter when the former is set, so defining both fails with a macro-redefined error) |
| sqlite3's `gethostuuid()` probe emits `#warning` on embedded Apple targets, which `-Werror` turns fatal | `scripts/src/3rdparty.lua` (`HAVE_GETHOSTUUID=0`) |
| `drawsdl3accel` (the default `-video accel`) claimed `FLAG_SDL_NEEDS_OPENGL`, forcing an OpenGL-flagged window it never actually needs (`SDL_CreateRenderer` is called with a null/auto driver name, so it gets Metal); fatal on any platform with no OpenGL at all | `src/osd/modules/render/drawsdl3accel.cpp` — not visionOS-specific, a real bug on any such platform |

## Things confirmed vs. still open

Confirmed, via `xcrun simctl launch --console-pty` + `xcrun simctl io screenshot`
on the visionOS 26.5 Simulator (`Apple Vision Pro` device), no `Simulator.app`
GUI needed:
- App launches, no crash, no `-video accel` window-creation failure.
- `-video accel` selects Metal (`SDL renderer using driver metal` in the log)
  and actually shows MAME's system-select UI as a floating window in the
  Shared Space.
- CoreAudio, keyboard, mouse, lightgun all initialize.
- SDL3's GameController backend detects and maps a virtual gamepad
  (`platform:visionOS` in the mapping string) with no extra work.
- `MAME_NOASM=1` (the forced C DRC backend) is active, per the verbose log.
- **Real gameplay**: Arkanoid (World v1.0) — a fully byte-verified romset
  (`-verifyroms` passes clean) — boots past its hardware self-test, shows the
  Taito title screen, and renders actual Level 1 gameplay (brick layout,
  paddle, ball) via `-autoboot_script` inserting a coin and starting a game
  through MAME's Lua console. YM2149 sound initializes without error.
- **bgfx on Metal**, i.e. `-video bgfx` specifically, on a second Simulator
  device: initializes on Metal, the UIKit `CAMetalLayer` path in
  `drawbgfx.cpp` works, and `arkanoid -video bgfx -bgfx_screen_chains
  crt-geom` renders full gameplay with the crt-geom shadow-mask/glow chain
  visibly applied. Clean exit via Lua `manager.machine:exit()`, 100% speed,
  no crash.

Still open:
1. **A bgfx/Metal shutdown crash on the *early-fatal* path only** (e.g. a
   missing-ROM abort before the machine starts): `SIGABRT` in
   `renderer_bgfx::~renderer_bgfx → video_bgfx::last_renderer_destroyed →
   bgfx::shutdown → Context::shutdown/frame/swap/renderFrame → autorelease
   pool drain → -[MTLSerializerBlitCommandEncoder dealloc] →
   MTLReportFailure("Command encoder released without endEncoding")`. Looks
   like a blit encoder opened for a texture upload (`getBlitCommandEncoder`,
   `renderer_mtl.mm` ~2451/3575) is still open when bgfx's shutdown frame's
   autorelease pool drains. Doesn't affect normal gameplay or a normal exit,
   only this early-abort path (MAME exiting before the machine starts) —
   low priority, but worth fixing since a bad ROM shouldn't crash the whole
   app. **Confirmed not visionOS-specific**: reproduces with current
   upstream bgfx on native macOS under `MTL_DEBUG_LAYER=1` — if a
   texture/buffer update is still pending when `bgfx::shutdown()` runs,
   `RendererShutdownBegin` skips the submit, and the `renderFrame`
   autorelease pool then frees the still-open blit encoder. A fix exists as
   a draft upstream bgfx PR; MAME vendors bgfx API 118, much older than
   upstream, so pulling the fix in would be a separate backport.
2. **No JIT in a driver that actually uses DRC.** Arkanoid's Z80 doesn't use
   MAME's recompiler at all, so `MAME_NOASM=1` being *set* is confirmed, but
   `drc_cache` actually logging "Using W^X mode" and never executing from the
   cache needs a DRC-using driver (MIPS3, PowerPC, SH2/4, ARM7, etc.) plus its
   ROM.
3. **Gaze-as-paddle-input.** `visionos/ini/mame.ini` now defaults
   `dial_device`/`paddle_device`/`trackball_device` to `mouse`, and it boots
   cleanly with no errors, but nothing on this build machine can synthesize
   pointer/touch input to confirm gaze motion actually reaches the paddle —
   `simctl` has no touch/pointer injection, and Accessibility automation to
   move a real pointer times out. Needs a person physically trying it.
4. **Device (hardware) launch.** Only the Simulator has been tried. Needs a
   dev-team identity + provisioning profile for `bundle.sh device`.
5. **visionOS 27.0 runtime instability on this machine.** A freshly-booted
   `Apple Vision Pro` device on the `visionOS 27.0` runtime failed after one
   launch attempt (`liblaunch_sim.dylib could not be opened`, `Malformed
   bundle does not contain an identifier` on the runtime's own `.simruntime`
   bundle) and needed a fallback to a `visionOS 26.5` device to make any
   further progress. Unclear whether that's a bad runtime install or a
   genuine bug; worth another look with a clean runtime install.
