// license:BSD-3-Clause
//============================================================
//
//  ark3d.h - decode Arkanoid's video RAM into a typed game state
//
//  Portable C11, no MAME headers: the visionOS app imports it
//  into Swift (bridging header) and Tests/ builds it on Linux.
//
//  Input: the raw bytes MAME's taito/arkanoid.cpp driver draws
//  from (videoram share, spriteram share, and optionally the
//  gfx1 / proms ROM regions plus the gfx/palette bank and flip
//  latches).  Output: a playfield in the player's (rotated,
//  224x256) view: brick grid, Vaus, balls, capsules, enemies,
//  lasers.  See ARKANOID_STATE.md for the memory layout and
//  which parts are derived from MAME's source vs. heuristics
//  that still need checking against a real ROM.
//
//============================================================

#ifndef ARK3D_H
#define ARK3D_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

//------------------------------------------------------------
//  hardware constants (from src/mame/taito/arkanoid*.cpp)
//------------------------------------------------------------

#define ARK3D_VIDEORAM_BYTES   0x800    // e000-e7ff: 32x32 tiles, 2 bytes each
#define ARK3D_SPRITERAM_BYTES  0x40     // e800-e83f: 16 sprites, 4 bytes each
#define ARK3D_NUM_SPRITES      16
#define ARK3D_GFX_BYTES        0x18000  // gfx1: 4096 8x8 chars, 3 bitplanes of 0x8000
#define ARK3D_PROM_BYTES       0x600    // proms: 512 entries x R,G,B nibbles
#define ARK3D_NUM_CHARS        4096
#define ARK3D_NUM_PENS         512      // 64 colour groups x 8 pens

// the player's view (the game is ROT90): 224 wide, 256 tall, y down
#define ARK3D_VIEW_W           224
#define ARK3D_VIEW_H           256
#define ARK3D_VIEW_COLS        28       // view tile columns (8 px)
#define ARK3D_VIEW_ROWS        32       // view tile rows

#define ARK3D_MAX_GRID_COLS    16
#define ARK3D_MAX_GRID_ROWS    32
#define ARK3D_MAX_BALLS        8
#define ARK3D_MAX_OBJECTS      16

//------------------------------------------------------------
//  classification
//------------------------------------------------------------

// what a tile or sprite code is; used both for the (optional)
// calibration tables and for decoded objects
typedef enum {
    ARK3D_KIND_UNKNOWN = 0,     // not calibrated: use the heuristics
    ARK3D_KIND_BACKGROUND,
    ARK3D_KIND_SHADOW,          // brick drop shadow
    ARK3D_KIND_WALL,
    ARK3D_KIND_BRICK,           // coloured brick (colour from the graphics)
    ARK3D_KIND_BRICK_SILVER,    // takes several hits
    ARK3D_KIND_BRICK_GOLD,      // indestructible
    ARK3D_KIND_TEXT,
    ARK3D_KIND_VAUS,            // sprite kinds from here on
    ARK3D_KIND_VAUS_LASER,
    ARK3D_KIND_BALL,
    ARK3D_KIND_CAPSULE,
    ARK3D_KIND_ENEMY,
    ARK3D_KIND_LASER,
    ARK3D_KIND_EXPLOSION,
    ARK3D_KIND_OTHER,
    ARK3D_KIND_VAUS_APPEARING,  // the Vaus materialising at the start of a life
    ARK3D_KIND_VAUS_EXPLODING,  // the Vaus blowing up after losing the ball
    ARK3D_KIND_COUNT
} ark3d_kind;

// what the Vaus is doing (ark3d_state.vaus_phase)
typedef enum {
    ARK3D_VAUS_NONE = 0,        // not on screen
    ARK3D_VAUS_NORMAL,
    ARK3D_VAUS_APPEARING,
    ARK3D_VAUS_EXPLODING
} ark3d_vaus_phase;

// power-up capsules, identified by their colour
typedef enum {
    ARK3D_CAPSULE_UNKNOWN = 0,
    ARK3D_CAPSULE_S,            // slow        (orange)
    ARK3D_CAPSULE_C,            // catch       (green)
    ARK3D_CAPSULE_L,            // laser       (red)
    ARK3D_CAPSULE_E,            // enlarge     (blue)
    ARK3D_CAPSULE_D,            // disruption  (cyan)
    ARK3D_CAPSULE_B,            // break       (pink)
    ARK3D_CAPSULE_P,            // player/1-up (grey)
    ARK3D_CAPSULE_COUNT
} ark3d_capsule;

