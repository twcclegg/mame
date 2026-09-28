# Arkanoid 3D (visionOS, experimental)

This is the **original arcade Arkanoid**, emulated exactly by MAME
(`src/mame/taito/arkanoid.cpp`), but shown as a 3D scene in RealityKit. It is
not a clone. MAME runs the real program, and every emulated frame the app reads
the video hardware's state and uses it to drive 3D objects:

- the background tilemap becomes bricks (bevelled, with depth; silver and gold ones are metallic)
- sprite RAM becomes the Vaus (metal body, red caps, stretches when enlarged), glowing balls with their own light, rolling colour-coded capsules, enemies and lasers
- a floor and metal walls make a table-top box, and bricks shatter into fragments when they break

Gameplay stays authentic and so does the sound, which is MAME's. The original
2D picture can be shown as a small screen behind the far wall. You supply your
own ROM set; the app never downloads any.

```
MAME thread                                        main thread (RealityKit, 90 Hz)
───────────                                        ─────────────────────────────
Z80 + 68705 run a frame
machine_frame callback ──► GameState.swift
   myosd_get_memory_share(":videoram"/":spriteram")
   myosd_read_memory(":maincpu", c000-c7ff)
   save items m_gfxbank/m_palettebank/m_flip_*
   ark3d_decode()  (Decoder/ark3d.c)  ──► GameStateStore ──► PlayfieldScene
   PaddleController ──► myosd_set_analog_input(":P1")        (eases entities,
video_draw_pixels ──► FrameStore ────────────────────────────► 2D screen)
```

## What's in here

| Path | What |
|---|---|
| `Decoder/ark3d.{h,c}` | Portable C11 decoder. Raw videoram and spriteram bytes (plus the gfx and palette ROM regions) go in; a typed state comes out: brick grid, Vaus x/width, balls, capsules (S/C/L/E/D/B/P), enemies, lasers, high score. |
| `ARKANOID_STATE.md` | The memory layout, with file:line references into MAME, and a note of which parts are exact and which are heuristics. |
| `Tests/` | `make -C visionos/arkanoid3d/Tests` runs the unit tests over synthetic buffers on Linux or macOS. `run_e2e.sh` runs a plumbing test through a real MAME build. `ark3d_dump` decodes captures. |
| `lua/ark3d_capture.lua` | MAME Lua script. It records, every frame, exactly what the app reads, so the decoder can be checked offline against a real ROM. |
| `App/` | The SwiftUI and RealityKit app: control window, volumetric table-top, immersive "arena". |
| `project.yml` | XcodeGen project. It links the same `libmame.xcframework` as MAMEVision and reuses its `MAMEEngine`, `GameControllerInput`, `ScreenUpdater` and `Shaders.metal`. |

The libmame side is generic and not Arkanoid-specific. It was added to
`src/osd/ios/libmame.h` in a backward-compatible way:

- the `machine_frame` callback runs once per emulated frame on the MAME thread, while the CPUs are stopped
- `myosd_get_memory_share` / `myosd_get_memory_region` return a zero-copy pointer, looked up by tag
- `myosd_get_state_item` returns a device's `save_item` variable, which reaches latched write-only registers
- `myosd_read_memory` reads an address space with side effects disabled
- `myosd_set_analog_input` / `myosd_clear_analog_input` override an analog field, for absolute paddle control

The new callback is appended to `myosd_callbacks`, and `myosd_main` now honours
`callbacks_size`, so older hosts get `NULL` for it. MAMEVision is unchanged: its
`MAMEEngine` gained optional hooks, and while they're nil the new callbacks
aren't installed.

## Build (on a Mac)

Requirements: Xcode with the visionOS SDK, XcodeGen (`brew install xcodegen`)
and Python 3.

```sh
# 1. libmame with just the Arkanoid driver (simulator; use `all` for device + simulator)
visionos/make-libmame.sh sim SOURCES=src/mame/taito/arkanoid.cpp

# 2. the app
cd visionos/arkanoid3d
xcodegen
open Arkanoid3D.xcodeproj        # run the Arkanoid3D scheme on the visionOS simulator / device
```

Copy your ROM set (for example `arkanoid.zip`) into the app's **Documents/roms**
folder, using the Files app on the device or Finder file sharing. For the
simulator, use the app container's Documents folder
(`xcrun simctl get_app_container booted org.mamedev.arkanoid3d data`). Clones
such as `arkanoidj` also need the parent `arkanoid.zip`. Then press **Start** in
the control window, and the table-top volume opens. A launch argument starts a
set directly, for example `xcrun simctl launch booted org.mamedev.arkanoid3d arkanoid`.

### Controls

| | |
|---|---|
| Left stick / d-pad | move the Vaus |
| A | fire (laser) / launch (catch) |
| Select (View / Share / Create) | insert coin |
| Start (Menu / Options) | 1 player start |
| Select + Start | MAME menu (the Home button is reserved by visionOS) |
| **Pinch & drag** | look at the field, pinch and move your hand sideways: the Vaus goes where you point |
| **Hand** (arena only) | the Vaus follows your right index fingertip (ARKit hand tracking) |

The paddle is a relative spinner, so absolute control runs in a closed loop.
Each frame `PaddleController` compares the Vaus x (from sprite RAM) with the
target and writes a new spinner count through `myosd_set_analog_input`. It
measures the pixels-per-count ratio as you play. The stick is handled the same
way, as a target velocity, so MAME's own dial mapping and the override never
fight.

