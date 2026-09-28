// license:BSD-3-Clause
//
// test_ark3d - unit tests for the Arkanoid state decoder over synthetic
// video RAM, sprite RAM, graphics and palette data.  Builds and runs on any
// host with a C11 compiler:  make -C visionos/arkanoid3d/Tests
//
// The synthetic graphics are *not* Arkanoid's: they're shaped to exercise
// the decoder's hardware formulas (tile/sprite addressing, ROT90 mapping,
// bitplane and PROM decoding) and its heuristics.  Whether the heuristics
// match the real game can only be checked with a ROM (see ../README.md).

#include "ark3d.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0, checks = 0;

#define CHECK(cond) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CHECK_EQ(a, b) do { long long _a = (long long)(a), _b = (long long)(b); checks++; if (_a != _b) { failures++; fprintf(stderr, "%s:%d: %s == %lld, expected %s == %lld\n", __FILE__, __LINE__, #a, _a, #b, _b); } } while (0)
#define CHECK_NEAR(a, b) do { double _a = (a), _b = (b); checks++; if (_a - _b > 0.01 || _b - _a > 0.01) { failures++; fprintf(stderr, "%s:%d: %s == %g, expected %g\n", __FILE__, __LINE__, #a, _a, _b); } } while (0)

//------------------------------------------------------------
//  synthetic hardware
//------------------------------------------------------------

static uint8_t gfx[ARK3D_GFX_BYTES];
static uint8_t proms[ARK3D_PROM_BYTES];
static uint8_t videoram[ARK3D_VIDEORAM_BYTES];
static uint8_t spriteram[ARK3D_SPRITERAM_BYTES];
static uint8_t workram[0x800];

// inverse of ark3d_char_pen
static void set_pen(int code, int px, int py, int pen)
{
    size_t const row = (size_t)code * 8 + (size_t)py;
    uint8_t const bit = (uint8_t)(0x80 >> px);
    uint8_t *planes[3] = { &gfx[0x10000 + row], &gfx[0x08000 + row], &gfx[row] };
    for (int p = 0; p < 3; p++)
    {
        if ((pen >> (2 - p)) & 1)
            *planes[p] |= bit;
        else
            *planes[p] &= (uint8_t)~bit;
    }
}

static void fill_char(int code, int pen)
{
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 8; x++)
            set_pen(code, x, y, pen);
}

// sprite pixel in view space (u 0-15 across, v 0-7 down), as ark3d.c documents
static void set_sprite_pixel(int code, int u, int v, int pen)
{
    int const off = 15 - u;
    set_pen(2 * code + (off >= 8 ? 1 : 0), v, off & 7, pen);
}

// palette entry from 8-bit-ish levels: pick the nibble whose prom_level is closest
static void set_color(int index, int r, int g, int b)
{
    int const want[3] = { r, g, b };
    for (int k = 0; k < 3; k++)
    {
        int best = 0, bestd = 1 << 30;
        for (int n = 0; n < 16; n++)
        {
            int const lvl = 0x0e * (n & 1) + 0x1f * ((n >> 1) & 1) + 0x43 * ((n >> 2) & 1) + 0x8f * ((n >> 3) & 1);
            int const d = (lvl - want[k]) * (lvl - want[k]);
            if (d < bestd) { bestd = d; best = n; }
        }
        proms[index + k * ARK3D_NUM_PENS] = (uint8_t)best;
    }
}

// write a tile at a *view* tile position, the way the game would (tilemap index)
static void put_tile(int view_col, int view_row, int code, int color)
{
    int const index = (29 - view_col) * 32 + view_row;
    videoram[index * 2] = (uint8_t)(((color & 31) << 3) | ((code >> 8) & 7));
    videoram[index * 2 + 1] = (uint8_t)(code & 0xff);
}

