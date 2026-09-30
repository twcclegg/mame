// license:BSD-3-Clause
//
// ark3d_export - decoded game state as JSON lines, one per frame, for
// renderers outside this app (e.g. the Godot diorama).  It carries only the
// decoded state (no ROM graphics), so traces can live in a repository.
//
//   ark3d_export capture.bin [first last] [--ram high.bin] > trace.jsonl
//
// --ram adds e840-efff per frame (u32 frame, then 0x7c0 bytes, as written by
// a test script), which DOH's hit count needs; without it "hits" is -1.
//
// Each line (view pixels: 224 wide, 256 tall, y down; see ark3d.h):
//   {"f":frame, "play":0|1,
//    "bricks":[[row,col,kind,"rrggbb",hit],...],   kind: 4 brick, 5 silver, 6 gold; hit 1 while silver flashes
//    "vaus":{"x","y","w","phase","laser"} or null, phase: 1 normal, 2 appearing, 3 exploding
//    "balls":[[x,y],...],
//    "objs":[[kind,x,y,w,h,"rrggbb",capsule,enemy],...],  kind: 11 capsule, 12 enemy, 13 laser, 14 explosion
//    "banner":[round,ready], "gates":[left,right], "warp":w,
//    "score":s, "hi":h, "lives":spare,
//    "doh":null or {"phase","x","y","w","h","hits","hits_max","flash","mouth"}}
//    DOH phase: 1 alive, 2 dying, 3 gone (hole in the wall), 4 ending screen;
//    DOH projectiles are objs of kind 18.
// Capsule letters: 1 S, 2 C, 3 L, 4 E, 5 D, 6 B, 7 P.  Enemy types: 1 molecule,
// 2 cube, 3 pyramid, 4 cone.  Grid: 13 columns, cell (col,row) spans view
// x 8+16col..+16, y 24+8row..+8.

#include "ark3d.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

