# Arkanoid's game state, as seen from MAME's video hardware

How `Decoder/ark3d.c` gets a playfield out of the arcade Arkanoid's memory.
The references are to this tree. Two kinds of claim appear below, and they are
kept apart:

- **[driver]**: read directly off MAME's source for `taito/arkanoid.cpp`.
  This is how the hardware works, and it's exact.
- **[game]**: what the *game program* puts in that hardware: which tile is a
  gold brick, which sprite is the Vaus. None of that is in MAME's source. It
  lives in the ROMs. §10 lists what has been checked against captures of the
  real game (`lua/ark3d_bot.lua` + `lua/ark3d_capture.lua`); anything
  **[game]** that isn't there is still a heuristic.

## 1. Memory map [driver]

`arkanoid_state::arkanoid_map`, `src/mame/taito/arkanoid.cpp:833-848`:

| Z80 address | What | How the app reads it |
|---|---|---|
| `c000-c7ff` (mirrored at `c800`) | work RAM (`.ram().mirror(0x0800)`, :836) | `myosd_read_memory(":maincpu", MYOSD_AS_PROGRAM, 0xc000, …, 0x800)` |
| `d008` write | bank / flip / MCU-reset latch (:839, `arkanoid_d008_w`) | write-only, so via save items, see §4 |
| `e000-e7ff` | background tilemap RAM, share `"videoram"` (:844) | `myosd_get_memory_share(":videoram")` |
| `e800-e83f` | sprite RAM, share `"spriteram"` (:845) | `myosd_get_memory_share(":spriteram")` |
| `e840-efff` | more RAM (:846) | not used |

The shares are declared in `arkanoid.h:31-32`. The ROM regions are `"gfx1"`
(`0x18000` bytes, 3 bitplanes) and `"proms"` (`0x600`: R, G and B, 512 each),
at `arkanoid.cpp:1562-1570`.

## 2. Screen geometry [driver]

- `m_screen->set_raw(12_MHz_XTAL/2, 384, 0, 256, 264, 16, 240)` (`arkanoid.cpp:1371`):
  the raw frame is 256×224 visible, with x 0–255 and y 16–239.
- Every Arkanoid set is `ROT90` (`arkanoid.cpp:2329` ff.), and
  `ROT90 = ORIENTATION_SWAP_XY | ORIENTATION_FLIP_X` (`src/emu/emucore.h:176`).
  So raw pixel (x, y) is shown at **view (239 − y, x)**. The player sees
  224×256: raw x runs down the screen, and raw y runs right to left.
  (`ark3d_raw_to_view`.)

Everything the decoder outputs is in these **view pixels** (224×256, y down).

## 3. Background tilemap: bricks, walls, text [driver]

`video_start` (`arkanoid_v.cpp:170-173`) sets up a 32×32 tilemap of 8×8 tiles
with `TILEMAP_SCAN_ROWS`, so tile *i* is at raw (8·(i mod 32), 8·(i div 32)).
`get_bg_tile_info` (`arkanoid_v.cpp:161-168`) uses 2 bytes per tile:

```
byte 2i   : cccc c ccc    bits 7-3 colour (0-31), bits 2-0 code bits 10-8
byte 2i+1 : code bits 7-0
code   = byte1 + ((byte0 & 7) << 8) + 2048 * gfxbank        (0-4095)
colour = (byte0 >> 3) + 32 * palettebank                    (0-63)
```

In view order, view tile column *c* (0–27) and row *r* (0–31) are tilemap
index `(29 − c)·32 + r`. Tilemap rows 2–29 are the visible ones.

Inside a tile, view pixel (u, v) is char pixel (px = v, py = 7 − u).

Writes go through `arkanoid_videoram_w` (`arkanoid_v.cpp:15-19`), which only
marks the tile dirty. The RAM holds the whole picture, so reading the share is
enough.

**[game]** Bricks are 16×8 in the view (2 tiles side by side) and fill a 13-wide
grid between 8 px walls (13·16 = 208 = 224 − 2·8). That is the arcade game's
familiar geometry, but the exact offsets are assumptions: `ark3d_default_layout`
uses `grid_left = 8`, `grid_top = 24`, and two text rows plus a wall row above
the field. Which **tile codes** are bricks (and which colours, silver or gold),
walls, drop shadows or text is not in MAME's source. Without a calibration
table the decoder:
1. learns the **background** each frame from a band of the playfield that never
   holds bricks (`reference_top`–`reference_bottom`, y 208–223 by default). The
   background is a repeating pattern, so its tiles recur there;
2. calls a cell a **brick** when *every* tile of the cell is not background. A
   drop shadow darkens only part of a neighbouring cell. It also rejects cells
   whose mean colour is dark in every channel (max channel < 60), treating
   those as shadow;
