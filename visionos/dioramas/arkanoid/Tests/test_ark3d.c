// license:BSD-3-Clause
//
// test_ark3d - unit tests for the Arkanoid state decoder over synthetic
// video RAM, sprite RAM, graphics and palette data.  Builds and runs on any
// host with a C11 compiler:  make -C visionos/dioramas/arkanoid/Tests
//
// The synthetic graphics are *not* Arkanoid's: they're shaped to exercise
// the decoder's hardware formulas (tile/sprite addressing, ROT90 mapping,
// bitplane and PROM decoding) and its heuristics.  Whether the heuristics
// match the real game can only be checked with a ROM (see ../README.md).

#include "ark3d.h"
#include "synthetic.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0, checks = 0;

#define CHECK(cond) do { checks++; if (!(cond)) { failures++; fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define CHECK_EQ(a, b) do { long long _a = (long long)(a), _b = (long long)(b); checks++; if (_a != _b) { failures++; fprintf(stderr, "%s:%d: %s == %lld, expected %s == %lld\n", __FILE__, __LINE__, #a, _a, #b, _b); } } while (0)
#define CHECK_NEAR(a, b) do { double _a = (a), _b = (b); checks++; if (_a - _b > 0.01 || _b - _a > 0.01) { failures++; fprintf(stderr, "%s:%d: %s == %g, expected %g\n", __FILE__, __LINE__, #a, _a, _b); } } while (0)

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
    build_scene();

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
    CHECK_EQ(st.score, 270);

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

// the codes verified against the real game (ark3d_default_calibration),
// placed the way the game draws them: every object has a drop shadow, a copy
// in colour 8 offset down and right
static void test_default_calibration(void)
{
    static ark3d_calibration cal;
    ark3d_default_calibration(&cal);

    build_screen();
    memset(spriteram, 0, sizeof(spriteram));       // unused slots are all zero in the game
    put_sprite(0, 116, 236, 0x0f2, 8);              // Vaus shadow
    put_sprite(1, 100, 236, 0x0f3, 8);
    put_sprite(2, 112, 232, 0x0f2, 0x0a);           // Vaus
    put_sprite(3, 96, 232, 0x0f3, 0x0a);
    put_sprite(4, 42, 122, 0x193, 8);               // capsule shadow
    put_sprite(5, 40, 120, 0x193, 0x13);            // an L capsule, rotation frame 3
    put_sprite(6, 80, 150, 0x1b8, 0x0c);            // ball
    put_sprite(7, 80, 176, 0x1d8, 0x00);            // "ROUND" text

    ark3d_input in;
    memset(&in, 0, sizeof(in));
    in.videoram = videoram;
    in.spriteram = spriteram;

    ark3d_state st;
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, &cal, &st), 0);
    CHECK_EQ(st.vaus_visible, 1);
    CHECK_EQ(st.vaus_phase, ARK3D_VAUS_NORMAL);
    CHECK_NEAR(st.vaus_x, 112);                     // cells 96-128, not the shadow's 100-132
    CHECK_NEAR(st.vaus_y, 236);
    CHECK_EQ(st.ball_count, 1);
    CHECK_EQ(st.object_count, 1);                   // the capsule; shadows and text aren't objects
    CHECK_EQ(st.objects[0].kind, ARK3D_KIND_CAPSULE);
    CHECK_EQ(st.objects[0].capsule, ARK3D_CAPSULE_L);
    // the synthetic walls aren't the game's wall tiles, so no round is on screen
    CHECK_EQ(st.in_play, 0);

    // the game's walls: a round is on screen, and its bricks are decoded
    for (int r = 2; r < ARK3D_VIEW_ROWS; r++)
    {
        put_tile(0, r, 0x120, 0x1c);
        put_tile(27, r, 0x120, 0x1c);
    }
    put_tile(1, 7, 0x16e, 0x19);                    // silver brick at cell (0, 4)
    put_tile(2, 7, 0x16f, 0x19);
    put_tile(3, 8, 0x166, 0x18);                    // red brick at cell (1, 5)
    put_tile(4, 8, 0x167, 0x18);
    put_sprite(2, 112, 232, 0x10b, 0x09);           // the Vaus blowing up
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, &cal, &st), 0);
    CHECK_EQ(st.in_play, 1);
    CHECK_EQ(st.bricks[4][0].kind, ARK3D_KIND_BRICK_SILVER);
    // the game's wipe blanks the playfield column by column from the right
    put_tile(27, 20, 0x020, 0);
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, &cal, &st), 0);
    CHECK_EQ(st.in_play, 0);
    CHECK_EQ(st.brick_count, 0);
    put_tile(27, 20, 0x120, 0x1c);
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, &cal, &st), 0);
    CHECK_EQ(st.bricks[5][1].kind, ARK3D_KIND_BRICK);
    CHECK_EQ(st.vaus_phase, ARK3D_VAUS_EXPLODING);
    // gold: the silver tiles in colour 1b; it doesn't count as breakable
    int const breakable = st.brick_count;
    put_tile(5, 7, 0x16e, 0x1b);
    put_tile(6, 7, 0x16f, 0x1b);
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, &cal, &st), 0);
    CHECK_EQ(st.bricks[4][2].kind, ARK3D_KIND_BRICK_GOLD);
    CHECK_EQ(st.brick_count, breakable);
    CHECK_NEAR(st.gate_open[0], 0);
    CHECK_EQ(st.spare_lives, 0);
    put_tile(1, 31, 0x185, 0x1c); put_tile(2, 31, 0x184, 0x1c);
    put_tile(3, 31, 0x185, 0x1c); put_tile(4, 31, 0x184, 0x1c);
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, &cal, &st), 0);
    CHECK_EQ(st.spare_lives, 2);

    // the right hatch half open (third of five steps)
    for (int i = 0; i < 4; i++)
        put_tile(ARK3D_GATE_RIGHT_COL + i, 2, 0x152 + i, 0x1c);
    CHECK_EQ(ark3d_decode(&in, NULL, NULL, &cal, &st), 0);
    CHECK_NEAR(st.gate_open[0], 0);
    CHECK_NEAR(st.gate_open[1], 0.6);
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
    test_default_calibration();
    test_bad_input();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
