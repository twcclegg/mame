# MAME on visionOS: initial research

Status: research only, nothing is built yet. Written from a Linux container, so
every claim about Xcode, SDKs or device behaviour is marked **[verify on Mac]**
where it hasn't been checked against a real toolchain.

> **Progress (2026-09-27): it runs.** `MAME-sim.app` launches in the visionOS
> 26.5 Simulator and renders MAME's real system-selection UI as a Metal-backed
> window floating in the Shared Space — goal 1 (Run) and the first half of
> goal 2 (Display: a window in the Shared Space) are done. Getting there took
> four fixes total (two build-only, two needed to actually launch): Lua's
> `os.execute`, sqlite3's `gethostuuid` probe, building SDL from ≥3.4.0 instead
> of 3.2.x (3.2.x has no UIScene support and visionOS fatally traps apps that
> lack it), and a real, platform-agnostic MAME bug in `drawsdl3accel.cpp`
> (claimed `FLAG_SDL_NEEDS_OPENGL` when it doesn't actually need an
> OpenGL-flagged window, which broke window creation on any GL-less
> platform). See [README.md](README.md) for details and the file list.
> SDL3's own GameController backend picked up a virtual gamepad with no extra
> work. Still open: bgfx-on-Metal specifically (vs. the default SDL_Renderer
> path, which does now work), actual gameplay with a loaded ROM, and device
> (hardware) launch. Hardware is confirmed as an **M2** Vision Pro.

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
SwiftUI/RealityKit to own the app, which is phase 2 of display. **But see §1a:**
MAME4iOS has already built exactly this kind of OSD for iOS.

---

## 1a. Prior art: MAME4iOS (added 2026-09-28, missed in the first pass)

