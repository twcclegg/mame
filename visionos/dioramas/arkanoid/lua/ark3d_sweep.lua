-- license:BSD-3-Clause
--
-- ark3d_sweep.lua - TEST ONLY: walks through the rounds for captures.  Run
-- it with ark3d_bot.lua (which inserts coins, starts and steers) and
-- ark3d_capture.lua, e.g. from a wrapper script:
--
--   dofile("visionos/dioramas/arkanoid/lua/ark3d_bot.lua")    -- loads the capture too, via ARK3D_CAPTURE
--   dofile("visionos/dioramas/arkanoid/lua/ark3d_sweep.lua")
--
-- After SWEEP_PLAY frames with the Vaus in play it sets the game's
-- bricks-remaining counter (ed83) to 0, and the game clears the round.  It
-- also holds the lives at 3 (every byte that counts them down: c006, e8a8,
-- ed71, ed76), so the sweep never ends in a game over.  This changes the
-- game's state: never use it for anything but captures.
--
-- Environment variables:
--   SWEEP_PLAY    frames of play before clearing a round (default 40)
--   SWEEP_ROUNDS  how many rounds to clear (default 31: stops on round 32;
--                 32 reaches DOH, round 33).  Some clears don't advance the
--                 round, so the count can run ahead: ark3d_doh.lua stops the
--                 sweep by setting the global ark3d_sweep_stop instead
--
-- It sets the global ark3d_sweep_cleared to the count so far.

local mem = manager.machine.devices[":maincpu"].spaces["program"]
local sram = manager.machine.memory.shares[":spriteram"]
local play_for = tonumber(os.getenv("SWEEP_PLAY")) or 40
local rounds = tonumber(os.getenv("SWEEP_ROUNDS")) or 31
local played, cleared = 0, 0

-- the Vaus in play: its sprites at y 232 (not the shadow, colour 8)
local function vaus_up()
	for i = 0, 15 do
		local y, a, c = sram:read_u8(4 * i), sram:read_u8(4 * i + 2), sram:read_u8(4 * i + 3)
		local code = c + ((a & 3) << 8)
		if y == 232 and (a >> 3) ~= 8 and ((code >= 0xf2 and code <= 0x105) or code == 0xbe) then return true end
	end
	return false
end

sweep_subscription = emu.add_machine_frame_notifier(function()
	for _, a in ipairs({ 0xc006, 0xe8a8, 0xed71, 0xed76 }) do
		local v = mem:read_u8(a)
		if v >= 1 and v < 3 then mem:write_u8(a, 3) end
	end
	if cleared >= rounds or _G.ark3d_sweep_stop or not vaus_up() then return end
	played = played + 1
	if played >= play_for then
		mem:write_u8(0xed83, 0)
		played = -600               -- let the round change before counting again
		cleared = cleared + 1
		_G.ark3d_sweep_cleared = cleared
		print("ark3d_sweep: cleared round " .. cleared)
	end
end)
