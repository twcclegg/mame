// license:BSD-3-Clause
//
// ark3d_dump - decode a capture made by ../lua/ark3d_capture.lua (a real
// arkanoid run in MAME) with the same decoder the visionOS app uses, and
// print what it sees.  This is how the heuristics and the default layout
// get checked, and how a calibration table gets written, once someone has a
// ROM.
//
//   ark3d_dump capture.bin                 every frame, one summary line each
//   ark3d_dump capture.bin -f 1200         frame 1200 in detail: brick grid,
//                                          tile codes, objects
//   ark3d_dump capture.bin --codes         which tile / sprite codes turned up
//                                          where, over the whole capture
//
// Capture format (little-endian), written by ark3d_capture.lua:
//   "ARK3DCAP" u32 version(1) u32 gfx_bytes u32 prom_bytes  gfx  proms
//   then per frame: "FRME" u32 frame u8 gfxbank u8 palettebank u8 flip_x
//   u8 flip_y, videoram[0x800], spriteram[0x40], workram[0x800]

#include "ark3d.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WORKRAM_BYTES 0x800

static uint32_t rd32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

typedef struct {
    uint32_t frame;
    uint8_t gfxbank, palettebank, flip_x, flip_y;
    uint8_t videoram[ARK3D_VIDEORAM_BYTES];
    uint8_t spriteram[ARK3D_SPRITERAM_BYTES];
    uint8_t workram[WORKRAM_BYTES];
} record;

static int read_record(FILE *f, record *r)
{
    uint8_t hdr[12];
    if (fread(hdr, 1, sizeof(hdr), f) != sizeof(hdr) || memcmp(hdr, "FRME", 4) != 0)
        return 0;
    r->frame = rd32(hdr + 4);
    r->gfxbank = hdr[8];
    r->palettebank = hdr[9];
    r->flip_x = hdr[10];
    r->flip_y = hdr[11];
    return fread(r->videoram, 1, sizeof(r->videoram), f) == sizeof(r->videoram) &&
           fread(r->spriteram, 1, sizeof(r->spriteram), f) == sizeof(r->spriteram) &&
           fread(r->workram, 1, sizeof(r->workram), f) == sizeof(r->workram);
}

static void print_detail(const ark3d_state *st)
{
    printf("bricks (%d breakable; # brick, S silver, G gold, . empty):\n", st->brick_count);
    for (int r = 0; r < st->grid_rows; r++)
    {
        printf("  %2d ", r);
        for (int c = 0; c < st->grid_cols; c++)
        {
            int const k = st->bricks[r][c].kind;
            putchar(k == ARK3D_KIND_BRICK ? '#' : k == ARK3D_KIND_BRICK_SILVER ? 'S' : k == ARK3D_KIND_BRICK_GOLD ? 'G' : '.');
        }
        printf("   ");
        for (int c = 0; c < st->grid_cols; c++)
            if (st->bricks[r][c].kind)
                printf(" %03x/%02x#%02x%02x%02x", st->bricks[r][c].code, st->bricks[r][c].color,
                       st->bricks[r][c].rgb[0], st->bricks[r][c].rgb[1], st->bricks[r][c].rgb[2]);
        putchar('\n');
    }

    printf("tilemap (view order, code/colour; * = learned background):\n");
    for (int r = 0; r < ARK3D_VIEW_ROWS; r++)
    {
        printf("  %2d", r);
        for (int c = 0; c < ARK3D_VIEW_COLS; c++)
            printf(" %03x%c", st->tile_code[r][c], st->tile_kind[r][c] == ARK3D_KIND_BACKGROUND ? '*' : ' ');
        putchar('\n');
    }

    if (st->vaus_visible)
        printf("vaus: x %.1f y %.1f w %.1f h %.1f%s\n", st->vaus_x, st->vaus_y, st->vaus_w, st->vaus_h, st->vaus_laser ? " laser" : "");
    else
        printf("vaus: not found\n");
    for (int i = 0; i < st->ball_count; i++)
        printf("ball: x %.1f y %.1f (%gx%g) sprite %d code %03x\n", st->balls[i].x, st->balls[i].y,
               st->balls[i].w, st->balls[i].h, st->balls[i].sprite, st->balls[i].code);
    for (int i = 0; i < st->object_count; i++)
    {
        const ark3d_object *o = &st->objects[i];
        printf("%s%s%s: x %.1f y %.1f (%gx%g) sprite %d code %03x colour %02x rgb %02x%02x%02x\n",
               ark3d_kind_name(o->kind), o->kind == ARK3D_KIND_CAPSULE ? " " : "",
               o->kind == ARK3D_KIND_CAPSULE ? ark3d_capsule_name(o->capsule) : "",
               o->x, o->y, o->w, o->h, o->sprite, o->code, o->color, o->rgb[0], o->rgb[1], o->rgb[2]);
    }
    printf("score: %d  high score: %d%s\n", st->score, st->high_score, st->flipped ? "  (screen flipped)" : "");
}

