// license:BSD-3-Clause
//
// ark3d_synth - files for an end-to-end plumbing test through real MAME
// without the real ROM:
//
//   ark3d_synth OUTDIR
//     OUTDIR/arkanoid/*      placeholder ROM files with the right names and
//                            sizes: zeros for the program and MCU (the Z80 just
//                            runs NOPs), synthetic.h's graphics and palette for
//                            gfx1 and proms.  MAME runs them with a "wrong
//                            checksum" warning.
//     OUTDIR/inject.bin      videoram (0x800) + spriteram (0x40) of the test
//                            scene, for ark3d_capture.lua's ARK3D_INJECT
//
// Then run_e2e.sh runs MAME with them and checks what ark3d_dump decodes.
// This checks the capture script, share/region/save-item names and the file
// format against a real MAME build -- not the game's graphics, which only a
// real ROM can.

#include "synthetic.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

static int write_file(const char *dir, const char *name, const uint8_t *data, size_t bytes)
{
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (f == NULL || fwrite(data, 1, bytes, f) != bytes)
    {
        perror(path);
        return -1;
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s OUTDIR\n", argv[0]);
        return 2;
    }
    char romdir[1024];
    snprintf(romdir, sizeof(romdir), "%s/arkanoid", argv[1]);
    mkdir(argv[1], 0755);
    mkdir(romdir, 0755);

    build_graphics();
    build_screen();
    build_scene();

    // file names and sizes from ROM_START( arkanoid ) in src/mame/taito/arkanoid.cpp
    static uint8_t zeros[0x8000];
    int err = 0;
    err |= write_file(romdir, "a75__01-1.ic17", zeros, 0x8000);
    err |= write_file(romdir, "a75__11.ic16", zeros, 0x8000);
    err |= write_file(romdir, "a75__06.ic14", zeros, 0x800);
    err |= write_file(romdir, "a75__03.ic64", gfx + 0x00000, 0x8000);
    err |= write_file(romdir, "a75__04.ic63", gfx + 0x08000, 0x8000);
    err |= write_file(romdir, "a75__05.ic62", gfx + 0x10000, 0x8000);
    err |= write_file(romdir, "a75-07.ic24", proms + 0x000, 0x200);
    err |= write_file(romdir, "a75-08.ic23", proms + 0x200, 0x200);
    err |= write_file(romdir, "a75-09.ic22", proms + 0x400, 0x200);
    // alternative MCU dumps and the 68705P5 device's bootstrap (see mame -listroms arkanoid)
    err |= write_file(romdir, "arkanoid_mcu.ic14", zeros, 0x800);
    err |= write_file(romdir, "a75-06__bootleg_68705.ic14", zeros, 0x800);
    err |= write_file(romdir, "arkanoid1_68705p3.ic14", zeros, 0x800);
    err |= write_file(romdir, "bootstrap.bin", zeros, 115);

    static uint8_t inject[ARK3D_VIDEORAM_BYTES + ARK3D_SPRITERAM_BYTES];
    memcpy(inject, videoram, ARK3D_VIDEORAM_BYTES);
    memcpy(inject + ARK3D_VIDEORAM_BYTES, spriteram, ARK3D_SPRITERAM_BYTES);
    err |= write_file(argv[1], "inject.bin", inject, sizeof(inject));
    return err ? EXIT_FAILURE : EXIT_SUCCESS;
}