3. takes the brick's **colour** from its left tile's most common pen, through
   the real palette (§5). This makes colours right with no code table.

It can't tell silver or gold bricks from white or yellow ones without a table.
It will also count text drawn over the field ("ROUND 1", "READY") as bricks
while that text is up. A calibration file fixes both (see README).

## 4. Banks and flip: the `d008` latch [driver]

`arkanoid_d008_w` (`arkanoid_v.cpp:21-60`):

| bit | meaning | driver member (save item) |
|---|---|---|
| 0, 1 | flip X, flip Y (cocktail, player 2) | `m_flip_screen_x/y` (`src/emu/driver.cpp:207-208`) |
| 2 | which spinner the MCU reads, P1 or P2 | `m_paddle_select` (and `input_mux_r`, `arkanoid_m.cpp:33-36`) |
| 3 | coin lockout | — |
| 5 | graphics bank (adds 2048 to tile codes, 1024 to sprite codes) | `m_gfxbank` |
| 6 | palette bank (adds 32 to colours) | `m_palettebank` |
| 7 | MCU reset | — |

The register is write-only, so no share holds it. The driver latches it into
members, which `machine_start` registers for save states
(`arkanoid.cpp:1334-1343`). `myosd_get_state_item(":", "m_gfxbank")` and the
Lua `manager.machine.devices[":"].items["0/m_gfxbank"]` both find them. The
e2e test confirmed all four names against a real build.

Flip is applied by the hardware at draw time: tilemap flip, and
`sx = 248 − sx` in `draw_sprites`. So RAM stays in the game's logical
orientation, and the decoder ignores flip for positions. **[game]** This
assumes the program doesn't also mirror its own writes in cocktail mode.

## 5. Graphics and palette [driver]

- `charlayout` (`arkanoid.cpp:1310-1319`): 4096 chars, 8×8, 3 bpp. The planes sit at
  bit offsets {2·4096·64, 4096·64, 0}, i.e. bytes `0x10000`, `0x8000`, `0`
  of gfx1. The first is the most significant, with 8 bytes per char and the
  MSB as the leftmost pixel. (`ark3d_char_pen`.)
- The palette is `PALETTE(..., RGB_444_PROMS, "proms", 512)` (`arkanoid.cpp:1377`), decoded by
  `palette_init_rgb_444_proms` (`src/emu/emupal.cpp:720`): entry *i* has R =
  `proms[i]`, G = `proms[i+512]`, B = `proms[i+1024]`, each nibble weighted
  `0x0e, 0x1f, 0x43, 0x8f`. Pen = colour·8 + pixel. For tiles pixel 0 is
  opaque; for sprites it's transparent (`transpen(..., 0)`).

`ark3d_analyze_graphics` decodes both once per game, from the user's own ROM
through `myosd_get_memory_region`. That's what lets the heuristics look at
shapes and real colours.

## 6. Sprites [driver]

`draw_sprites` (`arkanoid_v.cpp:175-203`) has 16 entries of 4 bytes
(`m_spriteram.bytes()` = 0x40):

```
byte 0 : sx  (raw x)
byte 1 : sy = 248 − byte1  (raw y of the lower half)
byte 2 : bits 7-3 colour, bits 1-0 code bits 9-8
byte 3 : code bits 7-0
code   = byte3 + ((byte2 & 3) << 8) + 1024 * gfxbank
colour = (byte2 >> 3) + 32 * palettebank
```

Each sprite is two chars, `2·code` at raw (sx, sy−8) and `2·code+1` at (sx, sy),
so 8×16 raw. **In the view that's 16 wide × 8 tall, with top-left at
(byte1 − 16, byte0)** (`ark3d_sprite_view_rect`). Inside it, view pixel
(u, v) is char `2·code + (u < 8 ? 1 : 0)`, px = v, py = (15 − u) & 7.

**[game]** Which sprite codes are what isn't in MAME. Without a table the
decoder uses geometry and the ROM graphics:

