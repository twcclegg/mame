# MAME on visionOS: initial research

Status: research only, nothing is built yet. Written from a Linux container, so
every claim about Xcode, SDKs or device behaviour is marked **[verify on Mac]**
where it hasn't been checked against a real toolchain.

> **Progress (2026-09-27):** first-light build support is now in the tree, and
> `make visionos` / `make visionos-sim` both compile and link cleanly on a
> real Mac (Xcode 27, visionOS SDK 27.0), and `bundle.sh sim` produces a valid,
> codesigned `MAME-sim.app`. See [README.md](README.md) for build steps, the
> two small fixes that were needed (Lua's `os.execute`, sqlite3's
> `gethostuuid` probe), a required upstream SDL3 patch, and the file list.
> **Still unverified: actually running it.** This build machine's
> CoreSimulator is out of date relative to Xcode 27, so the Simulator won't
> launch here — milestone 2 (Pac-Man on screen) needs a Mac where
> `xcrun simctl list devicetypes` doesn't hang. Hardware is confirmed as an
> **M2** Vision Pro.

Goals, in order:
1. **Run.** Build MAME for visionOS and show a game in a window in the Shared Space.
2. **Display.** Present the game properly: resizable window, then a spatial screen or cabinet.
3. **Input.** Game controllers first, then keyboard, hands and gaze.
4. **Upscaling.** Resolution upscaling through bgfx shader chains, then "3D upscaling" (see §7).

---

## 1. Summary

**Use the existing `sdl3` OSD** (the same one the Android port uses) with a new
`visionos` target OS. Build MAME as static libraries through GENie/make, then link
them into a small hand-written Xcode app project together with `SDL3.xcframework`.
This works like `android-project/`, where Gradle wraps `libmame`.

Most of what we need is already in the tree:

| Need | What's in tree | Gap |
|---|---|---|
| Windowing and events on UIKit | `src/osd/sdl3/`. SDL ≥ 3.2 supports visionOS (`SDL_PLATFORM_VISIONOS`) | Small `#ifdef`s only |
| Metal rendering | bgfx Metal backend (`3rdparty/bgfx/src/renderer_mtl.mm`); prebuilt Metal shaders in `bgfx/shaders/metal/` | The bundled bx/bgfx doesn't recognise visionOS (§3.3) |
| No JIT | `NOASM=1` / `FORCE_DRC_C_BACKEND` (Android already builds this way) | None. Performance cost only (§4) |
| Game controllers | SDL3 gamepad (backed by GCController on Apple platforms) | None to start with |
| Build toolchain | `scripts/toolchain.lua`, which has Android cross-compile recipes to copy | Add `visionos-arm64` and `visionos-simulator` |
| Upscaling shaders | `bgfx/chains/` already has xbr, hqx, eagle, crt-geom, lcd-grid and others | None for 2D. See §7 for 3D |

The **native `src/osd/mac` OSD** (~3,100 lines, Cocoa, bgfx, GameController, no SDL)
is the template for a later **native visionOS OSD**. We'd want that once we need
SwiftUI/RealityKit to own the app, which is phase 2 of display.

---

## 2. Build system: what exists and what to add

### 2.1 How MAME builds today
- `makefile` → GENie (`3rdparty/genie`) → generated gmake projects under `build/projects/<osd>/…`.
- Picking the target: `--gcc=<toolchain>`, `--targetos=<os>`, `--osd=<osd>`. Android example (`makefile:1230`):
  `--gcc=android-arm64 --osd=sdl3 --targetos=android --PLATFORM=arm64 --NOASM=1`.
- `scripts/genie.lua:456`: `NOASM=1` implies `FORCE_DRC_C_BACKEND=1`, which defines `NATIVE_DRC=drcbe_c`.
- `scripts/src/osd/sdl3.lua` and `sdl3_cfg.lua` hold the per-OS link and define logic. `targetos=macosx` links `SDL3.framework` from `SDL3.xcframework/macos-arm64_x86_64/` (`sdl3.lua:215-218`) and pulls in Cocoa, OpenGL and IOKit, **none of which exist on visionOS**.

