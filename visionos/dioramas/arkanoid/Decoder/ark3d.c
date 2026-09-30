// license:BSD-3-Clause
//============================================================
//
//  ark3d.c - decode Arkanoid's video RAM into a typed game state
//
//  See ark3d.h and ARKANOID_STATE.md.  Every formula marked
//  [driver] is taken from src/mame/taito/arkanoid_v.cpp or
//  arkanoid.cpp; everything marked [heuristic] is a guess about
//  the game's graphics that needs checking against a real ROM.
//
//============================================================

#include "ark3d.h"

#include <string.h>

//------------------------------------------------------------
//  coordinate mapping
//------------------------------------------------------------

// [driver] screen: set_raw(..., 384, 0, 256, 264, 16, 240): 256x224 visible
// (raw y 16-239), game is ROT90.  ROT90 = SWAP_XY | FLIP_X, so raw pixel
// (x,y) lands at view (239 - y, x): raw x runs down the view, raw y runs
// right-to-left.
void ark3d_raw_to_view(int raw_x, int raw_y, int *view_x, int *view_y)
{
    *view_x = 239 - raw_y;
    *view_y = raw_x;
}

// [driver] draw_sprites: sx = ram[0], sy = 248 - ram[1]; char 2*code at
// raw (sx, sy-8), char 2*code+1 at (sx, sy).  So the sprite covers raw x
// [sx, sx+8), raw y [240-ram[1], 256-ram[1]): in the view, 16 wide x 8 tall
// at (ram[1]-16, ram[0]).
void ark3d_sprite_view_rect(const uint8_t *sprite4, int *x, int *y)
{
    *x = sprite4[1] - 16;
    *y = sprite4[0];
}

// view tile (col 0-27, row 0-31) -> tilemap index.  [driver] TILEMAP_SCAN_ROWS,
// 32x32 of 8x8: tile index = row*32 + col at raw (col*8, row*8).  View row r
// is tilemap column r; view column c is tilemap row 29-c (raw y 16-239 are
// tilemap rows 2-29).
static int view_tile_index(int col, int row)
{
    return (29 - col) * 32 + row;
}

//------------------------------------------------------------
//  graphics
//------------------------------------------------------------

// [driver] charlayout: 8x8, 4096 chars, 3bpp, planes at bit offsets
// {2*4096*64, 4096*64, 0} (first is the most significant), x offsets 0-7
// (MSB first within a byte), 8 bytes per char.
int ark3d_char_pen(const uint8_t *gfx, int code, int px, int py)
{
    size_t const row = (size_t)(code & (ARK3D_NUM_CHARS - 1)) * 8 + (size_t)py;
    int const bit = 7 - px;
    int const p0 = (gfx[0x10000 + row] >> bit) & 1;
    int const p1 = (gfx[0x08000 + row] >> bit) & 1;
    int const p2 = (gfx[0x00000 + row] >> bit) & 1;
    return (p0 << 2) | (p1 << 1) | p2;
}

// [driver] PALETTE(..., RGB_444_PROMS, "proms", 512): emupal.cpp
// palette_init_rgb_444_proms, weights 0x0e/0x1f/0x43/0x8f per bit.
static uint8_t prom_level(uint8_t nibble)
{
    return (uint8_t)(0x0e * ((nibble >> 0) & 1) + 0x1f * ((nibble >> 1) & 1) +
                     0x43 * ((nibble >> 2) & 1) + 0x8f * ((nibble >> 3) & 1));
}

void ark3d_analyze_graphics(ark3d_graphics *g, const uint8_t *gfx, size_t gfx_bytes,
                            const uint8_t *proms, size_t prom_bytes)
{
    memset(g, 0, sizeof(*g));
    if (gfx == NULL || gfx_bytes < ARK3D_GFX_BYTES || proms == NULL || prom_bytes < ARK3D_PROM_BYTES)
        return;

    for (int i = 0; i < ARK3D_NUM_PENS; i++)
    {
        g->rgb[i][0] = prom_level(proms[i]);
        g->rgb[i][1] = prom_level(proms[i + ARK3D_NUM_PENS]);
        g->rgb[i][2] = prom_level(proms[i + 2 * ARK3D_NUM_PENS]);
    }

    for (int code = 0; code < ARK3D_NUM_CHARS; code++)
    {
        ark3d_char_info *ci = &g->chars[code];
        for (int py = 0; py < 8; py++)
            for (int px = 0; px < 8; px++)
                ci->pen_count[ark3d_char_pen(gfx, code, px, py)]++;
        ci->opaque = (uint8_t)(64 - ci->pen_count[0]);
        int best = 0;
        for (int pen = 1; pen < 8; pen++)
            if (ci->pen_count[pen] > (best ? ci->pen_count[best] : 0))
                best = pen;
        ci->dominant_pen = (uint8_t)best;
    }

    // sprites in view space: view (u,v), u 0-15 across, v 0-7 down.  From
    // ark3d_sprite_view_rect: u covers raw y offset 15-u; offsets 0-7 are
    // char 2*code, 8-15 char 2*code+1; raw x offset (char px) is v.
    for (int code = 0; code < ARK3D_NUM_CHARS / 2; code++)
    {
        int count = 0, x0 = 16, y0 = 8, x1 = -1, y1 = -1;
        for (int u = 0; u < 16; u++)
        {
            int const off = 15 - u;
            int const ch = 2 * code + (off >= 8 ? 1 : 0);
            for (int v = 0; v < 8; v++)
            {
                if (ark3d_char_pen(gfx, ch, v, off & 7) == 0)
                    continue;
                count++;
                if (u < x0) x0 = u;
                if (u > x1) x1 = u;
                if (v < y0) y0 = v;
                if (v > y1) y1 = v;
            }
        }
        g->sprites[code].opaque = (uint8_t)count;
        g->sprites[code].x0 = (int8_t)x0;
        g->sprites[code].y0 = (int8_t)y0;
        g->sprites[code].x1 = (int8_t)x1;
        g->sprites[code].y1 = (int8_t)y1;
    }
    g->valid = 1;
}

