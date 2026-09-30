-- license:BSD-3-Clause
--
-- ark3d_doh.lua - TEST ONLY: records a fight with DOH (round 33) for the
-- decoder's DOH support and the trace in the private dioramas repository.
--
--   ARK3D_CAPTURE=visionos/dioramas/arkanoid/lua/ark3d_capture.lua ARK3D_OUT=doh.bin \
--   SWEEP_ROUNDS=60 mame arkanoid -video none -sound none -nothrottle \
--     -autoboot_script visionos/dioramas/arkanoid/lua/ark3d_doh.lua
--
-- It runs ark3d_bot.lua (with the capture) and ark3d_sweep.lua, stops the
-- sweep when DOH's round is on screen, and plays the fight.  Besides the
-- capture it writes DOH_RAM (default doh_ram.bin): per frame a u32 frame
-- number and e840-efff (0x7c0 bytes), which holds DOH's hit count (ed6b)
-- and is outside the capture's work RAM; ark3d_export --ram reads it.
--
-- The bot rarely lands 16 hits in one life, and the game resets DOH's count
-- when the Vaus is lost, so this puts the count back after a lost life
-- (up to 15: the last hit is the bot's own).  With the sweep's lives
-- held, that changes the game's state: use it only for captures.  It exits
-- 3000 frames after the 16th hit (the death and the ending), or if the
-- machine resets (which would reopen the capture).
--
-- Environment variables:
--   ARK3D_LUA     directory of these scripts (default visionos/dioramas/arkanoid/lua)
--   DOH_RAM       the e840-efff side file (default doh_ram.bin)
--   DOH_SNAPS     1: a snapshot every 30 frames during the fight

if _G.ark3d_doh_loaded then manager.machine:exit() return end
_G.ark3d_doh_loaded = true

local dir = os.getenv("ARK3D_LUA") or "visionos/dioramas/arkanoid/lua"
dofile(dir .. "/ark3d_bot.lua")
dofile(dir .. "/ark3d_sweep.lua")

local mem = manager.machine.devices[":maincpu"].spaces["program"]
local vram = manager.machine.memory.shares[":videoram"]
local screen = manager.machine.screens[":screen"]
local out = assert(io.open(os.getenv("DOH_RAM") or "doh_ram.bin", "wb"))
local snaps = os.getenv("DOH_SNAPS") == "1"
local seen, hits, killed = nil, 0, nil

-- DOH's face: its top-left tile, view (10, 7) = tilemap 19*32+7, is one of
-- 5ce/62e/68e/6ee in colour 16 (31 in a hit's flash); see ARKANOID_STATE.md §11
local function doh_on_screen()
	local i = 2 * (19 * 32 + 7)
	local b0, b1 = vram:read_u8(i), vram:read_u8(i + 1)
	local code, colour = b1 + ((b0 & 7) << 8), b0 >> 3
	return (code - 0x5ce) % 0x60 == 0 and code >= 0x5ce and code <= 0x6ee and (colour == 16 or colour == 31)
end

ark3d_doh_subscription = emu.add_machine_frame_notifier(function()
	local f = screen:frame_number()
	local t = { string.pack("<I4", f) }
	for a = 0xe840, 0xefff do t[#t + 1] = string.char(mem:read_u8(a)) end
	out:write(table.concat(t))

	if not seen and doh_on_screen() then
		seen = f
		_G.ark3d_sweep_stop = true
		print(string.format("ark3d_doh: DOH at frame %d", f))
	end
	if not seen then return end

	local h = mem:read_u8(0xed6b)
	if h == 0 and hits > 0 and hits <= 15 and not killed then
		mem:write_u8(0xed6b, hits)
		h = hits
	end
	if h ~= hits then print(string.format("ark3d_doh: frame %d hits %d", f, h)) end
	if h >= 16 and not killed then killed = f end
	hits = h
	if snaps and (f - seen) % 30 == 0 then screen:snapshot(string.format("doh_%07d.png", f)) end
	if killed and f - killed > 3000 then
		print("ark3d_doh: done")
		out:close()
		manager.machine:exit()
	end
end)
