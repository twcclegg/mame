# ios OSD (libmame)

Imported from [ToddLa/mame](https://github.com/ToddLa/mame) (`src/osd/ios`,
`scripts/src/osd/ios.lua`) at commit `fc040128` (MAME 0.288). This is the
MAME side of [MAME4iOS](https://github.com/yoshisuga/MAME4iOS): MAME built as a
static library, with a host app driving it through the C API in `libmame.h`.

Local changes for this tree (MAME 0.289, visionOS):
- `iosmain.cpp`: vector/LCD detection via `device_video_output_interface`
  (0.289 removed `screen_device::screen_type()`).
- `input.cpp`: include `input.h` (no longer pulled in by `emu.h`).
- `libmame.h` / `video.cpp`: optional `video_draw_pixels` callback: a
  software-rendered BGRA frame at native resolution x an integer scale, plus
  native size and display aspect (`myosd_video_frame`); guard against an empty
  primitive list; include `<stddef.h>` so the header is self-contained.
- `paste.mm`: clipboard on visionOS as well as iOS.
- `myosd_set` additions, applied on the MAME thread: `MYOSD_PAUSE` (pause and
  flush NVRAM, never undoing a user pause), `MYOSD_ZOOM_TO_SCREEN` and
  `MYOSD_SUPPRESS_NATIVE_3D`.  `running_machine::nvram_save()` was made public
  for the NVRAM flush.
- Optional `geometry_frame` callback: 3D polygons exported by drivers through
  `src/emu/geomexport.h` (`ios_geometry_sink` in `iososd.h`).  Sega Model 1
  is the first driver to export.

Build for visionOS with `make visionos-libmame` / `visionos-sim-libmame`, or
`visionos/make-libmame.sh`. See `visionos/README.md`.