//------------------------------------------------------------
//  layout
//------------------------------------------------------------

void ark3d_default_layout(ark3d_layout *l)
{
    // [heuristic] arcade Arkanoid: 224 px wide view, 8 px side walls, 13
    // bricks of 16x8 between them (13*16 = 208 = 224 - 2*8); two text rows
    // (1UP / HIGH SCORE and the scores) and an 8 px wall above the field.
    l->field_left = 8;
    l->field_right = 216;
    l->field_top = 24;
    l->field_bottom = ARK3D_VIEW_H;
    l->grid_left = 8;
    l->grid_top = 24;
    l->grid_cols = 13;
    l->grid_rows = 22;          // down to y=200; later rounds reach about 18 rows
    l->brick_w = 16;
    l->brick_h = 8;
    // [game] rows 26-29 (y 208-239) never hold bricks and cover a whole
    // period of every round's background pattern (it repeats every 4 rows)
    l->reference_top = 208;
    l->reference_bottom = 240;
    l->vaus_min_y = 224;        // [game] the Vaus's sprites sit at y 232
}

//------------------------------------------------------------
//  calibration verified against the real game
//------------------------------------------------------------

static void fill(uint8_t *table, int first, int last, int value)
{
    for (int code = first; code <= last; code++)
        table[code] = (uint8_t)value;
}

// [game] all graphics bank 0 (the game itself); read off captures of
// arkanoid (World) with visionos/dioramas/arkanoid/lua/ark3d_capture.lua and the
// ROM's own graphics.  See ARKANOID_STATE.md, "Verified codes".
void ark3d_default_calibration(ark3d_calibration *cal)
{
    memset(cal, 0, sizeof(*cal));

    // tiles: the eight coloured bricks are pairs (left even, right odd)
    // 15e-16d: white, orange, cyan, green, red, blue, magenta, yellow.
    // Silver is 16e/16f; 170-179 are its shimmer and hit animations.
    // Gold is the silver tiles in colour 1b (see ark3d_decode).
    // Each round's background is learned (see ark3d_decode).
    fill(cal->tile_kind, 0x000, 0x0ff, ARK3D_KIND_TEXT);            // the font, scores
    fill(cal->tile_kind, 0x710, 0x719, ARK3D_KIND_TEXT);            // the attract demo's "GAME OVER" banner
    fill(cal->tile_kind, 0x11e, 0x129, ARK3D_KIND_WALL);            // side walls and the top wall
    fill(cal->tile_kind, 0x12a, 0x149, ARK3D_KIND_WALL);            // the warp gate (see warp_open)
    fill(cal->tile_kind, 0x14a, 0x15d, ARK3D_KIND_WALL);            // enemy hatches opening (see gate_open)
    fill(cal->tile_kind, 0x184, 0x185, ARK3D_KIND_TEXT);            // spare-life icons (see spare_lives)
    fill(cal->tile_kind, 0x15e, 0x16d, ARK3D_KIND_BRICK);
    fill(cal->tile_kind, 0x16e, 0x179, ARK3D_KIND_BRICK_SILVER);

    // sprites
    // sprites.  The Vaus is 2 sprites at y 232 (3 when enlarged, with 0be
    // in the middle); every object also has a shadow copy in colour 8.
    fill(cal->sprite_kind, 0x0be, 0x0be, ARK3D_KIND_VAUS);          // enlarged Vaus, middle section
    fill(cal->sprite_kind, 0x0e8, 0x0f1, ARK3D_KIND_VAUS_APPEARING);
    fill(cal->sprite_kind, 0x0f2, 0x0f3, ARK3D_KIND_VAUS);
    fill(cal->sprite_kind, 0x0f4, 0x103, ARK3D_KIND_VAUS);          // turning into the laser Vaus
    fill(cal->sprite_kind, 0x104, 0x105, ARK3D_KIND_VAUS_LASER);
    fill(cal->sprite_kind, 0x106, 0x129, ARK3D_KIND_VAUS_EXPLODING);
    fill(cal->sprite_kind, 0x12a, 0x17f, ARK3D_KIND_ENEMY);         // 2 stacked sprites; see ark3d_enemy_type
    fill(cal->sprite_kind, 0x180, 0x1b7, ARK3D_KIND_CAPSULE);       // 7 letters x 8 rotation frames
    fill(cal->sprite_kind, 0x1b8, 0x1b8, ARK3D_KIND_BALL);
    fill(cal->sprite_kind, 0x1bd, 0x1bd, ARK3D_KIND_LASER);         // a shot, rising 5 px a frame
    fill(cal->sprite_kind, 0x1be, 0x1c9, ARK3D_KIND_EXPLOSION);     // an enemy destroyed
    fill(cal->sprite_kind, 0x1ca, 0x1d3, ARK3D_KIND_TEXT);          // "ROUND n": its digits 0-9 (see banner_round)
    fill(cal->sprite_kind, 0x1d4, 0x1e0, ARK3D_KIND_TEXT);
    fill(cal->sprite_kind, 0x2b1, 0x2bc, ARK3D_KIND_DOH_SHOT);      // DOH's projectile, 12 animation frames
    fill(cal->sprite_kind, 0x400, 0x7ff, ARK3D_KIND_OTHER);         // bank 1: the intro story

    // capsule letters in the order of ark3d_capsule: S C L E D B P
    for (int code = 0x180; code <= 0x1b7; code++)
        cal->sprite_capsule[code] = (uint8_t)(ARK3D_CAPSULE_S + (code - 0x180) / 8);
}

