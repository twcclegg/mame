# ios OSD (libmame)

Imported from [ToddLa/mame](https://github.com/ToddLa/mame) (`src/osd/ios`,
`scripts/src/osd/ios.lua`) at commit `fc040128` (MAME 0.288). This is the
MAME side of [MAME4iOS](https://github.com/yoshisuga/MAME4iOS): MAME built as a
static library, with a host app driving it through the C API in `libmame.h`.

Local changes for this tree (MAME 0.289, visionOS):
- `iosmain.cpp`: vector/LCD detection via `device_video_output_interface`
  (0.289 removed `screen_device::screen_type()`).
- `input.cpp`: include `input.h` (no longer pulled in by `emu.h`).
- `libmame.h` / `video.cpp`: optional `video_draw_pixels` callback (software
  rendered BGRA frame); guard against an empty primitive list; include
  `<stddef.h>` so the header is self-contained.
- `paste.mm`: clipboard on visionOS as well as iOS.

Build for visionOS with `make visionos-libmame` / `visionos-sim-libmame`, or
`visionos/make-libmame.sh`. See `visionos/README.md`.