// place sprite slot at view (x,y) (top-left of its 16x8 cell)
static void put_sprite(int slot, int x, int y, int code, int color)
{
    uint8_t *s = &spriteram[slot * 4];
    s[0] = (uint8_t)y;
    s[1] = (uint8_t)(x + 16);
    s[2] = (uint8_t)(((color & 31) << 3) | ((code >> 8) & 3));
    s[3] = (uint8_t)(code & 0xff);
}

enum {
    // tile codes
    T_BG_A = 1, T_BG_B = 2, T_WALL = 4, T_BRICK_L = 16, T_BRICK_R = 17, T_SHADOW = 20, T_BLUE_L = 24, T_BLUE_R = 25,
    // colour groups
    C_BG = 1, C_BRICK = 2, C_WALL = 3, C_SPRITE = 4, C_ORANGE = 5, C_BLUE = 6,
    // sprite codes (chars 2n, 2n+1)
    S_BLANK = 60, S_VAUS = 40, S_BALL = 41, S_CAPSULE = 42, S_ENEMY = 43, S_LASER = 44, S_DOT = 45
};

static void build_graphics(void)
{
    memset(gfx, 0, sizeof(gfx));
    memset(proms, 0, sizeof(proms));

    // palettes (group*8 + pen)
    set_color(C_BG * 8 + 1, 20, 20, 90);        // background: two dark blues
    set_color(C_BG * 8 + 2, 30, 30, 120);
    set_color(C_BRICK * 8 + 1, 230, 20, 20);    // red brick face
    set_color(C_BRICK * 8 + 2, 255, 255, 255);  // highlight
    set_color(C_BRICK * 8 + 3, 10, 10, 30);     // shadow (dark)
    set_color(C_WALL * 8 + 1, 160, 160, 170);
    set_color(C_SPRITE * 8 + 1, 200, 200, 200);
    set_color(C_SPRITE * 8 + 2, 255, 0, 0);
    set_color(C_ORANGE * 8 + 1, 255, 140, 0);
    set_color(C_BLUE * 8 + 1, 0, 60, 255);

    // background pattern: alternating chars, a checker inside each
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 8; x++)
        {
            set_pen(T_BG_A, x, y, ((x ^ y) & 1) ? 1 : 2);
            set_pen(T_BG_B, x, y, ((x ^ y) & 2) ? 1 : 2);
        }
    fill_char(T_WALL, 1);
    // brick halves: face pen 1 with a highlight row
    fill_char(T_BRICK_L, 1);
    fill_char(T_BRICK_R, 1);
    for (int x = 0; x < 8; x++) { set_pen(T_BRICK_L, x, 0, 2); set_pen(T_BRICK_R, x, 0, 2); }
    fill_char(T_SHADOW, 3);
    fill_char(T_BLUE_L, 1);
    fill_char(T_BLUE_R, 1);

    // sprites
    for (int u = 0; u < 16; u++)                // Vaus piece: full 16x6 bar
        for (int v = 1; v < 7; v++)
            set_sprite_pixel(S_VAUS, u, v, 1);
    for (int u = 6; u < 11; u++)                // ball: 5x4 blob at (6..10, 2..5)
        for (int v = 2; v < 6; v++)
            set_sprite_pixel(S_BALL, u, v, 1);
    for (int u = 0; u < 16; u++)                // capsule: orange body, grey letter
        for (int v = 0; v < 8; v++)
            set_sprite_pixel(S_CAPSULE, u, v, (u >= 6 && u <= 9 && v >= 2 && v <= 5) ? 2 : 1);
    for (int u = 2; u < 14; u++)                // enemy half: 12x8 block
        for (int v = 0; v < 8; v++)
            set_sprite_pixel(S_ENEMY, u, v, 1);
    for (int v = 0; v < 8; v++)                 // laser: two thin strokes
    {
        set_sprite_pixel(S_LASER, 3, v, 2);
        set_sprite_pixel(S_LASER, 12, v, 2);
    }
    set_sprite_pixel(S_DOT, 7, 0, 1);           // single pixel, for orientation
}