//------------------------------------------------------------
//  helpers
//------------------------------------------------------------

typedef struct {
    uint32_t keys[256];
    int count;
} key_set;

static uint32_t tile_key(uint16_t code, uint8_t color) { return (uint32_t)code | ((uint32_t)color << 12); }

static int set_has(const key_set *s, uint32_t k)
{
    for (int i = 0; i < s->count; i++)
        if (s->keys[i] == k)
            return 1;
    return 0;
}

static void set_add(key_set *s, uint32_t k)
{
    if (s->count < (int)(sizeof(s->keys) / sizeof(s->keys[0])) && !set_has(s, k))
        s->keys[s->count++] = k;
}

static void pen_rgb(const ark3d_graphics *g, int color, int pen, uint8_t rgb[3])
{
    const uint8_t *c = g->rgb[((color & 63) * 8 + (pen & 7)) & (ARK3D_NUM_PENS - 1)];
    rgb[0] = c[0]; rgb[1] = c[1]; rgb[2] = c[2];
}

// average colour over all 64 pixels of a background tile (pen 0 is opaque in the tilemap)
static void tile_mean_rgb(const ark3d_graphics *g, uint16_t code, uint8_t color, int rgb[3])
{
    const ark3d_char_info *ci = &g->chars[code & (ARK3D_NUM_CHARS - 1)];
    int sum[3] = {0, 0, 0};
    for (int pen = 0; pen < 8; pen++)
    {
        uint8_t c[3];
        pen_rgb(g, color, pen, c);
        for (int k = 0; k < 3; k++)
            sum[k] += c[k] * ci->pen_count[pen];
    }
    for (int k = 0; k < 3; k++)
        rgb[k] = sum[k] / 64;
}

// without graphics: a fixed hue per colour attribute so bricks still differ
static void fallback_rgb(uint8_t color, uint8_t rgb[3])
{
    static const uint8_t hues[8][3] = {
        {240,240,240}, {255,128,0}, {0,200,255}, {0,200,0}, {220,0,0}, {0,64,255}, {255,64,200}, {255,220,0}
    };
    const uint8_t *h = hues[color & 7];
    rgb[0] = h[0]; rgb[1] = h[1]; rgb[2] = h[2];
}

// [game] shadow sprites use a colour whose pens are all black (colour 8 in
// the game's palette); without the palette, assume colour 8
static int is_shadow_color(const ark3d_graphics *g, uint8_t color)
{
    if (g == NULL)
        return (color & 31) == 8;
    for (int pen = 1; pen < 8; pen++)
    {
        uint8_t rgb[3];
        pen_rgb(g, color, pen, rgb);
        if (rgb[0] | rgb[1] | rgb[2])
            return 0;
    }
    return 1;
}

static int calibrated_tile_kind(const ark3d_calibration *cal, uint16_t code)
{
    return cal ? cal->tile_kind[code & (ARK3D_NUM_CHARS - 1)] : ARK3D_KIND_UNKNOWN;
}

static int calibrated_sprite_kind(const ark3d_calibration *cal, uint16_t code)
{
    return cal ? cal->sprite_kind[code & (ARK3D_NUM_CHARS / 2 - 1)] : ARK3D_KIND_UNKNOWN;
}

// [heuristic] capsule colours as seen in the game: S orange, C green,
// L red, E blue, D cyan, B pink, P grey
static int nearest_capsule(const uint8_t rgb[3])
{
    static const uint8_t ref[ARK3D_CAPSULE_COUNT][3] = {
        {0,0,0}, {255,140,0}, {0,200,0}, {220,0,0}, {0,64,255}, {0,210,255}, {255,80,200}, {170,170,170}
    };
    int best = ARK3D_CAPSULE_UNKNOWN, bestd = 0x7fffffff;
    for (int i = 1; i < ARK3D_CAPSULE_COUNT; i++)
    {
        int d = 0;
        for (int k = 0; k < 3; k++)
        {
            int const e = (int)rgb[k] - (int)ref[i][k];
            d += e * e;
        }
        if (d < bestd) { bestd = d; best = i; }
    }
    return best;
}

static int is_vaus_kind(int kind)
{
    return kind == ARK3D_KIND_VAUS || kind == ARK3D_KIND_VAUS_LASER ||
           kind == ARK3D_KIND_VAUS_APPEARING || kind == ARK3D_KIND_VAUS_EXPLODING;
}

typedef struct {
    int used;
    int slot;
    int x, y;                       // view rect top-left (16x8)
    uint16_t code;
    uint8_t color;
    int kind;                       // calibrated kind, or UNKNOWN
} sprite_entry;

