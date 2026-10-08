# Arkanoid Diorama (visionOS, experimental)

The first **diorama**: a per-game renderer that reads a running game's state
out of MAME every frame and draws its own 3D scene from it.

This is the **original arcade Arkanoid**, emulated exactly by MAME
(`src/mame/taito/arkanoid.cpp`), but shown as a 3D scene in RealityKit. It is
not a clone. MAME runs the real program, and every emulated frame the app reads
the video hardware's state and uses it to drive 3D objects:

- the background tilemap becomes bricks (bevelled, with depth; silver and gold ones are metallic)
- sprite RAM becomes the Vaus (metal body, red caps, stretches when enlarged), glowing balls with their own light, rolling colour-coded capsules, enemies and lasers
- the board stands upright like a monitor, with the 3D depth coming out toward you (`DIORAMA_BOARD=table` lays it down as a tilted table top instead); metal walls frame it on a gunmetal base, and bricks shatter into fragments when they break

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
| `Decoder/ark3d.{h,c}` | Portable C11 decoder. Raw videoram and spriteram bytes (plus the gfx and palette ROM regions) go in; a typed state comes out: brick grid, the Vaus (x, width, phase, laser), balls, capsules (S/C/L/E/D/B/P), enemies by type, lasers, the enemy hatches, spare lives, score and high score, and whether a round is on screen. |
| `ARKANOID_STATE.md` | The memory layout, with file:line references into MAME, and a note of which parts are exact and which are heuristics. |
| `Tests/` | `make -C visionos/dioramas/arkanoid/Tests` runs the unit tests over synthetic buffers on Linux or macOS. `run_e2e.sh` runs a plumbing test through a real MAME build. `ark3d_dump` decodes captures. |
| `lua/ark3d_capture.lua` | MAME Lua script. It records, every frame, exactly what the app reads, so the decoder can be checked offline against a real ROM. |
| `lua/ark3d_bot.lua` | Plays unattended (coins, start, steering through the same spinner override as the app), for captures. |
| `App/` | The SwiftUI and RealityKit app: control window, a volume, and an immersive "arena". `PlayfieldScene` builds the diorama from the decoded state; `Models` (Vaus, enemies, capsules, ball, banner), `Effects` and `RomArt` (the game's own background pattern for the floor, optional) feed it. `ReplayPlayer` plays a capture instead of MAME. |
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
cd visionos/dioramas/arkanoid
xcodegen
open ArkanoidDiorama.xcodeproj        # run the ArkanoidDiorama scheme on the visionOS simulator / device
```

Copy your ROM set (for example `arkanoid.zip`) into the app's **Documents/roms**
folder, using the Files app on the device or Finder file sharing. For the
simulator, use the app container's Documents folder
(`xcrun simctl get_app_container booted org.mamedev.diorama.arkanoid data`). Clones
such as `arkanoidj` also need the parent `arkanoid.zip`. A launch argument
picks the set, for example `xcrun simctl launch booted org.mamedev.diorama.arkanoid arkanoid`.

The app opens on the diorama's volume, straight into a game (`QuickStart`): round
1, the ball held on the Vaus, waiting for you. The first launch gets there by
running the game unthrottled and muted while it inserts a coin and presses start
(a few seconds), then saves that moment as a state (`Documents/sta/<set>/ready.sta`);
later launches load it. The game is held (paused) until you pinch, press Fire or
use a controller. **New game** above the board goes back to that moment; **Settings**
opens the control window (set, views, paddle control and sensitivity). With no ROM
set yet, the control window opens instead and says how to add one. This uses two
calls added to libmame: `myosd_save_state` / `myosd_load_state` and `MYOSD_THROTTLE`.

### Controls

| | |
|---|---|
| Left stick | move the Vaus. Settings → Stick: **Speed** (default; how far you push sets how fast, on a curve, so it's fine near the centre; full deflection crosses the field in about half a second) or **Position** (where you push is where it goes; back to the middle when let go) |
| D-pad | move the Vaus at a steady speed |
| A, RT or RB | fire (laser) / launch (catch) |
| Select (View / Share / Create) | insert coin |
| Start (Menu / Options) | 1 player start |
| Select + Start | MAME menu (the Home button is reserved by visionOS) |
| **Pinch & drag** | look at the field and pinch (launches / fires), then move your hand sideways: the Vaus moves from where it is, by the hand's movement times the sensitivity, like the arcade's spinner; let go and pinch again to keep going |
| **Hand** (arena only) | the Vaus follows your right index fingertip (ARKit hand tracking), scaled about the field's centre by the sensitivity; pinch your left hand to fire |
| **Buttons** | New game, Fire and Settings above the board (and Leave arena in the arena); Coin, Start and Fire in the control window, for playing without a controller |

The paddle is a relative spinner, so absolute control runs in a closed loop.
Each frame `PaddleController` compares the Vaus x (from sprite RAM) with the
target and writes a new spinner count through `myosd_set_analog_input`. It
measures the pixels-per-count ratio as you play. The stick is handled the same
way, as a target velocity, so MAME's own dial mapping and the override never
fight.

## Working on the look

Two environment variables make any moment of the game reproducible in the
simulator, without MAME or input (set them from a shell with the
`SIMCTL_CHILD_` prefix):

```sh
# copy a capture (ark3d_capture.lua output) into the app's Documents first
SIMCTL_CHILD_DIORAMA_REPLAY=cap.bin SIMCTL_CHILD_DIORAMA_REPLAY_FROM=7835 SIMCTL_CHILD_DIORAMA_REPLAY_HOLD=1 \
SIMCTL_CHILD_DIORAMA_CLOSEUP=1 xcrun simctl launch booted org.mamedev.diorama.arkanoid
xcrun simctl io booted screenshot shot.png          # or recordVideo, for motion
```

- `DIORAMA_REPLAY` plays the capture through the same decoder (`_FROM` picks
  the first frame, `_HOLD=1` stays on it).
- `DIORAMA_CLOSEUP=1` opens the arena with the table right in front of the
  viewer, where the simulator's camera sees all of it. `DIORAMA_POSE="y z
  pitch scale"` adjusts the placement.

## Testing without a Mac or a ROM

```sh
make -C visionos/dioramas/arkanoid/Tests test synth dump     # unit tests: 88 checks
make SOURCES=src/mame/taito/arkanoid.cpp -j8          # headless-capable Linux MAME, Arkanoid only
visionos/dioramas/arkanoid/Tests/run_e2e.sh ./mame           # plumbing test through that MAME
```

`run_e2e.sh` writes **placeholder** ROM files: zeros for the program, and
synthetic graphics and palette. MAME runs them with a checksum warning. The
Lua script injects a synthetic playfield into the real `:videoram` and
`:spriteram` shares, captures it, and `ark3d_dump` decodes the capture. This
proves the names, the format and the decoder path. It says nothing about the
real game, whose program never runs.

## Checking against the real game

The decoder's code tables (`ark3d_default_calibration`) were read off real
gameplay; `ARKANOID_STATE.md` §10 lists them. To capture more (for example
later rounds, gold bricks, DOH) with any desktop MAME:

```sh
# unattended: the bot inserts coins, plays badly, and steers like the app does
ARK3D_CAPTURE=visionos/dioramas/arkanoid/lua/ark3d_capture.lua ARK3D_OUT=cap.bin ARK3D_FRAMES=20000 \
  ./mame arkanoid -video none -sound none -nothrottle \
  -autoboot_script visionos/dioramas/arkanoid/lua/ark3d_bot.lua
# or play it yourself
ARK3D_OUT=cap.bin ./mame arkanoid -autoboot_script visionos/dioramas/arkanoid/lua/ark3d_capture.lua

make -C visionos/dioramas/arkanoid/Tests dump
visionos/dioramas/arkanoid/Tests/build/ark3d_dump cap.bin | less        # one line per frame
visionos/dioramas/arkanoid/Tests/build/ark3d_dump cap.bin -f 1500       # grid + tilemap codes + objects
visionos/dioramas/arkanoid/Tests/build/ark3d_dump cap.bin --codes       # which codes were decoded as what
```

Codes that show up as `other` in `--codes` aren't in the tables yet. Captures
contain the ROM's graphics, so keep them out of the repository.

`Documents/arkanoid-diorama.json` can add to or override the tables on a
device without rebuilding; `GameState.swift` loads it when a game starts:

```json
{
  "tiles":    { "0x17a": "gold", "0x17b": "gold" },
  "sprites":  { "0x1bb": "laser" },
  "capsules": { "0x1b0": "P" },
  "layout":   { "grid_rows": 18 }
}
```

Codes include the graphics bank: add 0x800 for tiles and 0x400 for sprites
when `gfxbank` is 1.

## What's verified and what isn't

**Verified (on a Mac, with the real `arkanoid` ROM set):**
- libmame, with the machine-state API, builds for the visionOS simulator, and
  the app builds with Xcode 27 and runs on the visionOS 26.5 simulator.
- The decoder against captures of rounds 1–27 (a sweep with
  `lua/ark3d_sweep.lua`), the attract demo, and bot play that caught B and D
  capsules: bricks (coloured, silver, gold), each round's background and
  shadows, walls, enemy hatches, the warp gate, the Vaus in all its forms,
  balls (Disruption's three too), capsule letters, four enemy types, laser
  shots, the round banner, spare lives, player and high score.
  ARKANOID_STATE.md §8–10 has the tables.
- The scene, by screenshots and recordings in the simulator: every element
  above as a 3D model or effect, including motion (bricks dropping in,
  breaking, the Vaus exploding, enemies destroyed, capsules rolling).
- The paddle loop, driven by `lua/ark3d_bot.lua` through the same analog
  override: about +1 px per count, stable over whole games.
- The decoder's unit tests (124 checks, synthetic data, `-Werror -Wconversion`).

**Not verified / deferred** (issues in the private twcclegg/mame-dioramas):
- DOH, round 33 (#1, lowest priority).
- On a Vision Pro: hand tracking, gestures, performance, scale (#6).

## Next steps

- Refine the enemy models against the game's sprites (the cube's colours,
  the pyramid's animation).
- More effects from diffing states: a sound-synced burst when silver bricks
  are hit, a shockwave on the Disruption split, the Vaus's catch (C) glow.
- Decide whether the floor keeps the ROM's background (see the private
  repo's licensing issues) or gets its own look.
- Head-coupled parallax: tilt the table with the user's gaze in the arena.