| Object | Heuristic |
|---|---|
| **Vaus** | the lowest row (y ≥ `vaus_min_y` = 200) holding ≥ 2 sprites at the same y. The Vaus is 32 px+ wide, so it's always several 16 px sprites, and its y is fixed during play. Position and width come from the union of their opaque pixels, so enlarged and shrinking forms come out right. "Laser" form needs a table. |
| **Ball** | a sprite whose opaque pixels form a small compact blob (≤ 24 px, bbox 2–7 × 2–7). Its centre is the blob's centre, not the cell's. |
| **Laser** | small, sparse (≤ 32 px, under half its bbox), at least 5 px tall. |
| **Enemy** | a large sprite (≥ 40 px) with another large one exactly 8 px above or below at the same x. Enemies are assumed to be 16×16 pairs, and the two halves are merged. |
| **Capsule** | a large sprite with no such partner, i.e. a single 16×8. Its type comes from its dominant colour, nearest of S orange, C green, L red, E blue, D cyan, B pink and P grey. |
| other | everything else (explosions, the Vaus's death animation, …) |

Parked or unused sprites are left out if their graphic is blank.

## 7. Inputs [driver]

- `PORT_START("P1") PORT_BIT(0xff, 0x00, IPT_DIAL) PORT_SENSITIVITY(30) PORT_KEYDELTA(15)`
  (`arkanoid.cpp:1063-1064`); P2 is the same with `PORT_COCKTAIL` (:1066-1067).
  It's an 8-bit wrapping spinner count, read by the 68705 MCU through
  `input_mux_r` (`arkanoid_m.cpp:33-36`). The MCU turns movement into the Vaus
  position.
- Fire is `BUTTONS` bit 0 (`IPT_BUTTON1`, :1029). `SYSTEM` holds START1/2 and
  COIN1/2 (:1008-1015).

MAME's defaults, with the `ios` OSD's additions (`src/osd/ios/input.cpp:504-509`),
already map the controller for this game: the stick X axis and hat left/right
drive the dial, A is button 1, Select is Coin 1 (`src/emu/inpttype.ipp:598`)
and Start is Start 1 (:586).

**Absolute paddle.** A spinner is relative, so the app owns the count.
`myosd_set_analog_input(":P1"/":P2", 0xff, n)` overrides the field's raw value
(`analog_field::set_value`, `src/emu/ioport.cpp:3821`). Each frame
`PaddleController` compares the Vaus x from sprite RAM with the target and
steps n. **[game]** How many pixels one count moves the Vaus is measured while
playing, not assumed, and it starts at +1 px per count.

## 8. Score [game, verified]

Both scores are 3 BCD bytes, most significant first, in units of 10 points:
the player's at `c4d7-c4d9`, the high score at `c4df-c4e1` (the 3 bytes
`plugins/hiscore/hiscore.dat` saves). So `00 27 00` at `c4d7` would be 2,700
points, and `00 50 00` at `c4df` is the default high score of 50,000. Checked
against the digit tiles in view row 1 over about 58,000 captured frames; the
only mismatches are the frame where the display lags RAM by one update.

## 9. Validation status

| What | Status |
|---|---|
| Formulas in §2–§6 against MAME's source | done (above) |
| Decoder on synthetic data | `make -C Tests`: 149 checks pass, `-Werror -Wconversion` |
| Share, region and save-item names, capture format, decoding through a real MAME build | `Tests/run_e2e.sh` (placeholder ROMs); and real captures, below |
| Codes, layout and scores against the real game | **done for rounds 1–2** (§10): about 36,000 frames of `arkanoid` (World) played by `lua/ark3d_bot.lua` on macOS MAME 0.289 |
| Rounds 3–32 | swept with a test script that clears each round (bricks-remaining counter `ed83` set to 0) and holds the lives bytes (`c006`, `e8a8`, `ed71`, `ed76`); 4 background patterns, gold bricks, no other new brick codes |
| Disruption (3 balls), the B warp gate | seen with `BOT_CATCH="B D"` (the bot chases those capsules) |
| DOH (round 33) | **done** (§11): fights captured with `lua/ark3d_doh.lua` (the sweep to round 33, then the bot), including a kill, the death sequence and the ending |

## 10. Verified codes [game, verified]

All in graphics bank 0 (the game; bank 1 is only used by the intro story).
`ark3d_default_calibration` holds these tables; a calibration file can
override them.

**Tiles**

| Codes | What |
|---|---|
| `000-0ff` | font: scores, "HIGH SCORE", title and high-score screens |
| `11e-129` | walls: the side walls (view columns 0 and 27) and the top wall (row 2). A round is on screen (`in_play`) only while both side walls are there; the game blanks them column by column when it wipes the playfield |
| `124-127` in row 2, columns 5–8 and 19–22 | the two enemy hatches, closed. Opening runs through `14a`, `14e`, `152`, `156`, `15a` (4 tiles each, 4 frames a step) and closes the same way back (`gate_open`) |
| `12a-149` in column 27, rows 27–31 | the warp gate (B capsule, `warp_open`): opening through `12a-12e`, `12f-133`, `134-13b`, then a frame (`13d` top, `13c` bottom) round an interior cycling `13e-149`: a lightning arc between two electrodes, three tiles per animation frame (`13e-140`, `141-143`, `147-149`; `144-146` unused), two frames each (`warp_phase` 0, 1, 3) |
| `710-719` | the attract demo's "GAME OVER" banner |
| `185`,`184` in row 31 from column 1 | a spare-life icon each (`spare_lives`): 2 at the start of a game, so 3 lives. The lives count isn't in work RAM (c000-c7ff): no byte there drops by one at each lost life |
| `15e-16d` | coloured bricks, pairs (left even, right odd): white, orange, cyan, green, red, blue, magenta, yellow |
| `16e-16f` | silver brick in colour `19`, **gold** (indestructible) in colour `1b` (from round 3). `170-179` are silver's shimmer and hit animations |
| round 1: `186-191` colour `1c`; round 2: `192-1a1` colour `1d` | background, a pattern 3 tiles wide and 4 rows tall. The same tiles in colour `05` / `06` are the drop shadow of the bricks and walls. The decoder learns each round's background from rows 26–29 (a full period, never any bricks) |