// an empty playfield: background pattern inside, walls around, blank sprites
static void build_screen(void)
{
    memset(videoram, 0, sizeof(videoram));
    memset(spriteram, 0, sizeof(spriteram));
    for (int r = 0; r < ARK3D_VIEW_ROWS; r++)
        for (int c = 0; c < ARK3D_VIEW_COLS; c++)
        {
            if (r < 2)
                put_tile(c, r, 0, 0);                       // text area
            else if (r == 2 || c == 0 || c == 27)
                put_tile(c, r, T_WALL, C_WALL);
            else
                put_tile(c, r, ((r + c) & 1) ? T_BG_A : T_BG_B, C_BG);
        }
    // all sprites parked on the blank code
    for (int i = 0; i < ARK3D_NUM_SPRITES; i++)
        put_sprite(i, 0, 0, S_BLANK, 0);
}

static void put_brick(int col, int row, int left, int right, int color)
{
    // cell (col,row) with the default layout: x = 8 + 16*col, y = 24 + 8*row
    int const tc = (8 + 16 * col) / 8, tr = (24 + 8 * row) / 8;
    put_tile(tc, tr, left, color);
    put_tile(tc + 1, tr, right, color);
}

//------------------------------------------------------------
//  tests
//------------------------------------------------------------

static void test_mapping(void)
{
    int x, y;
    // raw (0,16) is the first visible line's first pixel: top-right of the view
    ark3d_raw_to_view(0, 16, &x, &y);
    CHECK_EQ(x, 223); CHECK_EQ(y, 0);
    ark3d_raw_to_view(255, 239, &x, &y);
    CHECK_EQ(x, 0); CHECK_EQ(y, 255);

    // a sprite with ram[0]=100, ram[1]=50 covers view x 34..49, y 100..107
    uint8_t s[4] = { 100, 50, 0, 0 };
    ark3d_sprite_view_rect(s, &x, &y);
    CHECK_EQ(x, 34); CHECK_EQ(y, 100);
}

static void test_pen_decoding(void)
{
    memset(gfx, 0, sizeof(gfx));
    // pen 5 = 101b: plane0 (0x10000) and plane2 (0x0000) set
    set_pen(3, 2, 4, 5);
    CHECK_EQ(gfx[0x10000 + 3 * 8 + 4], 0x20);
    CHECK_EQ(gfx[0x08000 + 3 * 8 + 4], 0x00);
    CHECK_EQ(gfx[0x00000 + 3 * 8 + 4], 0x20);
    CHECK_EQ(ark3d_char_pen(gfx, 3, 2, 4), 5);
    CHECK_EQ(ark3d_char_pen(gfx, 3, 3, 4), 0);
}

static void test_palette(ark3d_graphics *g)
{
    // all four bits set: 0x0e+0x1f+0x43+0x8f = 0xff
    memset(proms, 0, sizeof(proms));
    proms[7] = 0x0f;
    proms[7 + 512] = 0x01;
    proms[7 + 1024] = 0x08;
    ark3d_analyze_graphics(g, gfx, sizeof(gfx), proms, sizeof(proms));
    CHECK(g->valid);
    CHECK_EQ(g->rgb[7][0], 0xff);
    CHECK_EQ(g->rgb[7][1], 0x0e);
    CHECK_EQ(g->rgb[7][2], 0x8f);
    // missing regions -> not valid
    ark3d_analyze_graphics(g, NULL, 0, proms, sizeof(proms));
    CHECK(!g->valid);
}

static void test_sprite_orientation(ark3d_graphics *g)
{
    build_graphics();
    ark3d_analyze_graphics(g, gfx, sizeof(gfx), proms, sizeof(proms));
    // S_DOT has one pixel at view (7,0): that's char 2n+1, px 0, py 0
    CHECK_EQ(ark3d_char_pen(gfx, 2 * S_DOT + 1, 0, 0), 1);
    CHECK_EQ(g->sprites[S_DOT].opaque, 1);
    CHECK_EQ(g->sprites[S_DOT].x0, 7); CHECK_EQ(g->sprites[S_DOT].x1, 7);
    CHECK_EQ(g->sprites[S_DOT].y0, 0); CHECK_EQ(g->sprites[S_DOT].y1, 0);
    CHECK_EQ(g->sprites[S_BALL].opaque, 20);
    CHECK_EQ(g->sprites[S_BLANK].opaque, 0);
}