## Testing without a Mac or a ROM

```sh
make -C visionos/arkanoid3d/Tests test synth dump     # unit tests: 88 checks
make SOURCES=src/mame/taito/arkanoid.cpp -j8          # headless-capable Linux MAME, Arkanoid only
visionos/arkanoid3d/Tests/run_e2e.sh ./mame           # plumbing test through that MAME
```

`run_e2e.sh` writes **placeholder** ROM files: zeros for the program, and
synthetic graphics and palette. MAME runs them with a checksum warning. The
Lua script injects a synthetic playfield into the real `:videoram` and
`:spriteram` shares, captures it, and `ark3d_dump` decodes the capture. This
proves the names, the format and the decoder path. It says nothing about the
real game, whose program never runs.

## Validating with a real ROM (to do)

```sh
ARK3D_OUT=cap.bin ./mame arkanoid -autoboot_script visionos/arkanoid3d/lua/ark3d_capture.lua
# play a few rounds (collect capsules, lose a life, reach round 2), then quit
make -C visionos/arkanoid3d/Tests dump
visionos/arkanoid3d/Tests/build/ark3d_dump cap.bin | less        # one line per frame
visionos/arkanoid3d/Tests/build/ark3d_dump cap.bin -f 1500       # grid + tilemap codes + objects
visionos/arkanoid3d/Tests/build/ark3d_dump cap.bin --codes       # which codes were seen as what
```

Check these, in order:

1. **Layout.** In `-f` output, round 1's bricks should fill whole cells of the
   13-wide grid, the walls should sit at view columns 0 and 27, and the text
   should sit in rows 0–1. If they're off, set `layout` in the calibration file.
2. **Vaus and balls.** The Vaus x should track the paddle, and its width should
   grow with an E capsule. Balls should show up.
3. **Capsules.** Each letter should be recognised by its colour.
4. **Silver, gold, text and shadows.** Find their codes in `--codes` and the
   tilemap dump.

Put what you find in `Documents/arkanoid3d.json`. `GameState.swift` loads it
when a game starts:

```json
{
  "tiles":    { "0x1a0": "gold", "0x1a1": "gold", "0x1c0": "silver", "0x0b0": "text" },
  "sprites":  { "0x010": "vaus", "0x018": "vaus_laser", "0x020": "ball" },
  "capsules": { "0x040": "L" },
  "layout":   { "grid_top": 32, "grid_rows": 18 }
}
```

Codes include the graphics bank: add 0x800 for tiles and 0x400 for sprites
when `gfxbank` is 1. Once the tables are known they should become the
decoder's defaults.

## What's verified and what isn't

**Verified (in the Linux container this was written in):**
- The libmame C++ additions pass a syntax check with clang 18 using the OSD's
  flags. GENie still generates the `OSD=ios`, `targetos=visionos` project,
  and it now includes `state.cpp`.
- The decoder is warning-free under gcc and clang with `-Werror -Wconversion`,
  and passes 88 unit checks over synthetic data.
- The capture script, share, region and save-item names, capture format and
  decoder were run end to end through a real MAME build of this tree (Linux,
  Arkanoid driver only) with placeholder ROMs.

**Not verified:**
- **The Swift, RealityKit and ARKit code has never been compiled.** No Mac
  and no Swift toolchain were available. The APIs are written from Apple's
  documentation for visionOS 2: `PointLightComponent`,
  `PhysicallyBasedMaterial.clearcoat`, `DragGesture.targetedToEntity`,
  `HandTrackingProvider`. Expect some compile fixes.
- **The libmame additions haven't been linked or run.** They were only
  syntax-checked, and `ios` OSD builds need a Mac. The same MAME calls do work
  from Lua in the e2e test.
- **Everything marked [game] in ARKANOID_STATE.md.** That covers the playfield
  offsets, how bricks, the Vaus, balls, capsules, enemies and lasers are
  recognised, and the high score address. These are educated heuristics built
  on the ROM's own graphics, and none has been checked against the real game.
- **The paddle loop's tuning.** It uses step limits and learns the
  pixels-per-count ratio, and the first time the override takes over, the
  Vaus might jump.
- Performance: decoding is cheap, well under a millisecond per frame by
  design, but it hasn't been measured on device. Frame pacing between 60 Hz
  emulation and 90 Hz rendering relies on easing and hasn't been checked for
  judder.

## Next steps

- Run a capture with a real ROM and fix the layout and heuristics. Then make
  the verified code tables the defaults, and add a real-ROM regression capture
  (kept locally, never committed) for `ark3d_dump`.
- Show the current score and lives: find them in work RAM from a capture, or
  read the digit tiles.
- More effects from diffing states: a flash and a sound-synced particle burst
  when silver bricks are hit (their tiles animate), a shockwave on the
  Disruption split, a glow trail on the ball, and the warp gate on the right
  wall ("B" capsule).
- Gold and silver brick shimmer; DOH (round 33, drawn in the tilemap) as a big
  3D model.
- Use the ROM's own graphics as textures, for example capsule letters and
  enemy sprites as decals. `ark3d_char_pen` plus the palette already decode
  them.
- Head-coupled parallax: tilt the table with the user's gaze in the arena.
- Save states tied to the scene (MAME already supports them for this driver).