// dominant non-transparent colour of a sprite (both chars)
static void sprite_rgb(const ark3d_graphics *g, const sprite_entry *s, uint8_t rgb[3])
{
    if (g == NULL || !g->valid)
    {
        fallback_rgb(s->color, rgb);
        return;
    }
    int counts[8] = {0};
    for (int half = 0; half < 2; half++)
    {
        const ark3d_char_info *ci = &g->chars[(2 * s->code + half) & (ARK3D_NUM_CHARS - 1)];
        for (int pen = 1; pen < 8; pen++)
            counts[pen] += ci->pen_count[pen];
    }
    int best = 1;
    for (int pen = 2; pen < 8; pen++)
        if (counts[pen] > counts[best])
            best = pen;
    pen_rgb(g, s->color, best, rgb);
}

// opaque bounding box of a sprite in view pixels; falls back to the full cell
static void sprite_bounds(const ark3d_graphics *g, const sprite_entry *s, float *x0, float *y0, float *x1, float *y1)
{
    if (g != NULL && g->valid && g->sprites[s->code].opaque > 0)
    {
        *x0 = (float)(s->x + g->sprites[s->code].x0);
        *y0 = (float)(s->y + g->sprites[s->code].y0);
        *x1 = (float)(s->x + g->sprites[s->code].x1 + 1);
        *y1 = (float)(s->y + g->sprites[s->code].y1 + 1);
    }
    else
    {
        *x0 = (float)s->x;
        *y0 = (float)s->y;
        *x1 = (float)(s->x + 16);
        *y1 = (float)(s->y + 8);
    }
}

static void set_object(ark3d_object *o, const ark3d_graphics *g, const sprite_entry *s, int kind)
{
    float x0, y0, x1, y1;
    sprite_bounds(g, s, &x0, &y0, &x1, &y1);
    memset(o, 0, sizeof(*o));
    o->x = (x0 + x1) * 0.5f;
    o->y = (y0 + y1) * 0.5f;
    o->w = x1 - x0;
    o->h = y1 - y0;
    o->kind = (uint8_t)kind;
    o->sprite = (uint8_t)s->slot;
    o->code = s->code;
    o->color = s->color;
    sprite_rgb(g, s, o->rgb);
}

// 6 BCD digits x 10 points at work RAM offset `at`, or -1 if unreadable
static int read_score(const ark3d_input *in, size_t at)
{
    if (in->work_ram == NULL || in->work_ram_bytes < at + 3)
        return -1;
    int value = 0;
    for (size_t i = 0; i < 3; i++)
    {
        int const hi = in->work_ram[at + i] >> 4, lo = in->work_ram[at + i] & 15;
        if (hi > 9 || lo > 9)
            return -1;
        value = value * 100 + hi * 10 + lo;
    }
    return value * 10;
}

//------------------------------------------------------------
//  ark3d_decode
//------------------------------------------------------------