### 2.2 Proposed changes
1. **`scripts/toolchain.lua`**: add `visionos-arm64` and `visionos-simulator` gcc options.
   - cc/cxx: `xcrun --sdk xros clang` / `xcrun --sdk xrsimulator clang` **[verify on Mac]**
   - flags: `-target arm64-apple-xros2.0` (device) / `-target arm64-apple-xros2.0-simulator`, `-isysroot $(xcrun --sdk xros --show-sdk-path)`.
   - `3rdparty/bx/scripts/toolchain.lua` has `ios-arm64` / `tvos-arm64` recipes to crib from.
2. **`makefile`**: `visionos-arm64` and `visionos-simulator` targets, modelled on `android-arm64`, passing
   `--osd=sdl3 --targetos=visionos --NOASM=1 NO_OPENGL=1 NO_X11=1 NO_USE_MIDI=1 USE_QTDEBUG=0 NO_USE_PORTAUDIO=1 USE_TAPTUN=0 USE_PCAP=0`.
3. **`scripts/genie.lua`**: map `targetos=visionos` to `BASE_TARGETOS=unix`, and make sure every `targetos=="macosx"` branch leaves visionos alone (grep for `macosx` in `scripts/`).
4. **`scripts/src/osd/sdl3.lua` / `sdl3_cfg.lua`**: add a `visionos` branch:
   - `-F <SDL3.xcframework>/xros-arm64` (or `xros-arm64_x86_64-simulator`) **[verify slice names]**
   - frameworks: UIKit, Foundation, Metal, QuartzCore, AVFoundation, AudioToolbox, CoreAudio, GameController, CoreHaptics, CoreMotion (SDL's iOS dependency list).
   - no fontconfig, no SDL3_ttf to begin with. Use `SDLOS_TARGETOS="unix"` so `osdlib_unix.cpp` is compiled. **Don't use `osdlib_macosx.cpp`**: it includes `<Carbon/Carbon.h>` for the clipboard.
   - exclude `coreaudio_sound.cpp`. It uses the macOS HAL (`AudioObject*`, `AudioDeviceID`). Use the `sdl3` sound module.
5. **Build output**: static libs (MAME already builds `libemu`, `liboptional`, `libmame_mame` and others) plus the OSD `main`. The Xcode app links them. First light should use a **small driver subset** (`SOURCES=src/mame/pacman/pacman.cpp,...` or a custom `SUBTARGET`); a full MAME build is several hundred MB and slow to link.

### 2.3 GENie's Xcode generator
The bundled GENie already knows about visionOS: `xcode15.lua` handles `XROS_DEPLOYMENT_TARGET`, and
`xcode_common.lua` handles `visionostargetplatformversion`. MAME doesn't use the Xcode actions, though,
and there's a bug at `3rdparty/genie/src/actions/xcode/xcode_common.lua:427`:
`opts.XROS_DEPLOYMENT_TARGET = tvosversion` should be `visionosversion`. **Recommendation:** stick with
make plus a small hand-maintained Xcode wrapper project, as Android does with Gradle.

---

## 3. Source changes needed for first light

### 3.1 `src/osd/sdl3/sdlprefix.h`
Add `#if defined(SDL_PLATFORM_VISIONOS)` → `#define SDLMAME_VISIONOS 1` (and maybe a broader
`SDLMAME_APPLE_EMBEDDED`). `SDLMAME_DARWIN` is already set from `SDL_PLATFORM_APPLE`.

### 3.2 `src/osd/sdl3/sdlmain.cpp`, `sdlopts.cpp`, `window.cpp`
- `sdlmain.cpp:97,110`: add `SDLMAME_VISIONOS` to the list of platforms that skip `FcInit()`/`FcFini()` (fontconfig).
- `sdlmain.cpp` includes `<SDL3/SDL_main.h>`, so SDL renames `main` → `SDL_main` and runs it under `UIApplicationMain`. MAME's blocking run loop is OK there: SDL on UIKit pumps the run loop inside `SDL_PumpEvents`, which is how most SDL iOS games work. **[verify on Mac]**
- `sdlopts.cpp:30`: `INI_PATH` / working directory. The app sandbox is read-only apart from its containers. Plan:
  - read-only assets (bgfx shaders and chains, `plugins/`, `hash/`, `language/`, `artwork/`, `ctrlr/`) go in the app bundle, found via `SDL_GetBasePath()`.
  - writable paths (`cfg`, `nvram`, `ini`, `snap`, `sta`, `diff`, `roms`) go under Documents, found via `SDL_GetPrefPath()` or the Documents URL.
  - Android does a `chdir()` hack in the `sdl_options` constructor (`sdlopts.cpp:109`). We'd do something similar, or set explicit path defaults.
  - Set `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in Info.plist so ROMs can be dropped in through the Files app or Finder.
- `window.cpp:947`: `SDL_StartTextInput()` is skipped on Android and should be skipped here too, or it may bring up the virtual keyboard. **[verify]**

### 3.3 bgfx / bx platform detection (**main blocker**)
The bundled bx (`3rdparty/bx/include/bx/platform.h:196-199`) sets `BX_PLATFORM_IOS` only from
`__ENVIRONMENT_IPHONE_OS…` / `__ENVIRONMENT_TV_OS…`. An `xros` target matches neither, so bx will
misdetect the platform (it probably won't compile).

Upstream has since fixed this. bx master has `BX_PLATFORM_VISIONOS` detected via
`__is_target_os(xros)`, and bgfx master (`BGFX_API_VERSION` 161, vs **118** in this tree) treats
`BX_PLATFORM_IOS || BX_PLATFORM_VISIONOS` alike across `renderer_mtl`. Options:
- **A (fast, recommended for first light):** local patch. Detect `__is_target_os(xros)` in bx and treat it as `BX_PLATFORM_IOS` (plus `BX_PLATFORM_VISIONOS` for the few places that matter). Check that bgfx's `glcontext_eagl.mm` is excluded or compiles, and set `BGFX_CONFIG_RENDERER_OPENGL*=0` so only Metal is built.
- **B (proper):** update 3rdparty bx/bimg/bgfx to upstream. That's a large version jump (118 → 161), and `drawbgfx.cpp` / `bgfxutil.cpp` would likely need API fixes. It's the right fix upstream, but not for first light.

### 3.4 `src/osd/modules/render/drawbgfx.cpp`
`set_platform_data()` (line ~392) and `sdlNativeWindowHandle()` (line ~560) have branches for Win32,
Cocoa, X11, Wayland and Android, but **no UIKit branch**. On UIKit, bgfx's Metal backend wants a
`CAMetalLayer*` as `nwh` (`renderer_mtl.mm:3246-3252`). Add:
```cpp
#if defined(SDL_PLATFORM_VISIONOS) || defined(SDL_PLATFORM_IOS)
	SDL_MetalView view = SDL_Metal_CreateView(sdlwindow);   // keep and destroy with the window
	platform_data.nwh = SDL_Metal_GetLayer(view);
#endif
```
The window needs to be created with `SDL_WINDOW_METAL`. `osdsdl.cpp:504` already handles
`SDL_EVENT_WINDOW_METAL_VIEW_RESIZED`. Also make `-bgfx_backend auto` resolve to Metal (it should
already).

**Simplest fallback for first light:** `-video accel` (`drawsdl3accel.cpp`) or `-video soft`
(`drawsdl3soft.cpp`) go through SDL_Renderer, which has a Metal backend. Those need no bgfx at all, so
we could get a picture on screen before tackling §3.3.

### 3.5 OpenGL
Build with `NO_OPENGL=1` and don't use `-video opengl`. `osd_opengl.h` pulls in `<OpenGL/gl.h>` under
Apple. OpenGL ES on visionOS is at best deprecated **[verify]**, and Metal is the only path worth taking.

### 3.6 Small portability fixes spotted
- `src/osd/modules/lib/osdlib_unix.cpp:317`: `mmap(... MAP_ANON, fd)` uses `fd=0` unless `SDLMAME_BSD`/`MACOSX`/`EMSCRIPTEN`. Darwin expects `-1` (or a VM tag), so add `SDLMAME_DARWIN`.
- `src/osd/modules/file/posixptty.cpp:25`: includes `<util.h>` / `openpty` for `__APPLE__`. That may be unavailable on xros. Stub it out if it fails to compile. **[verify]**
- `src/osd/modules/font/font_osx.cpp` includes `<ApplicationServices/ApplicationServices.h>` (macOS only). Porting it to `<CoreText/CoreText.h>` + `<CoreGraphics/CoreGraphics.h>` should be trivial. Until then use `-uifontprovider none`, which uses the built-in `uismall.bdf`.
- `osdobj_common.cpp:282`: `DEBUG_OSX` is registered under `SDLMAME_MACOSX`. That's fine because we won't define it for visionos. The Qt debugger is off, and the imgui debugger should work.
- Networking (taptun/pcap) and MIDI: off for now. CoreMIDI may exist on visionOS, which would enable portmidi later **[verify]**.

---

## 4. CPU emulation: no JIT

- visionOS, like iOS, gives third-party apps **no executable writable memory**: no `MAP_JIT` entitlement and no `mprotect(PROT_EXEC)` on data pages.
- `drc_cache::allocate_cache` (`src/devices/cpu/drccache.cpp:176`) asks for RWX and falls back to W^X by toggling permissions with `mprotect`. Both will fail on device, so we **must** build with `FORCE_DRC_C_BACKEND` (`NOASM=1` implies it). With the C backend, the cache is only read and written, never executed. **[verify it doesn't still request EXECUTE on the reservation]**: `allocate_cache` passes `READ_WRITE_EXECUTE` as the *intent* to `virtual_memory_allocation`, but on Unix the initial mapping is `PROT_NONE` (`osdlib_unix.cpp:301`), so this should be harmless.
- **Impact:** the DRC is only used by recompiling cores (MIPS3/4, PowerPC, SH2/SH4, the Hyperstone E1 family, ADSP-21062, TMS32031, ARM7 in some drivers, i386 in some configs). Classic 8/16-bit arcade drivers are interpreted anyway and won't notice. Heavy 3D systems (Model 2/3, Naomi-era, Saturn, N64, Seattle/Vegas) will be noticeably slower with the C backend, though an M2/M5 has a lot of headroom.
- **Possible later:** dev builds with `get-task-allow` and a debugger attached can sometimes JIT on iOS (StikDebug-style tricks). Whether that works on visionOS is unknown, and it's only for sideloaded builds. Not a plan of record. If it did work, `drcbe_arm64` would need `MAP_JIT` plus `pthread_jit_write_protect_np` handling (not in tree today: `grep MAP_JIT src/` is empty).

---

## 5. Display plan

**Phase 1: flat window in the Shared Space (first light).** SDL3 creates a `UIWindowScene`, which
visionOS shows as a floating, resizable 2D window, the same as a "Designed for iPad" app. MAME renders
into it with bgfx Metal (or SDL_Renderer). The existing fullscreen/switchres code
(`window.cpp:950ff`) should be disabled or made a no-op, since there are no display modes on visionOS.

**Phase 2: spatial presentation.** Here SDL gets in the way, because SwiftUI and RealityKit need to own
the app lifecycle. Options:
- **2a. Native `visionos` OSD** modelled on `src/osd/mac`: a SwiftUI app runs MAME on a background thread. The OSD renders with bgfx into an **offscreen framebuffer / `MTLTexture`**, which is handed to RealityKit (`LowLevelTexture` / `TextureResource.DrawableQueue`) and mapped onto a `ModelEntity` quad. That quad can be a big floating screen, or the screen on a 3D cabinet model in a `RealityView` / `ImmersiveSpace`. Input comes from GameController plus SwiftUI gestures. **Recommended long-term path.**
- **2b. Compositor Services** (`CompositorLayer`, full immersive custom Metal): maximum control and per-eye rendering, but we'd be writing the whole scene renderer ourselves. Only worth it for true stereo 3D (§7). Upstream bgfx doesn't appear to support `cp_layer_renderer` today **[verify]**.

MAME's render targets (`render_target`) already support multiple independent targets and layout views.
So a later step could render e.g. the bezel/artwork and the game screen as separate textures for
separate spatial layers.

---

## 6. Input plan

- **Game controllers** (PS5, Xbox, MFi): work out of the box via SDL3's gamepad API, which is backed by GCController. This is the primary input. The native mac OSD's `input_macgame.mm` uses GCController directly and can be reused for the native OSD.
- **Bluetooth keyboard**: SDL keyboard events. Needed for the MAME UI (Tab/Esc/etc.) until controller UI mappings are set up. Ship a default `ctrlr` / ini that maps UI_MENU, UI_CANCEL, coin and start to controller buttons. Controller UI navigation mostly works already.
- **Look and pinch**: arrives as pointer/touch events in UIKit, which SDL turns into mouse/touch events. Good enough for the MAME menu, and possibly for lightgun games (gaze-plus-pinch as a trigger is interesting).
- **Hand tracking / spatial controllers**: phase 2 only, needs ARKit in a Full Space.
- **Lifecycle**: handle `SDL_EVENT_WILL_ENTER_BACKGROUND` / `DID_ENTER_FOREGROUND` (and window-scene close) by pausing emulation and saving nvram/cfg. visionOS kills backgrounded scenes aggressively.

---

## 7. Upscaling

**2D resolution upscaling (easy):** the bgfx post-processing chains are already in `bgfx/chains/`: `xbr`,
`hqx`, `eagle`, `depixelize`, `crt-geom(-deluxe)`, `lcd-grid`, `hlsl`, `lut`, and more. Metal shader
binaries exist in `bgfx/shaders/metal/`. Select them with `-bgfx_screen_chains xbr` once bgfx runs.
Rebuilding shaders (`make shaders`) is documented as Windows-only (`makefile:1681`), so we'll use the
prebuilt binaries. Newer Apple options to look at later: MetalFX spatial upscaling (check it's available
on visionOS) as a final pass in the RealityKit presenter.

**"3D upscaling":** this needs clarifying (see §9). Two meanings:
- **Higher internal resolution for 3D games** (Model 2/3, Voodoo-based, PSX, N64 and so on). MAME rasterises polygons in software at native resolution into a bitmap (`src/emu/video/poly.h` and per-driver renderers). There's no GPU-accelerated 3D path. Rendering at N× internal resolution would be **per-driver work**: scale the rasteriser's viewport and bitmap, and tell the screen device its visible area is larger. This is a research project, feasible for one or two chosen drivers but not across all of them.
- **Stereoscopic depth for 2D games** (e.g. separating sprite, tilemap and background layers onto different depth planes). Also per-driver: we'd have to hook the video update so layers are emitted separately rather than composited. Very compelling on Vision Pro, and needs the Compositor Services path (5 → 2b) or RealityKit layered quads. A generic alternative is AI depth estimation per frame, which is cheaper to integrate but lower quality.

---

## 8. Proposed milestones (for the Mac agent)

1. **Toolchain sanity:** ✅ done. SDL3.xcframework built from source with visionOS device+simulator slices (needed one upstream SDL3 patch, see README); `3rdparty` libs and all of MAME build and link for both `visionos-clang` and `visionos-sim-clang`.
2. **Tiny MAME for the simulator:** binary and `.app` bundle exist, both for a single driver (`SOURCES=src/mame/pacman/pacman.cpp`) and for `SUBTARGET=tiny` (59 drivers, full netlist), but **not yet launched** — this build machine's CoreSimulator is out of date for Xcode 27, so `simctl`/Simulator.app don't work here. Needs a Mac where the Simulator actually runs to reach "Pac-Man on screen."
3. **Device build:** ✅ compiles and links (`make visionos`). Code signing with a real dev team and on-device run are still untested.
4. **bgfx Metal:** patch bx detection, add the UIKit branch in `drawbgfx.cpp`, `-video bgfx`, try the `xbr` / `crt-geom` chains. ✅ partially derisked: with no visionOS Simulator available on this build machine (see milestone 2), the same source tree was instead built natively for macOS (`make macosx_arm64_clang SOURCES=src/mame/pacman/pacman.cpp NOASM=1`, sdl3 OSD, same `MAME_NOASM=1`/C-DRC-backend config) and actually run. Both `-video accel` (SDL/OpenGL) and `-video bgfx -bgfx_backend metal` start cleanly, initialize CoreAudio/keyboard/mouse/lightgun/GameController, and reach a stable running frontend ("BGFX: Vector CRT renderer initialized", no crash). This doesn't exercise the UIKit-specific `CAMetalLayer` branch in `drawbgfx.cpp` (that needs the actual visionOS Simulator/device), but it confirms the shared bgfx/Metal, SDL3, and C-DRC-backend code in this tree is sound on real Apple Silicon. No screenshot could be taken (this build machine's display is asleep/headless and Screen Recording + Accessibility TCC permissions aren't grantable without an interactive GUI session), but the process stays alive and steady (no crash-loop) under both renderers.
5. **Controller defaults and UI:** default ini/ctrlr for gamepad, lifecycle pause/resume, file import.
6. **Bigger driver set / full build:** check link time and app size; decide on a SUBTARGET.
7. **Phase 2 display:** prototype the native `visionos` OSD rendering to an MTLTexture shown in RealityKit.
8. **3D experiments** once we've clarified which meaning of "3D upscaling" we want.

---

## 9. Open questions for you

1. **Distribution:** personal/sideload only, TestFlight, or App Store? The App Store adds review concerns for emulators and rules out any JIT ideas.
2. **Scope:** the full MAME driver list, or a curated subset (arcade only)? This affects build time, app size, and how much DRC performance matters.
3. **"3D upscaling":** higher internal resolution for polygon games, stereo depth for 2D games, or both?
4. **App shell:** is SDL (quick, UIKit, Shared Space window only) fine as a stepping stone, or should we go straight to a SwiftUI shell with a native OSD?
5. ~~**Hardware:**~~ answered: **M2**. Budget accordingly. Interpreted classic systems will be fine. With the C DRC backend, heavy recompiler-era systems (Model 3, Naomi, Saturn, N64, Seattle/Vegas) will likely fall short of full speed, and the frame budget also has to cover rendering at visionOS's 90 Hz compositor rate.

## References
- SDL3 visionOS platform macro: https://wiki.libsdl.org/SDL3/SDL_PLATFORM_VISIONOS
- SDL visionOS support PR: https://github.com/libsdl-org/SDL/pull/8027
- bgfx upstream (visionOS support in bx/bgfx master): https://github.com/bkaradzic/bgfx
- Compositor Services: https://developer.apple.com/documentation/compositorservices
- Metal on visionOS example: https://github.com/gnikoloff/drawing-graphics-on-apple-vision-with-metal-rendering-api
- JIT on iOS background: https://saagarjha.com/blog/2020/02/23/jailed-just-in-time-compilation-on-ios/
