-- license:BSD-3-Clause
--
-- ark3d_capture.lua - record the state the visionOS 3D Arkanoid app reads,
-- from a real arkanoid run in MAME, for checking the decoder offline:
--
--   mame arkanoid -autoboot_script visionos/dioramas/arkanoid/lua/ark3d_capture.lua
--   make -C visionos/dioramas/arkanoid/Tests dump
--   visionos/dioramas/arkanoid/Tests/build/ark3d_dump ark3d_capture.bin [-f N | --codes]
--
-- It reads exactly what the app reads through libmame (myosd_* in
-- src/osd/ios/libmame.h), in the same order: the gfx1 and proms regions once,
-- then every frame the videoram and spriteram shares, main CPU RAM
-- c000-c7ff, and the driver's latched d008 bits (flip, gfx bank, palette
-- bank) from its save-state items.  The file format is documented in
-- Tests/ark3d_dump.c.
--
-- Environment variables:
--   ARK3D_OUT     output file            (default ark3d_capture.bin)
--   ARK3D_EVERY   keep every Nth frame   (default 1)
--   ARK3D_FRAMES  stop after N frames    (default: run until MAME exits)
--   ARK3D_LOG     print a one-line summary every N frames (default 60, 0 = off)
--   ARK3D_INJECT  TESTING ONLY: a file of videoram (0x800) + spriteram (0x40)
--                 bytes written into the shares before every capture, for the
--                 end-to-end test (Tests/run_e2e.sh) with placeholder ROMs
--
-- Works with any MAME whose Lua API has manager.machine.memory.shares and
-- emu.add_machine_frame_notifier (0.227 and later).

local out_path = os.getenv("ARK3D_OUT") or "ark3d_capture.bin"
local every = tonumber(os.getenv("ARK3D_EVERY") or "1") or 1
local max_frames = tonumber(os.getenv("ARK3D_FRAMES") or "0") or 0
local log_every = tonumber(os.getenv("ARK3D_LOG") or "60") or 60
local inject_path = os.getenv("ARK3D_INJECT")

local machine = manager.machine
local memory = machine.memory

local function need(what, value)
	if not value then
		error("ark3d_capture: " .. what .. " not found; is this the arkanoid driver (taito/arkanoid.cpp)?")
	end
	return value
end

local videoram = need(":videoram share", memory.shares[":videoram"])
local spriteram = need(":spriteram share", memory.shares[":spriteram"])
local program = need(":maincpu program space", machine.devices[":maincpu"].spaces["program"])
local gfx1 = memory.regions[":gfx1"]
local proms = memory.regions[":proms"]

-- the driver's save_item()s: arkanoid_state (tag ":") registers m_gfxbank,
-- m_palettebank; driver_device registers m_flip_screen_x/y (index 0)
local items = machine.devices[":"].items
local function item(name)
	local index = items["0/" .. name]
	return index and emu.item(index) or nil
end
local gfxbank = item("m_gfxbank")
local palettebank = item("m_palettebank")
local flip_x = item("m_flip_screen_x")
local flip_y = item("m_flip_screen_y")
for name, it in pairs({ m_gfxbank = gfxbank, m_palettebank = palettebank, m_flip_screen_x = flip_x, m_flip_screen_y = flip_y }) do
	if not it then
		print("ark3d_capture: warning: save item " .. name .. " not found, recording 0")
	end
end
local function read_item(it) return it and (it:read(0) & 0xff) or 0 end

local function share_bytes(share, count)
	local t = {}
	for i = 0, count - 1 do
		t[#t + 1] = string.char(share:read_u8(i))
	end
	return table.concat(t)
end

local function region_bytes(region)
	if not region then return "" end
	local t = {}
	for i = 0, region.size - 1 do
		t[#t + 1] = string.char(region:read_u8(i))
	end
	return table.concat(t)
end

local file = need("output file " .. out_path, io.open(out_path, "wb"))
local gfx_data, prom_data = region_bytes(gfx1), region_bytes(proms)
file:write("ARK3DCAP", string.pack("<I4I4I4", 1, #gfx_data, #prom_data), gfx_data, prom_data)
print(string.format("ark3d_capture: writing %s (gfx1 %d bytes, proms %d bytes)", out_path, #gfx_data, #prom_data))

local inject
if inject_path then
	local f = need("inject file " .. inject_path, io.open(inject_path, "rb"))
	inject = f:read("a")
	f:close()
	if #inject ~= 0x840 then error("ark3d_capture: inject file must be 0x840 bytes") end
	print("ark3d_capture: TEST MODE, injecting " .. inject_path .. " into videoram/spriteram every frame")
end
local function do_inject()
	for i = 0, 0x7ff do videoram:write_u8(i, inject:byte(i + 1)) end
	for i = 0, 0x3f do spriteram:write_u8(i, inject:byte(0x800 + i + 1)) end
end

local screen = machine.screens[":screen"]
local seen, written = 0, 0

-- a quick look without the decoder: visible sprites as (view x, view y, code)
local function sprite_summary(sram)
	local parts = {}
	for i = 0, 15 do
		local b0, b1, b2, b3 = sram:byte(4 * i + 1, 4 * i + 4)
		if b0 ~= 0 or b1 ~= 0 then
			local code = b3 + ((b2 & 3) << 8)
			parts[#parts + 1] = string.format("%d,%d:%03x", b1 - 16, b0, code)
		end
	end
	return table.concat(parts, " ")
end

subscription = emu.add_machine_frame_notifier(function()
	seen = seen + 1
	if (seen - 1) % every ~= 0 then return end
	if max_frames > 0 and written >= max_frames then return end

	if inject then do_inject() end
	local frame = screen and screen:frame_number() or seen
	local vram = share_bytes(videoram, 0x800)
	local sram = share_bytes(spriteram, 0x40)
	local wram = program:read_range(0xc000, 0xc7ff, 8)
	file:write("FRME", string.pack("<I4BBBB", frame & 0xffffffff,
		read_item(gfxbank), read_item(palettebank), read_item(flip_x), read_item(flip_y)),
		vram, sram, wram)
	written = written + 1

	if log_every > 0 and written % log_every == 0 then
		print(string.format("ark3d_capture: frame %d  bank %d/%d flip %d/%d  sprites %s",
			frame, read_item(gfxbank), read_item(palettebank), read_item(flip_x), read_item(flip_y),
			sprite_summary(sram)))
		file:flush()
	end
	if max_frames > 0 and written >= max_frames then
		file:close()
		print(string.format("ark3d_capture: %d frames written, exiting", written))
		machine:exit()
	end
end)

stop_subscription = emu.add_machine_stop_notifier(function()
	if io.type(file) == "file" then
		file:close()
		print(string.format("ark3d_capture: %d frames written to %s", written, out_path))
	end
end)