int ark3d_decode(const ark3d_input *in, const ark3d_layout *layout_in,
                 const ark3d_graphics *g, const ark3d_calibration *cal, ark3d_state *st)
{
    if (in == NULL || in->videoram == NULL || in->spriteram == NULL || st == NULL)
        return -1;
    if (g != NULL && !g->valid)
        g = NULL;

    ark3d_layout layout;
    if (layout_in)
        layout = *layout_in;
    else
        ark3d_default_layout(&layout);

    memset(st, 0, sizeof(*st));
    st->flipped = (in->flip_x || in->flip_y) ? 1 : 0;

    // ---- tilemap in view order.  [driver] get_bg_tile_info:
    // code = ram[2i+1] + ((ram[2i] & 7) << 8) + 2048*gfxbank,
    // color = (ram[2i] >> 3) + 32*palettebank.  Flip is applied by the
    // hardware at draw time, so RAM is already in the logical orientation.
    for (int r = 0; r < ARK3D_VIEW_ROWS; r++)
        for (int c = 0; c < ARK3D_VIEW_COLS; c++)
        {
            int const offs = view_tile_index(c, r) * 2;
            uint8_t const attr = in->videoram[offs];
            st->tile_code[r][c] = (uint16_t)(in->videoram[offs + 1] + ((attr & 0x07) << 8) + 2048 * (in->gfxbank & 1));
            st->tile_color[r][c] = (uint8_t)((attr >> 3) + 32 * (in->palettebank & 1));
        }

    // ---- learn the background: [game] the band between the lowest bricks
    // and the Vaus never holds bricks and covers a whole period of the
    // round's background pattern, so its tiles are the background tiles.
    // Drop shadows (of bricks and the walls) are the same tiles drawn in a
    // dark colour.  Most of the band is lit, so each code's commonest colour
    // there is its lit colour.
    key_set background, background_codes;
    background.count = 0;
    background_codes.count = 0;
    {
        key_set seen;
        int seen_n[256];
        seen.count = 0;
        for (int r = layout.reference_top / 8; r < layout.reference_bottom / 8 && r < ARK3D_VIEW_ROWS; r++)
            for (int c = layout.field_left / 8; c < layout.field_right / 8 && c < ARK3D_VIEW_COLS; c++)
            {
                if (calibrated_tile_kind(cal, st->tile_code[r][c]) != ARK3D_KIND_UNKNOWN)
                    continue;
                uint32_t const k = tile_key(st->tile_code[r][c], st->tile_color[r][c]);
                int i = 0;
                while (i < seen.count && seen.keys[i] != k)
                    i++;
                if (i == seen.count)
                {
                    if (seen.count == 256)
                        continue;
                    seen.keys[seen.count++] = k;
                    seen_n[i] = 0;
                }
                seen_n[i]++;
                set_add(&background_codes, k & 0xfff);
            }
        for (int i = 0; i < seen.count; i++)
        {
            int lit = 1;
            for (int j = 0; j < seen.count; j++)
                if (j != i && (seen.keys[j] & 0xfff) == (seen.keys[i] & 0xfff) && seen_n[j] > seen_n[i])
                    lit = 0;
            if (lit)
                set_add(&background, seen.keys[i]);
        }
    }

    for (int r = 0; r < ARK3D_VIEW_ROWS; r++)
        for (int c = 0; c < ARK3D_VIEW_COLS; c++)
        {
            int kind = calibrated_tile_kind(cal, st->tile_code[r][c]);
            if (kind == ARK3D_KIND_UNKNOWN && set_has(&background_codes, st->tile_code[r][c]))
                kind = set_has(&background, tile_key(st->tile_code[r][c], st->tile_color[r][c]))
                    ? ARK3D_KIND_BACKGROUND : ARK3D_KIND_SHADOW;
            st->tile_kind[r][c] = (uint8_t)kind;
        }

    // ---- is a round on screen?  [game] both side walls are there: not on
    // the title, high-score and intro screens, nor while the game wipes and
    // redraws the playfield (after losing a life, between rounds), which
    // blanks it column by column.  Without calibrated wall tiles, assume it is.
    {
        int walls = 0, rows = 0;
        for (int r = layout.field_top / 8; r < ARK3D_VIEW_ROWS; r++, rows++)
        {
            walls += st->tile_kind[r][0] == ARK3D_KIND_WALL;
            walls += st->tile_kind[r][ARK3D_VIEW_COLS - 1] == ARK3D_KIND_WALL;
        }
        int calibrated_walls = 0;
        if (cal != NULL)
            for (int code = 0; code < ARK3D_NUM_CHARS && !calibrated_walls; code++)
                calibrated_walls = cal->tile_kind[code] == ARK3D_KIND_WALL;
        st->in_play = calibrated_walls ? (walls >= 2 * rows) : 1;
    }

    // ---- enemy hatches.  [game] closed they're tiles 124-127 in row 2; they
    // open through 14a, 14e, 152, 156, 15a (4 tiles each, 4 frames a step)
    // and close the same way back.
    {
        static const int gate_cols[2] = { ARK3D_GATE_LEFT_COL, ARK3D_GATE_RIGHT_COL };
        for (int gate = 0; gate < 2; gate++)
        {
            int const code = st->tile_code[2][gate_cols[gate]];
            int step = 0;
            if (code >= 0x14a && code <= 0x15d)
                step = (code - 0x14a) / 4 + 1;
            st->gate_open[gate] = (float)step / 5.0f;
        }
    }

    // ---- spare lives: [game] a Vaus icon (tiles 185, 184) per life left
    // besides the one in play, along the bottom row from column 1
    st->spare_lives = -1;
    if (st->in_play)
    {
        int n = 0;
        for (int c = 1; c + 1 < ARK3D_VIEW_COLS - 1; c += 2, n++)
            if (st->tile_code[ARK3D_VIEW_ROWS - 1][c] != 0x185 || st->tile_code[ARK3D_VIEW_ROWS - 1][c + 1] != 0x184)
                break;
        st->spare_lives = n;
    }

    // ---- warp gate.  [game] catching a B capsule opens it in the right wall,
    // view rows 27-31: the wall's tiles there step through 12a-12e, 12f-133
    // and 134-13b, then stay open (a frame, 13d on top and 13c at the bottom,
    // round an interior cycling 13e-149).  Judged by the top tile.
    {
        int const code = st->tile_code[27][ARK3D_VIEW_COLS - 1];
        float open = 0;
        if (code >= 0x12a && code <= 0x12e) open = 0.25f;
        else if (code >= 0x12f && code <= 0x133) open = 0.5f;
        else if (code >= 0x134 && code <= 0x13b) open = 0.75f;
        else if (code >= 0x13c && code <= 0x149) open = 1;
        st->warp_open = open;
    }

    // ---- DOH, round 33's boss.  [game] The round's background (codes
    // 3c2-471, seen nowhere else) says it's the DOH round.  DOH is tiles:
    // its face is the 8x12 block at view columns 10-17, rows 7-18.  The
    // face's top-left tile gives its state: 5ce, 62e, 68e, 6ee are the
    // mouth closed to open (the whole block steps by 0x60) in colour 16,
    // or 31 on the frame a hit lands.  After the 16th hit the face cycles
    // through colours 2-6, closes, turns to a wireframe (codes 472-5d9,
    // colours 7 then 24-27) and is cleared to blank tiles (20) in colour 9,
    // leaving a hole.  The hit count is ed6b, in RAM outside c000-c7ff;
    // the game resets it when the Vaus is lost.
    int doh_round = 0;
    {
        uint16_t const bg = st->tile_code[7][6], face = st->tile_code[7][10];
        uint8_t const face_color = st->tile_color[7][10] & 31;
        doh_round = bg >= 0x3c2 && bg <= 0x471;
        if (doh_round)
        {
            ark3d_doh *d = &st->doh;
            d->x = 80; d->y = 56; d->w = 64; d->h = 96;
            d->hits_max = 16;
            int const stage = (face >= 0x5ce && face <= 0x6ee && (face - 0x5ce) % 0x60 == 0) ? (face - 0x5ce) / 0x60 : -1;
            if (stage >= 0 && (face_color == 16 || face_color == 31))
            {
                d->phase = ARK3D_DOH_ALIVE;
                d->flash = face_color == 31;
            }
            else if (face == 0x20 && face_color == 9)
                d->phase = ARK3D_DOH_GONE;
            else if (face == 0x20)
                d->phase = ARK3D_DOH_ALIVE;         // wiped for a moment while the round is redrawn
            else
                d->phase = ARK3D_DOH_DYING;
            d->mouth = stage >= 0 ? (float)stage / 3.0f : 0;
            size_t const hits_at = 0xed6b - ARK3D_HIGH_RAM_BASE;
            d->hits = (in->high_ram != NULL && in->high_ram_bytes > hits_at) ? in->high_ram[hits_at] : -1;
            // after the last hit the face goes back to colour 16 for a few
            // frames to close its mouth: that's still dying
            if (d->phase == ARK3D_DOH_ALIVE && d->hits >= d->hits_max)
                d->phase = ARK3D_DOH_DYING;
            if (d->phase == ARK3D_DOH_DYING || d->phase == ARK3D_DOH_GONE)
                d->hits = d->hits_max;
        }
    }

    // ---- bricks (none in the DOH round: its face would read as bricks)
    st->grid_cols = layout.grid_cols < ARK3D_MAX_GRID_COLS ? layout.grid_cols : ARK3D_MAX_GRID_COLS;
    st->grid_rows = layout.grid_rows < ARK3D_MAX_GRID_ROWS ? layout.grid_rows : ARK3D_MAX_GRID_ROWS;
    for (int br = 0; br < st->grid_rows && !doh_round; br++)
        for (int bc = 0; bc < st->grid_cols; bc++)
        {
            int const x = layout.grid_left + bc * layout.brick_w;
            int const y = layout.grid_top + br * layout.brick_h;
            int const tc0 = x / 8, tc1 = (x + layout.brick_w - 1) / 8;
            int const tr0 = y / 8, tr1 = (y + layout.brick_h - 1) / 8;
            if (tc1 >= ARK3D_VIEW_COLS || tr1 >= ARK3D_VIEW_ROWS || !st->in_play)
                continue;

            ark3d_brick *b = &st->bricks[br][bc];
            b->code = st->tile_code[tr0][tc0];
            b->color = st->tile_color[tr0][tc0];

            // a calibrated brick tile decides directly.  [game] gold uses the
            // silver tiles in colour 1b (silver is colour 19)
            int ckind = calibrated_tile_kind(cal, b->code);
            if (ckind == ARK3D_KIND_BRICK_SILVER && (b->color & 31) == 0x1b)
                ckind = ARK3D_KIND_BRICK_GOLD;
            int kind = ARK3D_KIND_UNKNOWN;
            if (ckind == ARK3D_KIND_BRICK || ckind == ARK3D_KIND_BRICK_SILVER || ckind == ARK3D_KIND_BRICK_GOLD)
                kind = ckind;
            else if (ckind != ARK3D_KIND_UNKNOWN)
                kind = ARK3D_KIND_UNKNOWN;          // calibrated as something else: empty
            else
            {
                // [heuristic] a brick replaces every tile of its cell; a drop
                // shadow darkens only part of a neighbouring cell
                int all_foreign = 1, sum[3] = {0, 0, 0}, n = 0;
                for (int tr = tr0; tr <= tr1; tr++)
                    for (int tc = tc0; tc <= tc1; tc++)
                    {
                        int const k = st->tile_kind[tr][tc];
                        if (k == ARK3D_KIND_BACKGROUND || k == ARK3D_KIND_SHADOW || k == ARK3D_KIND_WALL || k == ARK3D_KIND_TEXT)
                            all_foreign = 0;
                        if (g)
                        {
                            int rgb[3];
                            tile_mean_rgb(g, st->tile_code[tr][tc], st->tile_color[tr][tc], rgb);
                            for (int k2 = 0; k2 < 3; k2++)
                                sum[k2] += rgb[k2];
                            n++;
                        }
                    }
                if (all_foreign)
                {
                    kind = ARK3D_KIND_BRICK;
                    // [heuristic] shadows are dark in every channel
                    if (g && n > 0)
                    {
                        int const r = sum[0] / n, gg = sum[1] / n, bb = sum[2] / n;
                        int const v = r > gg ? (r > bb ? r : bb) : (gg > bb ? gg : bb);
                        if (v < 60)
                            kind = ARK3D_KIND_UNKNOWN;
                    }
                }
            }
            if (kind == ARK3D_KIND_UNKNOWN)
            {
                b->kind = 0;
                continue;
            }
            b->kind = (uint8_t)kind;
            if (g)
                pen_rgb(g, b->color, g->chars[b->code].dominant_pen ? g->chars[b->code].dominant_pen : 0, b->rgb);
            else
                fallback_rgb(b->color, b->rgb);
            if (kind != ARK3D_KIND_BRICK_GOLD)
                st->brick_count++;
        }

    // ---- sprites.  [driver] draw_sprites: 16 entries of 4 bytes,
    // code = ram[3] + ((ram[2] & 3) << 8) + 1024*gfxbank,
    // color = (ram[2] >> 3) + 32*palettebank.
    sprite_entry spr[ARK3D_NUM_SPRITES];
    for (int i = 0; i < ARK3D_NUM_SPRITES; i++)
    {
        const uint8_t *s = in->spriteram + 4 * i;
        sprite_entry *e = &spr[i];
        memset(e, 0, sizeof(*e));
        e->slot = i;
        ark3d_sprite_view_rect(s, &e->x, &e->y);
        e->code = (uint16_t)((s[3] + ((s[2] & 0x03) << 8) + 1024 * (in->gfxbank & 1)) & (ARK3D_NUM_CHARS / 2 - 1));
        e->color = (uint8_t)((s[2] >> 3) + 32 * (in->palettebank & 1));
        e->kind = calibrated_sprite_kind(cal, e->code);
        // skip what can't be seen: off the view, or a blank graphic, and
        // [game] drop shadows: every object has a copy drawn in a colour
        // whose pens are all black, offset down and right
        e->used = (e->x > -16 && e->x < ARK3D_VIEW_W && e->y < ARK3D_VIEW_H) &&
                  (g == NULL || g->sprites[e->code].opaque > 0) &&
                  !is_shadow_color(g, e->color);
    }

    // Vaus: calibrated sprites, else [heuristic] the lowest row (>= vaus_min_y)
    // of two or more side-by-side sprites.  Its y never changes in play.
    int vaus_y = -1, have_cal_vaus = 0;
    for (int i = 0; i < ARK3D_NUM_SPRITES; i++)
        if (spr[i].used && is_vaus_kind(spr[i].kind))
        {
            have_cal_vaus = 1;
            vaus_y = spr[i].y;
        }
    if (!have_cal_vaus)
    {
        int best_n = 0;
        for (int i = 0; i < ARK3D_NUM_SPRITES; i++)
        {
            if (!spr[i].used || spr[i].kind != ARK3D_KIND_UNKNOWN || spr[i].y < layout.vaus_min_y)
                continue;
            int n = 0;
            for (int j = 0; j < ARK3D_NUM_SPRITES; j++)
                if (spr[j].used && spr[j].kind == ARK3D_KIND_UNKNOWN && spr[j].y == spr[i].y)
                    n++;
            if (n >= 2 && (n > best_n || (n == best_n && spr[i].y > vaus_y)))
            {
                best_n = n;
                vaus_y = spr[i].y;
            }
        }
    }
    if (vaus_y >= 0)
    {
        float x0 = 1e9f, y0 = 1e9f, x1 = -1e9f, y1 = -1e9f;
        for (int i = 0; i < ARK3D_NUM_SPRITES; i++)
        {
            sprite_entry *e = &spr[i];
            int const member = have_cal_vaus
                ? (e->used && is_vaus_kind(e->kind))
                : (e->used && e->kind == ARK3D_KIND_UNKNOWN && e->y == vaus_y);
            if (!member)
                continue;
            float a, b, c, d;
            sprite_bounds(g, e, &a, &b, &c, &d);
            if (a < x0) x0 = a;
            if (b < y0) y0 = b;
            if (c > x1) x1 = c;
            if (d > y1) y1 = d;
            if (e->kind == ARK3D_KIND_VAUS_LASER)
                st->vaus_laser = 1;
            if (e->kind == ARK3D_KIND_VAUS_EXPLODING)
                st->vaus_phase = ARK3D_VAUS_EXPLODING;
            else if (e->kind == ARK3D_KIND_VAUS_APPEARING && st->vaus_phase != ARK3D_VAUS_EXPLODING)
                st->vaus_phase = ARK3D_VAUS_APPEARING;
            e->used = 0;                        // consumed
        }
        st->vaus_visible = 1;
        if (st->vaus_phase == ARK3D_VAUS_NONE)
            st->vaus_phase = ARK3D_VAUS_NORMAL;
        st->vaus_x = (x0 + x1) * 0.5f;
        st->vaus_y = (y0 + y1) * 0.5f;
        st->vaus_w = x1 - x0;
        st->vaus_h = y1 - y0;
    }

    // ---- the round banner.  [game] "ROUND" is sprites 1d8-1da at x 80-112,
    // y 176, then the round number's digits (1ca + digit) at x 128 (units)
    // and x 120 (tens, from round 10); "READY" (1de-1e0) follows below.
    // Only in bank 0: the intro story reuses the codes.
    if ((in->gfxbank & 1) == 0)
    {
        int round_word = 0, units = -1, tens = 0, ready = 0;
        for (int i = 0; i < ARK3D_NUM_SPRITES; i++)
        {
            const sprite_entry *e = &spr[i];
            if (!e->used)
                continue;
            if (e->y == 176 && e->code == 0x1d8)
                round_word = 1;
            else if (e->y == 176 && e->code >= 0x1ca && e->code <= 0x1d3)
            {
                if (e->x == 128) units = e->code - 0x1ca;
                else if (e->x == 120) tens = e->code - 0x1ca;
            }
            else if (e->y == 192 && e->code >= 0x1de && e->code <= 0x1e0)
                ready = 1;
        }
        if (round_word && units >= 0)
        {
            st->banner_round = tens * 10 + units;
            st->banner_ready = ready;
        }
    }

    // everything else
    for (int i = 0; i < ARK3D_NUM_SPRITES; i++)
    {
        sprite_entry *e = &spr[i];
        if (!e->used)
            continue;
        int kind = e->kind;
        if (kind == ARK3D_KIND_TEXT)
            continue;

        if (kind == ARK3D_KIND_UNKNOWN && g != NULL)
        {
            int const opaque = g->sprites[e->code].opaque;
            int const w = g->sprites[e->code].x1 - g->sprites[e->code].x0 + 1;
            int const h = g->sprites[e->code].y1 - g->sprites[e->code].y0 + 1;
            // [heuristic] ball: a small compact blob (about 5x4 px);
            // laser: thin vertical strokes; big sprites: a capsule (one
            // 16x8 sprite) or an enemy (two sprites stacked, 16x16)
            if (opaque <= 24 && w <= 7 && h <= 7 && w >= 2 && h >= 2)
                kind = ARK3D_KIND_BALL;
            else if (opaque <= 32 && h >= 5 && opaque * 2 <= w * h)
                kind = ARK3D_KIND_LASER;
            else if (opaque >= 40)
            {
                kind = ARK3D_KIND_CAPSULE;
                for (int j = 0; j < ARK3D_NUM_SPRITES; j++)
                    if (j != i && spr[j].used && spr[j].kind == ARK3D_KIND_UNKNOWN &&
                        g->sprites[spr[j].code].opaque >= 20 &&
                        (spr[j].x - e->x <= 2 && e->x - spr[j].x <= 2) &&
                        (spr[j].y - e->y == 8 || e->y - spr[j].y == 8))
                        kind = ARK3D_KIND_ENEMY;
            }
            else
                kind = ARK3D_KIND_OTHER;
        }
        else if (kind == ARK3D_KIND_UNKNOWN)
            kind = ARK3D_KIND_OTHER;

        if (kind == ARK3D_KIND_BALL)
        {
            if (st->ball_count < ARK3D_MAX_BALLS)
                set_object(&st->balls[st->ball_count++], g, e, kind);
            continue;
        }
        if (st->object_count >= ARK3D_MAX_OBJECTS)
            continue;
        ark3d_object *o = &st->objects[st->object_count++];
        set_object(o, g, e, kind);
        if (kind == ARK3D_KIND_CAPSULE)
        {
            int const cc = cal ? cal->sprite_capsule[e->code] : ARK3D_CAPSULE_UNKNOWN;
            o->capsule = (uint8_t)(cc != ARK3D_CAPSULE_UNKNOWN ? cc : nearest_capsule(o->rgb));
        }
    }

    // merge stacked enemy halves into one 16x16 object
    for (int i = 0; i < st->object_count; i++)
    {
        ark3d_object *a = &st->objects[i];
        if (a->kind != ARK3D_KIND_ENEMY)
            continue;
        for (int j = i + 1; j < st->object_count; j++)
        {
            ark3d_object *b = &st->objects[j];
            float const dx = a->x - b->x, dy = a->y - b->y;
            if (b->kind != ARK3D_KIND_ENEMY || dx > 3 || dx < -3 || dy > 12 || dy < -12)
                continue;
            float const top = (a->y - a->h / 2 < b->y - b->h / 2) ? a->y - a->h / 2 : b->y - b->h / 2;
            float const bot = (a->y + a->h / 2 > b->y + b->h / 2) ? a->y + a->h / 2 : b->y + b->h / 2;
            a->y = (top + bot) * 0.5f;
            a->h = bot - top;
            st->objects[j] = st->objects[--st->object_count];
            break;
        }
    }

    // ---- scores: [game] 3 BCD bytes each, most significant first, in units
    // of 10 points: the player's at c4d7, the high score at c4df.  Checked
    // against the digits on screen over about 58,000 captured frames.
    st->score = read_score(in, 0x4d7);
    st->high_score = read_score(in, 0x4df);
    return 0;
}