int main(int argc, char **argv)
{
    const char *ram_path = NULL;
    for (int i = 1; i + 1 < argc; i++)
        if (strcmp(argv[i], "--ram") == 0)
        {
            ram_path = argv[i + 1];
            for (int j = i; j + 2 < argc; j++)
                argv[j] = argv[j + 2];
            argc -= 2;
            break;
        }
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s capture.bin [first last] [--ram high.bin]\n", argv[0]);
        return 2;
    }
    long first = argc > 3 ? strtol(argv[2], NULL, 0) : 0, last = argc > 3 ? strtol(argv[3], NULL, 0) : 0x7fffffff;
    FILE *ram = ram_path ? fopen(ram_path, "rb") : NULL;
    if (ram_path && ram == NULL) { perror(ram_path); return 1; }
    static uint8_t high[4 + 0x7c0];
    int have_high = 0;
    int doh_gone = 0;           // DOH's hole was on screen: the story screen after it is the ending
    ark3d_doh doh_last;         // DOH as last seen, and how many frames ago
    int doh_missing = 1000;
    FILE *f = fopen(argv[1], "rb");
    if (f == NULL) { perror(argv[1]); return 1; }
    uint8_t hdr[20];
    if (fread(hdr, 1, sizeof(hdr), f) != sizeof(hdr) || memcmp(hdr, "ARK3DCAP", 8) != 0) { fprintf(stderr, "not a capture\n"); return 1; }
    uint32_t const gfx_bytes = rd32(hdr + 12), prom_bytes = rd32(hdr + 16);
    uint8_t *gfx = malloc(gfx_bytes), *proms = malloc(prom_bytes);
    if (fread(gfx, 1, gfx_bytes, f) != gfx_bytes || fread(proms, 1, prom_bytes, f) != prom_bytes) { fprintf(stderr, "truncated\n"); return 1; }

    static ark3d_graphics graphics;
    static ark3d_calibration cal;
    static ark3d_state st;
    ark3d_analyze_graphics(&graphics, gfx, gfx_bytes, proms, prom_bytes);
    ark3d_default_calibration(&cal);

    static uint8_t rec[12 + ARK3D_VIDEORAM_BYTES + ARK3D_SPRITERAM_BYTES + 0x800];
    while (fread(rec, 1, sizeof(rec), f) == sizeof(rec))
    {
        long const frame = (long)rd32(rec + 4);
        if (frame < first) continue;
        if (frame > last) break;
        ark3d_input in;
        memset(&in, 0, sizeof(in));
        in.gfxbank = rec[8]; in.palettebank = rec[9]; in.flip_x = rec[10]; in.flip_y = rec[11];
        in.videoram = rec + 12;
        in.spriteram = rec + 12 + ARK3D_VIDEORAM_BYTES;
        in.work_ram = rec + 12 + ARK3D_VIDEORAM_BYTES + ARK3D_SPRITERAM_BYTES;
        in.work_ram_bytes = 0x800;
        // the side file has one record per frame too: catch up to this one
        while (ram && (!have_high || (long)rd32(high) < frame))
            if (fread(high, 1, sizeof(high), ram) == sizeof(high)) have_high = 1;
            else { fclose(ram); ram = NULL; have_high = 0; }
        if (have_high && (long)rd32(high) == frame)
        {
            in.high_ram = high + 4;
            in.high_ram_bytes = 0x7c0;
        }
        ark3d_decode(&in, NULL, graphics.valid ? &graphics : NULL, &cal, &st);

        printf("{\"f\":%ld,\"play\":%d,\"bricks\":[", frame, st.in_play);
        int n = 0;
        for (int r = 0; r < st.grid_rows; r++)
            for (int c = 0; c < st.grid_cols; c++)
            {
                const ark3d_brick *b = &st.bricks[r][c];
                if (!b->kind) continue;
                // [game] a silver brick's tiles leave 16e while the game animates a hit or its shimmer
                int const hit = b->kind == ARK3D_KIND_BRICK_SILVER && b->code != 0x16e;
                printf("%s[%d,%d,%d,\"%02x%02x%02x\",%d]", n++ ? "," : "", r, c, b->kind, b->rgb[0], b->rgb[1], b->rgb[2], hit);
            }
        printf("],\"vaus\":");
        if (st.vaus_visible)
            printf("{\"x\":%.1f,\"y\":%.1f,\"w\":%.1f,\"phase\":%d,\"laser\":%d}", st.vaus_x, st.vaus_y, st.vaus_w, st.vaus_phase, st.vaus_laser);
        else
            printf("null");
        printf(",\"balls\":[");
        for (int i = 0; i < st.ball_count; i++)
            printf("%s[%.1f,%.1f]", i ? "," : "", st.balls[i].x, st.balls[i].y);
        printf("],\"objs\":[");
        int m = 0;
        for (int i = 0; i < st.object_count; i++)
        {
            const ark3d_object *o = &st.objects[i];
            if (o->kind == ARK3D_KIND_OTHER) continue;
            printf("%s[%d,%.1f,%.1f,%.1f,%.1f,\"%02x%02x%02x\",%d,%d]", m++ ? "," : "", o->kind, o->x, o->y, o->w, o->h,
                   o->rgb[0], o->rgb[1], o->rgb[2], o->capsule, o->kind == ARK3D_KIND_ENEMY ? ark3d_enemy_type(o->code) : 0);
        }
        printf("],\"banner\":[%d,%d],\"gates\":[%.2f,%.2f],\"warp\":%.2f,\"score\":%d,\"hi\":%d,\"lives\":%d,\"doh\":",
               st.banner_round, st.banner_ready, st.gate_open[0], st.gate_open[1], st.warp_open, st.score, st.high_score, st.spare_lives);
        // the decoder is per frame and can't tell the ending from the intro
        // story (the same kind of screen); here, it's the one that follows DOH
        if (st.doh.phase == ARK3D_DOH_GONE)
            doh_gone = 1;
        else if (st.doh.phase != ARK3D_DOH_NONE || st.in_play)
            doh_gone = 0;
        else if (doh_gone)
        {
            st.doh.phase = ARK3D_DOH_ENDING;
            st.doh.hits = st.doh.hits_max = 16;
        }
        // the game wipes and redraws the round after the Vaus is lost, which
        // hides DOH for a few frames: keep it (a renderer would flicker)
        if (st.doh.phase != ARK3D_DOH_NONE)
            doh_last = st.doh, doh_missing = 0;
        else if (++doh_missing <= 12 && doh_last.phase == ARK3D_DOH_ALIVE)
        {
            st.doh = doh_last;
            st.doh.flash = 0;
        }
        if (st.doh.phase != ARK3D_DOH_NONE)
            printf("{\"phase\":%d,\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f,\"hits\":%d,\"hits_max\":%d,\"flash\":%d,\"mouth\":%.2f}}\n",
                   st.doh.phase, st.doh.x, st.doh.y, st.doh.w, st.doh.h, st.doh.hits, st.doh.hits_max, st.doh.flash, st.doh.mouth);
        else
            printf("null}\n");
    }
    fclose(f);
    if (ram) fclose(ram);
    free(gfx);
    free(proms);
    return 0;
}