static void test_playfield(const ark3d_graphics *g, int with_graphics)
{
    build_screen();
    put_brick(0, 0, T_BRICK_L, T_BRICK_R, C_BRICK);
    put_brick(12, 3, T_BRICK_L, T_BRICK_R, C_BRICK);
    put_brick(5, 10, T_BLUE_L, T_BLUE_R, C_BLUE);
    // a drop shadow over half of cell (6,10): not a brick
    put_tile((8 + 16 * 6) / 8, (24 + 8 * 10) / 8, T_SHADOW, C_BRICK);
    // a fully shadowed cell (7,11): only the darkness test rejects it
    put_brick(7, 11, T_SHADOW, T_SHADOW, C_BRICK);

    put_sprite(0, 96, 232, S_VAUS, C_SPRITE);
    put_sprite(1, 112, 232, S_VAUS, C_SPRITE);
    put_sprite(2, 100, 150, S_BALL, C_SPRITE);
    put_sprite(3, 50, 100, S_CAPSULE, C_ORANGE);
    put_sprite(4, 150, 60, S_ENEMY, C_SPRITE);
    put_sprite(5, 150, 68, S_ENEMY, C_SPRITE);
    put_sprite(6, 30, 180, S_LASER, C_SPRITE);

    workram[0x4df] = 0x05; workram[0x4e0] = 0x00; workram[0x4e1] = 0x00;

    ark3d_input in;
    memset(&in, 0, sizeof(in));
    in.videoram = videoram;
    in.spriteram = spriteram;
    in.work_ram = workram;
    in.work_ram_bytes = sizeof(workram);

    ark3d_state st;
    CHECK_EQ(ark3d_decode(&in, NULL, with_graphics ? g : NULL, NULL, &st), 0);

    // tile readback in view order
    CHECK_EQ(st.tile_code[3][1], T_BRICK_L);
    CHECK_EQ(st.tile_code[3][2], T_BRICK_R);
    CHECK_EQ(st.tile_color[3][1], C_BRICK);
    CHECK_EQ(st.tile_kind[20][10], ARK3D_KIND_BACKGROUND);

    // bricks
    CHECK_EQ(st.grid_cols, 13);
    CHECK_EQ(st.bricks[0][0].kind, ARK3D_KIND_BRICK);
    CHECK_EQ(st.bricks[3][12].kind, ARK3D_KIND_BRICK);
    CHECK_EQ(st.bricks[10][5].kind, ARK3D_KIND_BRICK);
    CHECK_EQ(st.bricks[10][6].kind, 0);                     // half shadow
    CHECK_EQ(st.bricks[0][1].kind, 0);
    if (with_graphics)
    {
        CHECK_EQ(st.bricks[11][7].kind, 0);                 // dark cell
        CHECK_EQ(st.brick_count, 3);
        CHECK(st.bricks[0][0].rgb[0] > 200 && st.bricks[0][0].rgb[1] < 60);    // red
        CHECK(st.bricks[10][5].rgb[2] > 200 && st.bricks[10][5].rgb[0] < 60);  // blue
    }
    else
    {
        CHECK_EQ(st.bricks[11][7].kind, ARK3D_KIND_BRICK);  // no graphics: can't tell
        CHECK_EQ(st.brick_count, 4);
    }

    // Vaus: two 16 px pieces at x 96 and 112
    CHECK(st.vaus_visible);
    CHECK_NEAR(st.vaus_x, 112);
    CHECK_NEAR(st.vaus_w, 32);
    if (with_graphics)
    {
        CHECK_NEAR(st.vaus_y, 232 + 4);    // rows 1..6 opaque
        CHECK_NEAR(st.vaus_h, 6);
    }
    else
        CHECK_NEAR(st.vaus_y, 236);

    CHECK_EQ(st.high_score, 50000);

    if (!with_graphics)
    {
        // everything else is "other" without the graphics to look at,
        // including the 9 parked sprites (blank graphics can't be detected)
        CHECK_EQ(st.ball_count, 0);
        CHECK_EQ(st.object_count, 14);
        return;
    }

    CHECK_EQ(st.ball_count, 1);
    CHECK_NEAR(st.balls[0].x, 100 + 8.5);  // blob u 6..10 -> centre 8.5
    CHECK_NEAR(st.balls[0].y, 150 + 4);    // v 2..5 -> centre 4
    CHECK_NEAR(st.balls[0].w, 5);
    CHECK_NEAR(st.balls[0].h, 4);

    int capsules = 0, enemies = 0, lasers = 0;
    for (int i = 0; i < st.object_count; i++)
    {
        const ark3d_object *o = &st.objects[i];
        if (o->kind == ARK3D_KIND_CAPSULE)
        {
            capsules++;
            CHECK_EQ(o->capsule, ARK3D_CAPSULE_S);
            CHECK_NEAR(o->x, 58);
        }
        if (o->kind == ARK3D_KIND_ENEMY)
        {
            enemies++;
            CHECK_NEAR(o->h, 16);          // two halves merged
            CHECK_NEAR(o->y, 68);
        }
        if (o->kind == ARK3D_KIND_LASER)
            lasers++;
    }
    CHECK_EQ(capsules, 1);
    CHECK_EQ(enemies, 1);
    CHECK_EQ(lasers, 1);
    CHECK_EQ(st.object_count, 3);
}