// enemy types, by their sprite frames (ark3d_enemy_type)
typedef enum {
    ARK3D_ENEMY_UNKNOWN = 0,
    ARK3D_ENEMY_MOLECULE,       // three balls
    ARK3D_ENEMY_CUBE,
    ARK3D_ENEMY_SPHERE,
    ARK3D_ENEMY_PYRAMID,
    ARK3D_ENEMY_CONE
} ark3d_enemy;

// exact tables by code.  ark3d_default_calibration fills in the codes
// verified against captures of the real game (see ARKANOID_STATE.md); a
// calibration file can add to or override them.  UNKNOWN entries fall
// back to the heuristics.
typedef struct {
    uint8_t tile_kind[ARK3D_NUM_CHARS];         // by tile code (incl. gfx bank: +2048)
    uint8_t sprite_kind[ARK3D_NUM_CHARS / 2];   // by sprite code (incl. gfx bank: +1024)
    uint8_t sprite_capsule[ARK3D_NUM_CHARS / 2];// ark3d_capsule, for CAPSULE sprites
} ark3d_calibration;

//------------------------------------------------------------
//  layout of the playfield in view pixels.  Defaults are from
//  the arcade game's known geometry (13 bricks of 16x8 between
//  8 px walls); ark3d_default_layout documents each value, and
//  every one of them is a guess until checked on a real ROM.
//------------------------------------------------------------

typedef struct {
    int field_left, field_right;    // inner playfield edges (x), walls outside
    int field_top;                  // inner top edge (y), wall above
    int field_bottom;               // bottom of the view where the ball is lost
    int grid_left, grid_top;        // top-left of brick cell (0,0)
    int grid_cols, grid_rows;
    int brick_w, brick_h;
    int reference_top, reference_bottom;    // y band always free of bricks,
                                            // used to learn background tiles
    int vaus_min_y;                 // a sprite row this low (or lower) can be the Vaus
} ark3d_layout;

//------------------------------------------------------------
//  input
//------------------------------------------------------------

typedef struct {
    const uint8_t *videoram;        // ARK3D_VIDEORAM_BYTES, required
    const uint8_t *spriteram;       // ARK3D_SPRITERAM_BYTES, required
    int gfxbank;                    // d008 bit 5 (driver: m_gfxbank)
    int palettebank;                // d008 bit 6 (driver: m_palettebank)
    int flip_x, flip_y;             // d008 bits 0,1 (cocktail); informational
    const uint8_t *work_ram;        // optional: c000-c7ff (2 KB), for the scores
    size_t work_ram_bytes;
} ark3d_input;

//------------------------------------------------------------
//  graphics analysis: built once from the ROM regions
//------------------------------------------------------------

typedef struct {
    uint8_t opaque;                 // non-zero pixels (0-64)
    uint8_t dominant_pen;           // most common non-zero pen (1-7), 0 if blank
    uint8_t pen_count[8];
} ark3d_char_info;

typedef struct {
    int valid;                      // gfx and proms were supplied
    uint8_t rgb[ARK3D_NUM_PENS][3]; // decoded palette (RGB_444_PROMS)
    ark3d_char_info chars[ARK3D_NUM_CHARS];
    // per sprite code (16x8 in view space): opaque pixel count and bounding box
    struct {
        uint8_t opaque;
        int8_t x0, y0, x1, y1;      // inclusive, view space within the 16x8 cell; x0>x1 if blank
    } sprites[ARK3D_NUM_CHARS / 2];
} ark3d_graphics;

//------------------------------------------------------------
//  output
//------------------------------------------------------------

typedef struct {
    uint8_t kind;                   // ark3d_kind (BRICK / BRICK_SILVER / BRICK_GOLD), 0 = empty
    uint8_t rgb[3];                 // representative colour (from the graphics, or a
                                    // colour-attribute guess without them)
    uint16_t code;                  // tile code of the left half (for calibration)
    uint8_t color;                  // colour attribute of the left half
} ark3d_brick;

typedef struct {
    float x, y;                     // centre, view pixels
    float w, h;                     // size, view pixels
    uint8_t kind;                   // ark3d_kind
    uint8_t capsule;                // ark3d_capsule, for CAPSULE
    uint8_t rgb[3];
    uint8_t sprite;                 // sprite slot (0-15) of the first sprite
    uint16_t code;                  // sprite code (incl. bank)
    uint8_t color;
} ark3d_object;