//------------------------------------------------------------
//  names
//------------------------------------------------------------

int ark3d_enemy_type(uint16_t code)
{
    // [game] the four types, found by following each enemy's animation
    // through captures of rounds 1-27 and the attract demo: molecule
    // 12a-139 (8 frames), cube 146-159 (10), pyramid 15a-16f (11), cone
    // 170-17f (8).  13a-145 were never seen; they sit with the cube.
    if (code >= 0x12a && code < 0x13a) return ARK3D_ENEMY_MOLECULE;
    if (code >= 0x13a && code < 0x15a) return ARK3D_ENEMY_CUBE;
    if (code >= 0x15a && code < 0x170) return ARK3D_ENEMY_PYRAMID;
    if (code >= 0x170 && code < 0x180) return ARK3D_ENEMY_CONE;
    return ARK3D_ENEMY_UNKNOWN;
}

const char *ark3d_kind_name(int kind)
{
    static const char *const names[ARK3D_KIND_COUNT] = {
        "unknown", "background", "shadow", "wall", "brick", "silver", "gold", "text",
        "vaus", "vaus_laser", "ball", "capsule", "enemy", "laser", "explosion", "other",
        "vaus_appearing", "vaus_exploding", "doh_shot"
    };
    return (kind >= 0 && kind < ARK3D_KIND_COUNT) ? names[kind] : "?";
}

const char *ark3d_capsule_name(int capsule)
{
    static const char *const names[ARK3D_CAPSULE_COUNT] = { "?", "S", "C", "L", "E", "D", "B", "P" };
    return (capsule >= 0 && capsule < ARK3D_CAPSULE_COUNT) ? names[capsule] : "?";
}
