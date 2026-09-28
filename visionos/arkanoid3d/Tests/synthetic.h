// license:BSD-3-Clause
//
// synthetic.h - made-up Arkanoid-format graphics, palette and screen
// contents, shared by test_ark3d.c (unit tests) and ark3d_synth.c (files for
// an end-to-end run through real MAME).  NOT Arkanoid's graphics: shaped to
// exercise the decoder.

#ifndef ARK3D_SYNTHETIC_H
#define ARK3D_SYNTHETIC_H

#include "ark3d.h"

#include <string.h>

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

// the scene test_playfield checks (also what ark3d_synth writes for the
// end-to-end MAME test)
static void build_scene(void)
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

}

#endif // ARK3D_SYNTHETIC_H