**Sprites** (every object also has a shadow copy, drawn in colour 8, whose
pens are all black, offset +4,+4 for the Vaus and +2,+2 for capsules)

| Codes | What |
|---|---|
| `0f2`,`0f3` | the Vaus, two sprites at y 232 (colour cycles `09-0c`) |
| `0be` | the enlarged Vaus's middle section (3 sprites, 48 px) |
| `0e8-0f1` | the Vaus materialising at the start of a life |
| `0f4-103` | turning into the laser Vaus; `104`,`105` the laser Vaus |
| `106-129` | the Vaus exploding (up to 3x3 sprites) |
| `12a-17f` | enemies: 2 stacked sprites (16x16), four types (`ark3d_enemy_type`), found by following each enemy's animation through the captures: molecule `12a-139` (8 frames), cube `146-159` (10, tumbling), pyramid `15a-16f` (11), cone `170-17f` (8). `13a-145` were never seen |
| `180-1b7` | capsules: 7 letters x 8 rotation frames, in the order S C L E D B P, so the letter is `(code - 0x180) / 8` |
| `1b8` | the ball |
| `1bd` | a laser shot, rising 5 px a frame |
| `1be-1c9` | an enemy destroyed |
| `1d8-1da`, `1ca-1d3`, `1de-1e0` | the round banner (`banner_round`, `banner_ready`): "ROUND" at x 80-112, y 176; the number's digits as `1ca` + digit, units at x 128 and tens at x 120 (from round 10); "READY" at y 192, about 30 frames later |

**Paddle.** The spinner moves the Vaus about +1 px per count (to the right),
measured by the bot through the same analog override the app uses.

## 11. DOH, round 33 [game, verified]

Checked on about 10,000 frames of fights, one of them to the kill, recorded
with `lua/ark3d_doh.lua`.

- **The round.** Its background (codes `3c2-471`, colour 16/17) is used by no
  other round. `ark3d_decode` checks view tile (6, 7) and reports no bricks
  in this round.
- **The face** is background tiles, an 8×12 block at view columns 10–17,
  rows 7–18 (view x 80–143, y 56–151), in colour 16. It doesn't move.
- **Mouth:** the whole block steps by `0x60` per stage. The top-left tile is
  `5ce` (closed), `62e`, `68e`, `6ee` (open), a step every 5 frames. DOH rests
  with the mouth open and closes it for about 60 frames at a time.
- **Hit:** the face is drawn in colour 31 for exactly one frame, and the
  score goes up 1000.
- **Hit count:** `ed6b`, which is in RAM at e840-efff, outside the c000-c7ff
  work RAM. No copy of it was found in c000-c7ff. **The game resets it to 0
  when the Vaus is lost**, so DOH has to be hit 16 times in one life. The
  16th hit destroys it.
- **Projectiles:** sprites `2b1-2bc` in colour 15, 12 animation frames about
  5 frames apart, with up to 4 on screen. They leave the mouth around view
  (110–118, 106) and fall towards the Vaus.
- **Death.** After the 16th hit:
  1. the face cycles through colours 2–6 and back, 5 frames each (about 45
     frames);
  2. it goes back to colour 16 and closes its mouth;
  3. it becomes a wireframe (codes `472-5d9`), in colour 7 and then fading
     through 24–27 (about 150 frames);
  4. the block is cleared to blank tiles (`20`) in colour 9, leaving a hole
     in the wall for about 460 frames;
  5. then comes the ending story screen, off the playfield (about 950
     frames).
  With the lives held (the test scripts), the game then starts round 33
  again.
- **Decoding** (`ark3d_state.doh`): phase ALIVE / DYING / GONE come from the
  face's top-left tile, and `mouth` from its stage. `flash` is colour 31.
  `hits` is read from `ed6b` when the input has `high_ram`. The decoder
  can't tell the ending screen from the intro story on its own; the
  exporter (`Tests/ark3d_export.c`) calls it ENDING when it follows DOH's
  hole.