[yoshisuga/MAME4iOS](https://github.com/yoshisuga/MAME4iOS) is an actively maintained
port of current MAME to iOS, iPadOS, tvOS and Mac Catalyst. The Xcode config shows
`MARKETING_VERSION = 2026.6` and an App Store build flag. It is the closest prior
work, and it **already solves most of phase 2** (the native OSD) for UIKit.

**How it's put together:**
- **Two repos.** The app (UIKit, Objective-C and Swift, GPL-2.0) lives in MAME4iOS. MAME itself comes from a fork, [ToddLa/mame](https://github.com/ToddLa/mame), which tracks upstream closely: it's at **0.288**, one version behind this tree. The fork adds an `OSD=ios` layer (`src/osd/ios/`, about 1,400 lines, BSD-3 headers) and `make-ios.sh`, which builds MAME as a **static library** (`libmame-ios.a`, `-tvos`, `-mac`, plus simulator variants). The app downloads prebuilt libs from the fork's releases (`get-libmame.sh`) or links locally built ones.
- **The interface** is a small C callback API (`src/osd/ios/libmame.h`): `myosd_main(argc, argv, callbacks)`, with callbacks for `video_draw(myosd_render_primitive *list, w, h)`, `input_poll`, `sound_play`, `game_list` and so on. MAME hands over **render primitive lists** (quads and lines with textures and UVs), and the app draws them in its own **Metal renderer**, which comes with CRT and vector shaders (`megaTron`, `lineTron`, `ulTron`, `simpleTron`).
- **No bgfx and no SDL.** The app owns UIKit, Metal, GameController, audio and the file UI. MAME is purely a library.
- **No JIT**, the same as ours: `make-ios.sh` sets `FORCE_DRC_C_BACKEND=1`. They also expose a "Use DRC" toggle, because some DRC games (e.g. NFL Blitz) misbehave with the C backend on arm64 and run better with `-nodrc` (the interpreter). That's worth knowing for us too.
- **No visionOS target yet.** Neither the Xcode project nor `make-ios.sh` mentions `xros`.

**What this means for us:**
1. **The quickest check of all:** see whether the App Store's iPad build of MAME4iOS installs on the Vision Pro as a "compatible iPad app". If it does, we have a baseline for performance and input today, with no build at all. **[check on device]**
2. **The `myosd` API is the native OSD that §5 (phase 2a) proposed writing.** A primitive list is the ideal input for spatial presentation: our own Metal or RealityKit code can draw the game screen, bezels and artwork as separate layers or quads, and render per-eye through Compositor Services later. Reusing it beats writing a new OSD from `src/osd/mac`.
3. **Adding a visionOS slice to their pipeline looks small:** a `visionos` / `visionos-simulator` case in `make-ios.sh` (`-target arm64-apple-xros2.0 -isysroot $(xcrun --sdk xros --show-sdk-path)`), plus a visionOS destination in their Xcode targets. Most of their UIKit app should compile for visionOS. `UIScreen`-based sizing, the TopShelf/tvOS bits and the web server may need `#if`s. **[verify on Mac]**

**Revised recommendation:** Path A has since reached first light (milestone 2), so this is now a phase-2 decision.
- **Path A, SDL3 (this branch, runs in the simulator):** stock upstream structure, no app code, bgfx shader chains. Good for a *plain window*, but spatial features would need a rewrite later.
- **Path B, `myosd` / libmame:** either (B1) build MAME4iOS itself for visionOS, the quickest way to a *polished* app with menus, controllers and file import, or (B2) write our own SwiftUI + RealityKit app against `libmame.h`, which is the best base for goals 2–4 (spatial display, 3D). B2 can borrow B1's Metal renderer and shaders.

The work already done on Path A carries over to B only in part. The toolchain
knowledge, JIT findings and sandbox paths apply to both; the bgfx and bx patches
don't matter for B, which doesn't use bgfx. The likely end state is **B2 built on
ToddLa's `ios` OSD**, possibly upstreamed into this fork as `OSD=ios` with an added
`xros` target, and with Path A kept as a debugging fallback.

## 1b. Other prior art (added 2026-09-28)

**Emulators on the Vision Pro today:**
- **RetroArch** (App Store) and **Provenance** list Apple Vision compatibility, but both are **iPad apps running in compatibility mode**, not native visionOS apps. RetroArch's Xcode project targets device families 1,2 (iPhone/iPad) and tvOS only; neither has a visionOS target or spatial features. RetroArch's libretro MAME core is another iOS cross-compile precedent: `Makefile.libretro` builds with `TARGETOS=macosx`, `LIBRETRO_IOS=1` and an `-target arm64-apple-ios` ARCHOPTS, the same trick ToddLa's `make-ios.sh` uses. Provenance ships MAME only for Apple II, and keeps it out of the App Store build.
- **MAME4iOS** (§1a) has no visionOS target either. Its App Store build is presumably the "ArcadeMania" app (its xcconfig names an `ArcadeMania` launch screen), but I couldn't confirm that or its Vision Pro availability, because App Store pages are blocked from this container. **[check on device]**
- There's **no native, spatial MAME port** that I could find. That's the gap this project fills.

**Spatial arcade UX reference: Retrocade** (Resolution Games, Apple Arcade, Feb 2026). It has 7 licensed classics (Namco, Atari, Taito, Konami) running original ROMs in emulation, inside 3D cabinets with period artwork and control panels. It offers three viewing modes on Vision Pro, including a fully immersive virtual arcade and cabinets placed in your room via passthrough. It has an on-by-default CRT filter and a faux screen reflection. Coverage praises the immersion, but the headlines hint at caveats (UploadVR: "…With A Catch"; Gizmodo: "could not provide me the (fake) arcade of my dreams"). I couldn't read either review because they're blocked from this container, so what the catch is remains unknown. It's the bar for our "virtual cabinet" display goal. The emulator it uses isn't public.

**Stereoscopic 3D precedents** (for the "3D upscaling" goal): Dolphin's stereoscopy mode and PPSSPP VR re-render *hardware-rendered* 3D geometry per eye. That's possible because those emulators draw through a GPU API. MAME's 3D systems rasterize in software per driver, so the equivalent needs per-driver work (§7) or a renderer rewrite for the chosen driver. Nothing generic to borrow.

**visionOS platform facts that affect the design:**
- **The controller Home button (PS / Xbox / Guide) is reserved by the system** and never reaches the app. MAME's SDL3 gamepad support maps the UI menu to Guide, so we need another binding. **Done:** `visionos/ctrlr/visionos.cfg` adds Select+Start, and the libmame host uses Select+Start as well. Volumetric windows reportedly expose even fewer controller inputs.
- **Per-frame Metal texture into RealityKit:** use `LowLevelTexture`. Apple recommends it in WWDC24 "Bring your iOS or iPadOS game to visionOS", and you can blit an existing `MTLTexture` into it each frame. This is the path for phase 2a (the game screen on a RealityKit quad or cabinet) without going full Compositor Services.
- **JIT:** StikDebug-style debugger JIT enabling targets iOS (17.4 and later; iOS 26 support is shaky) with sideloaded `get-task-allow` builds. Nothing indicates it works on visionOS. Treat no-JIT as permanent.

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
- **Look and pinch**: arrives as pointer/touch events in UIKit, which SDL turns into mouse/touch events. Good enough for the MAME menu, and possibly for lightgun games (gaze-plus-pinch as a trigger is interesting). ✅ confirmed useful for more than the menu: MAME's `dial_device`/`paddle_device`/`trackball_device` options (`ioport.cpp:1856-1862`) default to `keyboard`, not `mouse` — set them to `mouse` (now the visionOS default in `visionos/ini/mame.ini`) and any spinner/paddle/trackball game (Arkanoid's paddle is an `IPT_DIAL`) becomes steerable by gaze, no per-game setup. Not yet confirmed hands-on (no way to synthesize pointer motion from this build machine — `simctl` has no touch/pointer injection, and Accessibility automation to move a real pointer is blocked, same TCC issue as screenshots before that got fixed); needs a person actually looking around in the headset/simulator to verify the paddle actually tracks.
- **Head-pose tracking is not available here.** A plain windowed (Shared Space) app — which is what this SDL3 port is — has no ARKit/head-pose access at all; that's an OS-level privacy boundary, not a missing SDL feature. Getting literal head-tilt input needs the native/RealityKit OSD below, not a config change.
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

## 7a. Per-game renderers: what libmame provides (added 2026-09-28)

The direction is **renderers built for specific games** (Arkanoid first, on
branch `claude/arkanoid-3d-visionos`), plus generic presentation for
everything else. A per-game renderer can draw on four things from libmame:

| Need | libmame API | Status |
|---|---|---|
| The emulated screen, framed tightly | `video_draw_pixels` (native res × integer scale, native size + aspect) and `MYOSD_ZOOM_TO_SCREEN` (crop artwork) | done |
| Game state (sprites, tilemaps, RAM) | memory-read API | being added by the Arkanoid session |
| True 3D geometry for polygon games | `geometry_frame` callback + `MYOSD_SUPPRESS_NATIVE_3D`, fed by `src/emu/geomexport.h` | done for **Sega Model 1**; other drivers need a hook each |
| Lifecycle | `MYOSD_PAUSE` (pauses, flushes NVRAM, never undoes a user pause) | done; MAMEVision pauses when all its scenes are backgrounded |

**Item 3 (a Metal primitive renderer for layered artwork): deferred.** It was
proposed for two reasons: (a) crisp MAME UI text and (b) splitting
bezel/backdrop artwork into separate spatial layers.
- For (a): the native×integer frame keeps MAME's menus legible, if chunky.
- For (b): per-game renderers will build their own surroundings (cabinets, playfields) rather than reuse MAME's 2D `.lay` artwork. Where artwork is wanted, it can come from a second render target with `set_zoom_to_screen(false)` and the screen hidden via view visibility toggles. That's much cheaper than re-implementing MAME's texture formats, palettes and blend modes in Metal.
- The primitive-list path (`video_draw`) remains in libmame if a real need shows up.

**Item 4 ("3D upscaling"): research result.** MAME's 3D arcade hardware is
emulated with per-driver software rasterizers (29 users of `poly_manager`
alone: Model 2/3, Namco System 22/23, Gaelco 3D, Midway V-Unit/Zeus,
Voodoo-based systems, N64 and others). There are two ways to go beyond native resolution:
1. **Rasterize at N× inside MAME.** This is per-driver surgery: scale vertex coordinates and bitmaps, and upscale the 2D layers alongside. It costs N² CPU time on a no-JIT M2, and it breaks drivers whose games read the framebuffer back (Voodoo). **Rejected.**
2. **Export the geometry and let the host GPU render it.** Resolution-independent and **truly stereoscopic**, since the geometry keeps its real depth. It costs one hook per driver, at the point where the driver has camera-space polygons just before projecting them. **Chosen.**

**Pilot: Sega Model 1** (Virtua Racing, Virtua Fighter, Star Wars Arcade, Wing War).
- `model1_v.cpp` transforms into camera space, frustum-clips, then projects in `view_t::project_point()` with `s = c + (p/z·zoom + view)`.
- Quads are flat-shaded, with their colour already lit and stored as RGB.
- `draw_quads()` now exports each batch (quads plus that view's projection) when a sink is registered. It skips its own fill when asked, so the video frame keeps only the 2D layers (HUD, text) for compositing.
- It's also CPU-friendly for us: v60 and TGP (MB86233) are interpreted, not DRC.

The next driver candidates are Model 2, which projects in `model2_3d_project()` and adds textures (it would need a texture export too), and Namco System 22.

**Host rendering of exported geometry: still open.** RealityKit `LowLevelMesh`
can take per-frame vertex data, but it's unclear whether RealityKit's built-in
materials honour a per-vertex colour attribute. Options:
- a `ShaderGraphMaterial` that reads the colour from a UV channel;
- grouping polygons by colour into mesh parts;
- a Compositor Services Metal renderer, which gives full control and per-eye rendering.

`GeometryStore` in MAMEVision already copies each frame into Swift arrays and
documents how to rebuild the game's camera (vertical FOV = 2·atan((screen_h/2)/scale_y)).

## 8. Proposed milestones (for the Mac agent)

0. **Prior-art checks (§1a):** see whether MAME4iOS from the App Store runs on the Vision Pro as an iPad app (a zero-build baseline to compare against). For phase 2, try adding an `xros` slice to ToddLa's `make-ios.sh`.

1. **Toolchain sanity:** ✅ done. SDL3.xcframework built from source with visionOS device+simulator slices (needed one upstream SDL3 patch, see README); `3rdparty` libs and all of MAME build and link for both `visionos-clang` and `visionos-sim-clang`.
2. **Tiny MAME for the simulator:** ✅ done, and launched. `MAME-sim.app` (built with `SOURCES=src/mame/pacman/pacman.cpp`) runs in the visionOS 26.5 Simulator (`xcrun simctl launch` + `xcrun simctl io screenshot`, no `Simulator.app` GUI needed — this Xcode install doesn't even ship one) and renders MAME's system-select UI as a floating Metal window in the Shared Space. Two blockers on the way, both now fixed: the build machine's CoreSimulator/Xcode version mismatch (fixed by the user updating macOS to 27.0, matching Xcode 27), and two runtime bugs (SDL's UIKit backend needing scene-lifecycle support — use SDL ≥3.4.0 — and a `FLAG_SDL_NEEDS_OPENGL` bug in `drawsdl3accel.cpp`). See README.md Status for the exact fixes. Not yet tried: an actual ROM (only the ROM-less frontend has been shown), and the `visionOS 27.0` Simulator runtime on this machine turned out to be broken (`liblaunch_sim.dylib could not be opened`) — 26.5 worked fine.
3. **Device build:** ✅ compiles and links (`make visionos`). Code signing with a real dev team and on-device run are still untested.
4. **bgfx Metal:** patch bx detection, add the UIKit branch in `drawbgfx.cpp`, `-video bgfx`, try the `xbr` / `crt-geom` chains. ✅ partially derisked: with no visionOS Simulator available on this build machine (see milestone 2), the same source tree was instead built natively for macOS (`make macosx_arm64_clang SOURCES=src/mame/pacman/pacman.cpp NOASM=1`, sdl3 OSD, same `MAME_NOASM=1`/C-DRC-backend config) and actually run. Both `-video accel` (SDL/OpenGL) and `-video bgfx -bgfx_backend metal` start cleanly, initialize CoreAudio/keyboard/mouse/lightgun/GameController, and reach a stable running frontend ("BGFX: Vector CRT renderer initialized", no crash). This doesn't exercise the UIKit-specific `CAMetalLayer` branch in `drawbgfx.cpp` (that needs the actual visionOS Simulator/device), but it confirms the shared bgfx/Metal, SDL3, and C-DRC-backend code in this tree is sound on real Apple Silicon. No screenshot could be taken (this build machine's display is asleep/headless and Screen Recording + Accessibility TCC permissions aren't grantable without an interactive GUI session), but the process stays alive and steady (no crash-loop) under both renderers.
5. **Controller defaults and UI:** default ini/ctrlr for gamepad, lifecycle pause/resume, file import.
6. **Bigger driver set / full build:** check link time and app size; decide on a SUBTARGET. ✅ first data point: a deliberately diverse 13-driver sample — one per major DRC CPU family (MIPS3 `konami/ksys573.cpp`, PowerPC `sega/model3.cpp`, SH2 `namco/namcos23.cpp`, SH4 `sega/naomi.cpp`, Hyperstone `misc/vamphalf.cpp`, TMS32031 `williams/midvunit.cpp`, SHARC `konami/gticlub.cpp`, ARM7 `misc/39in1.cpp`) plus CHD/hard-disk (`williams/vegas.cpp`), GD-ROM (`naomi.cpp`), a second 3D-geometry candidate (`sega/model2.cpp`), a vector display (`atari/asteroid.cpp`), a laserdisc game (`stern/cliffhgr.cpp`), and a softlist-heavy home computer (`apple/apple2.cpp`) — compiles for `visionos-sim` with **zero errors** (805 driver variants total) and passes `-validate` cleanly (silent exit, MAME's convention for "no errors found," confirmed against a known-good native-macOS baseline). Strong signal that the source tree is broadly portable, not just the handful of arcade boards tried so far; a genuinely full, unrestricted build is the next step if this needs to be conclusive rather than just a strong sample.
7. **Phase 2 display:** prototype the native `visionos` OSD rendering to an MTLTexture shown in RealityKit.
8. **3D experiments** once we've clarified which meaning of "3D upscaling" we want.

---

## 9. Open questions for you

1. **Distribution:** personal/sideload only, TestFlight, or App Store? The App Store adds review concerns for emulators and rules out any JIT ideas.
2. **Scope:** the full MAME driver list, or a curated subset (arcade only)? This affects build time, app size, and how much DRC performance matters.
3. **"3D upscaling":** higher internal resolution for polygon games, stereo depth for 2D games, or both?
4. **App shell:** is SDL (quick, UIKit, Shared Space window only) fine as a stepping stone, or should we go straight to a SwiftUI shell with a native OSD?
5. ~~**Hardware:**~~ answered: **M2**. Budget accordingly. Interpreted classic systems will be fine. With the C DRC backend, heavy recompiler-era systems (Model 3, Naomi, Saturn, N64, Seattle/Vegas) will likely fall short of full speed, and the frame budget also has to cover rendering at visionOS's 90 Hz compositor rate.

## 10. Handoff: open items from the research session (2026-09-28)

These are loose ends from the cloud research session, which had no Mac. The
Mac-side status lives in README.md.

**Checks for a person with the headset (no build needed):**
- Does MAME4iOS's App Store build (probably "ArcadeMania") install on Vision Pro as an iPad app? If so, it's a zero-build baseline for speed and controls without JIT. See §1a.
- Retrocade (Apple Arcade): note how its CRT effect, screen scale and legibility, and controls feel. It's the design bar for a cabinet mode (§1b).

**Written but not yet exercised at runtime:**
- Pause on background, the NVRAM flush and never undoing a user pause (`MYOSD_PAUSE`, MAMEVision `scenePhase`). To test: close the window mid-game and reopen; take the headset off.
- `MYOSD_ZOOM_TO_SCREEN` in theater mode. Check with a game that has bezel artwork.
- **Sega Model 1 geometry export** (`src/emu/geomexport.h`, `model1_v.cpp`, `geometry_frame`). It needs a Model 1 ROM (e.g. Virtua Racing) and a host that sets `wantsGeometry`. `MYOSD_SUPPRESS_NATIVE_3D` should leave only the HUD in the frame.
- SDL3 build: Select+Start opening the MAME menu (`visionos/ctrlr/visionos.cfg`). MAMEVision's own combos: Select+Start = menu, Select+L1 = ESC, Select+R1 = pause.

**Next decisions and steps:**
- A host renderer for exported geometry. Options are in §7a: a ShaderGraph material with colour in UV, colour-grouped mesh parts, or Compositor Services.
- Model 2 geometry export: it also needs a texture export.
- `claude/arkanoid-3d-visionos` was merged with this branch at `9501bc5a` (the libmame API conflicts were resolved by keeping both sides). Keep merging this branch into it as libmame changes. It's meant to move to its own repository eventually; the GitHub integration here can't create repositories, so create an empty one and any session can push there.
- Cloud sessions can't type-check Swift. Adding `download.swift.org` to the environment's allowed domains would let them check the libmame C interop (not SwiftUI/UIKit).

**Known and harmless:** the files imported from ToddLa in `src/osd/ios/` use Clang-only extensions (`_Static_assert` in C++, `offsetof` with a runtime index). GCC rejects them, but only Apple Clang ever compiles that OSD.

## References
- RetroArch App Store listing: https://apps.apple.com/us/app/retroarch/id6499539433
- Provenance: https://github.com/Provenance-Emu/Provenance
- libretro MAME core: https://github.com/libretro/mame
- Retrocade coverage: https://appleinsider.com/articles/26/01/14/apple-vision-pro-owners-will-get-a-great-assortment-of-classic-arcade-games-in-vr-soon , https://www.uploadvr.com/retrocade-for-apple-vision-pro-nostalgic-virtual-arcade-review/
- WWDC24 "Bring your iOS or iPadOS game to visionOS" (LowLevelTexture): https://developer.apple.com/videos/play/wwdc2024/10093/
- Controller button reservation on visionOS: https://developer.apple.com/forums/tags/game-controller
- StikDebug: https://github.com/StikDebug/StikDebug
- MAME4iOS (app): https://github.com/yoshisuga/MAME4iOS
- ToddLa/mame (MAME fork with `OSD=ios`, `make-ios.sh`, `src/osd/ios/libmame.h`): https://github.com/ToddLa/mame
- SDL3 visionOS platform macro: https://wiki.libsdl.org/SDL3/SDL_PLATFORM_VISIONOS
- SDL visionOS support PR: https://github.com/libsdl-org/SDL/pull/8027
- bgfx upstream (visionOS support in bx/bgfx master): https://github.com/bkaradzic/bgfx
- Compositor Services: https://developer.apple.com/documentation/compositorservices
- Metal on visionOS example: https://github.com/gnikoloff/drawing-graphics-on-apple-vision-with-metal-rendering-api
- JIT on iOS background: https://saagarjha.com/blog/2020/02/23/jailed-just-in-time-compilation-on-ios/