typedef struct {
    // background tilemap, in view order ([row][col]): code and colour
    uint16_t tile_code[ARK3D_VIEW_ROWS][ARK3D_VIEW_COLS];
    uint8_t  tile_color[ARK3D_VIEW_ROWS][ARK3D_VIEW_COLS];
    uint8_t  tile_kind[ARK3D_VIEW_ROWS][ARK3D_VIEW_COLS];   // BACKGROUND or UNKNOWN (non-background)
                                                            // unless calibrated

    // bricks
    int grid_cols, grid_rows;
    ark3d_brick bricks[ARK3D_MAX_GRID_ROWS][ARK3D_MAX_GRID_COLS];
    int brick_count;                // bricks that can still be broken (not gold)

    // Vaus
    int vaus_visible;
    float vaus_x, vaus_y;           // centre
    float vaus_w, vaus_h;
    int vaus_laser;                 // only from calibration
    int vaus_phase;                 // ark3d_vaus_phase

    ark3d_object balls[ARK3D_MAX_BALLS];
    int ball_count;
    ark3d_object objects[ARK3D_MAX_OBJECTS];    // capsules, enemies, lasers, other
    int object_count;

    int in_play;                    // a round's playfield is on screen (not the title,
                                    // high-score or intro screens); bricks are only
                                    // decoded then
    int flipped;                    // screen flipped for player 2 in cocktail mode
    int score;                      // player's score, -1 if unknown (no work RAM)
    int high_score;                 // -1 if unknown
} ark3d_state;

//------------------------------------------------------------
//  functions
//------------------------------------------------------------

void ark3d_default_layout(ark3d_layout *layout);

// the codes verified against the real game (graphics bank 0), plus the
// intro sequence's bank-1 sprites as OTHER
void ark3d_default_calibration(ark3d_calibration *calibration);

// decode the gfx1 and proms regions (either may be NULL: then valid=0)
void ark3d_analyze_graphics(ark3d_graphics *graphics, const uint8_t *gfx, size_t gfx_bytes,
                            const uint8_t *proms, size_t prom_bytes);

// pen colour of pixel (px,py) of 8x8 char `code` (0 = transparent)
int ark3d_char_pen(const uint8_t *gfx, int code, int px, int py);

// Decode one frame.  graphics and calibration may be NULL.  Returns 0, or
// -1 if the input is missing.
int ark3d_decode(const ark3d_input *input, const ark3d_layout *layout,
                 const ark3d_graphics *graphics, const ark3d_calibration *calibration,
                 ark3d_state *state);

// Map between raw hardware (unrotated 256x256 tilemap space) and view
// coordinates.  Exposed for tests and the debug overlay.
void ark3d_raw_to_view(int raw_x, int raw_y, int *view_x, int *view_y);
void ark3d_sprite_view_rect(const uint8_t *sprite4, int *x, int *y);   // 16x8 at (x,y)

int ark3d_enemy_type(uint16_t sprite_code);        // ark3d_enemy
const char *ark3d_kind_name(int kind);
const char *ark3d_capsule_name(int capsule);

// accessors for Swift, which imports the fixed-size arrays above as tuples
static inline const ark3d_brick *ark3d_brick_at(const ark3d_state *s, int row, int col)
{
    return (row >= 0 && row < ARK3D_MAX_GRID_ROWS && col >= 0 && col < ARK3D_MAX_GRID_COLS) ? &s->bricks[row][col] : NULL;
}
static inline const ark3d_object *ark3d_ball_at(const ark3d_state *s, int i)
{
    return (i >= 0 && i < s->ball_count) ? &s->balls[i] : NULL;
}
static inline uint16_t ark3d_tile_code_at(const ark3d_state *s, int row, int col)
{
    return (row >= 0 && row < ARK3D_VIEW_ROWS && col >= 0 && col < ARK3D_VIEW_COLS) ? s->tile_code[row][col] : 0;
}
static inline uint8_t ark3d_tile_color_at(const ark3d_state *s, int row, int col)
{
    return (row >= 0 && row < ARK3D_VIEW_ROWS && col >= 0 && col < ARK3D_VIEW_COLS) ? s->tile_color[row][col] : 0;
}
static inline const ark3d_object *ark3d_object_at(const ark3d_state *s, int i)
{
    return (i >= 0 && i < s->object_count) ? &s->objects[i] : NULL;
}

#if defined(__cplusplus)
}
#endif

#endif // ARK3D_H
