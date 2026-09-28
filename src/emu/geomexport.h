// license:BSD-3-Clause
// copyright-holders:MAMEdev Team
/***************************************************************************

    geomexport.h

    Optional export of a driver's 3D scene geometry to the OSD/host, so a
    host can re-render it itself (at any resolution, in stereo, ...)
    instead of, or as well as, using the driver's software rasterizer.

    Drivers opt in by calling geometry_export::get_sink() and, when it returns
    non-null, handing it their camera-space polygons just before they would
    project and rasterize them.  With no sink registered this costs one
    pointer test per batch.

    Coordinate conventions for everything passed to a sink:
      - camera (view) space: +x right, +y up, +z forward (away from the
        viewer); z > 0 for anything visible
      - projection to screen pixels:
            screen_x = center_x + (x / z) * scale_x + offset_x
            screen_y = center_y - ((y / z) * scale_y + offset_y)
        within [clip_min, clip_max] of a screen of screen_width x screen_height

***************************************************************************/

#ifndef MAME_EMU_GEOMEXPORT_H
#define MAME_EMU_GEOMEXPORT_H

#pragma once

#include <cstddef>
#include <cstdint>


namespace emu::geometry_export {

struct vertex
{
	float x, y, z;              // camera space
};

struct projection
{
	float center_x, center_y;   // screen-space centre of projection
	float scale_x, scale_y;     // focal length in pixels
	float offset_x, offset_y;   // additional pixel offset
	int clip_min_x, clip_min_y; // visible viewport (inclusive)
	int clip_max_x, clip_max_y;
	int screen_width, screen_height;
};

enum polygon_flags : uint32_t
{
	POLY_FLAG_MOIRE     = 1 << 0,   // stippled / translucent (e.g. Model 1 shadows)
	POLY_FLAG_WIREFRAME = 1 << 1,   // a line: only v[0] and v[2] are meaningful
};

struct polygon
{
	vertex v[4];                // 3 or 4 vertices (count), in drawing order
	int count;
	uint32_t rgb;               // 0x00RRGGBB, already lit/shaded by the game
	uint32_t flags;             // polygon_flags
	float sort_z;               // the driver's own depth-sort key (larger = further)
};

class sink
{
public:
	virtual ~sink() = default;

	// One batch of polygons sharing a projection, in the driver's draw order.
	// A frame may contain several batches (e.g. separate viewports).
	virtual void polygons(const projection &proj, const polygon *polys, std::size_t count) = 0;

	// If true, the driver should skip rasterizing the exported polygons itself
	// (its 2D layers are still drawn), so the host can composite its own 3D.
	virtual bool suppress_native_rendering() const { return false; }
};

// one emulated machine per process: a single global sink is enough
inline sink *g_sink = nullptr;

inline sink *get_sink() { return g_sink; }
inline void set_sink(sink *s) { g_sink = s; }

} // namespace emu::geometry_export

#endif // MAME_EMU_GEOMEXPORT_H