int main(int argc, char **argv)
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s capture.bin [-f frame] [--codes] [--heuristic]\n", argv[0]);
        return 2;
    }
    long detail_frame = -1;
    int codes = 0, heuristic = 0;
    for (int i = 2; i < argc; i++)
    {
        if (!strcmp(argv[i], "-f") && i + 1 < argc)
            detail_frame = strtol(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--codes"))
            codes = 1;
        else if (!strcmp(argv[i], "--heuristic"))
            heuristic = 1;          // ignore the verified code tables
    }

    FILE *f = fopen(argv[1], "rb");
    if (f == NULL)
    {
        perror(argv[1]);
        return 1;
    }
    uint8_t hdr[20];
    if (fread(hdr, 1, sizeof(hdr), f) != sizeof(hdr) || memcmp(hdr, "ARK3DCAP", 8) != 0 || rd32(hdr + 8) != 1)
    {
        fprintf(stderr, "%s: not an ark3d capture (version 1)\n", argv[1]);
        return 1;
    }
    uint32_t const gfx_bytes = rd32(hdr + 12), prom_bytes = rd32(hdr + 16);
    uint8_t *gfx = malloc(gfx_bytes ? gfx_bytes : 1), *proms = malloc(prom_bytes ? prom_bytes : 1);
    if (fread(gfx, 1, gfx_bytes, f) != gfx_bytes || fread(proms, 1, prom_bytes, f) != prom_bytes)
    {
        fprintf(stderr, "%s: truncated header\n", argv[1]);
        return 1;
    }

    static ark3d_graphics graphics;
    ark3d_analyze_graphics(&graphics, gfx, gfx_bytes, proms, prom_bytes);
    if (!graphics.valid)
        fprintf(stderr, "warning: no usable gfx1/proms in the capture; decoding without graphics\n");

    static ark3d_calibration calibration;
    ark3d_default_calibration(&calibration);

    // --codes: (code,colour) counts per kind of place, and sprite codes by decoded kind
    static unsigned brick_codes[ARK3D_NUM_CHARS][64];
    static unsigned sprite_codes[ARK3D_NUM_CHARS / 2][ARK3D_KIND_COUNT];

    static record rec;
    static ark3d_state st;
    long n = 0;
    while (read_record(f, &rec))
    {
        ark3d_input in;
        memset(&in, 0, sizeof(in));
        in.videoram = rec.videoram;
        in.spriteram = rec.spriteram;
        in.gfxbank = rec.gfxbank;
        in.palettebank = rec.palettebank;
        in.flip_x = rec.flip_x;
        in.flip_y = rec.flip_y;
        in.work_ram = rec.workram;
        in.work_ram_bytes = sizeof(rec.workram);
        ark3d_decode(&in, NULL, graphics.valid ? &graphics : NULL, heuristic ? NULL : &calibration, &st);
        n++;

        if (codes)
        {
            for (int r = 0; r < st.grid_rows; r++)
                for (int c = 0; c < st.grid_cols; c++)
                    if (st.bricks[r][c].kind)
                        brick_codes[st.bricks[r][c].code][st.bricks[r][c].color & 63]++;
            for (int i = 0; i < st.ball_count; i++)
                sprite_codes[st.balls[i].code][ARK3D_KIND_BALL]++;
            for (int i = 0; i < st.object_count; i++)
                sprite_codes[st.objects[i].code][st.objects[i].kind]++;
        }
        else if (detail_frame >= 0)
        {
            if ((long)rec.frame == detail_frame)
            {
                printf("frame %u  gfxbank %d palettebank %d flip %d,%d\n", rec.frame, rec.gfxbank, rec.palettebank, rec.flip_x, rec.flip_y);
                print_detail(&st);
                break;
            }
        }
        else
        {
            static const char *const phase[] = { "(none)", "", "appearing", "exploding" };
            printf("frame %6u bricks %3d vaus %s%6.1f w%5.1f balls %d", rec.frame, st.brick_count,
                   phase[st.vaus_phase & 3], st.vaus_x, st.vaus_w, st.ball_count);
            for (int i = 0; i < st.ball_count; i++)
                printf(" (%.0f,%.0f)", st.balls[i].x, st.balls[i].y);
            for (int i = 0; i < st.object_count; i++)
                printf(" %s%s", ark3d_kind_name(st.objects[i].kind),
                       st.objects[i].kind == ARK3D_KIND_CAPSULE ? ark3d_capsule_name(st.objects[i].capsule) : "");
            printf(" score %d hi %d\n", st.score, st.high_score);
        }
    }
    fclose(f);

    if (codes)
    {
        printf("%ld frames\nbrick cells: left-tile code/colour -> frames seen\n", n);
        for (int c = 0; c < ARK3D_NUM_CHARS; c++)
            for (int k = 0; k < 64; k++)
                if (brick_codes[c][k])
                    printf("  %03x/%02x %u\n", c, k, brick_codes[c][k]);
        printf("sprite codes -> decoded kind: frames\n");
        for (int c = 0; c < ARK3D_NUM_CHARS / 2; c++)
        {
            int any = 0;
            for (int k = 0; k < ARK3D_KIND_COUNT; k++)
                any |= sprite_codes[c][k] != 0;
            if (!any)
                continue;
            printf("  %03x", c);
            for (int k = 0; k < ARK3D_KIND_COUNT; k++)
                if (sprite_codes[c][k])
                    printf(" %s:%u", ark3d_kind_name(k), sprite_codes[c][k]);
            putchar('\n');
        }
    }
    free(gfx);
    free(proms);
    return 0;
}