static void test_banks_and_calibration(const ark3d_graphics *g)
{
    build_screen();
    // with gfxbank=1 the same RAM bytes address codes +2048 (tiles) / +1024 (sprites)
    put_tile(5, 10, 0x123, 7);
    put_sprite(0, 40, 40, 0x045, 3);

    ark3d_input in;
    memset(&in, 0, sizeof(in));
    in.videoram = videoram;
    in.spriteram = spriteram;
    in.gfxbank = 1;
    in.palettebank = 1;

    static ark3d_calibration cal;
    memset(&cal, 0, sizeof(cal));
    cal.sprite_kind[0x045 + 1024] = ARK3D_KIND_BALL;
    cal.tile_kind[0x123 + 2048] = ARK3D_KIND_BRICK_GOLD;

    ark3d_state st;
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, &cal, &st), 0);
    CHECK_EQ(st.tile_code[10][5], 0x123 + 2048);
    CHECK_EQ(st.tile_color[10][5], 7 + 32);
    CHECK_EQ(st.ball_count, 1);
    CHECK_EQ(st.balls[0].code, 0x045 + 1024);
    CHECK_EQ(st.balls[0].color, 3 + 32);

    // calibrated gold brick at cell (col 2, row 7): x = 40, y = 80 -> tiles (5,10),(6,10)
    CHECK_EQ(st.bricks[7][2].kind, ARK3D_KIND_BRICK_GOLD);
    CHECK_EQ(st.brick_count, 0);           // gold doesn't count
    (void)g;
}

static void test_bad_input(void)
{
    ark3d_state st;
    ark3d_input in;
    memset(&in, 0, sizeof(in));
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, NULL, &st), -1);
    CHECK_EQ(ark3d_decode(NULL, NULL, NULL, NULL, &st), -1);
}

int main(void)
{
    static ark3d_graphics g;
    test_mapping();
    test_pen_decoding();
    test_palette(&g);
    test_sprite_orientation(&g);
    test_playfield(&g, 1);
    test_playfield(&g, 0);
    test_banks_and_calibration(&g);
    test_bad_input();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
