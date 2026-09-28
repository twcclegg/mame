-- license:BSD-3-Clause
--
-- ark3d_bot.lua - plays arkanoid unattended, for capturing real gameplay
-- (with ark3d_capture.lua) and for checking the paddle control loop:
--
--   ARK3D_CAPTURE=visionos/arkanoid3d/lua/ark3d_capture.lua ARK3D_OUT=cap.bin ARK3D_FRAMES=20000 \
--     mame arkanoid -video none -sound none -nothrottle -autoboot_script visionos/arkanoid3d/lua/ark3d_bot.lua
--
-- It inserts a coin and starts a game whenever no Vaus is on screen, fires
-- every 20 frames (launch / laser), and steers the Vaus under the ball, aiming
-- a little off-centre so the ball doesn't loop.  Steering is the same closed
-- loop as App/PaddleController.swift: it owns the spinner counter through
-- the analog override (what libmame's myosd_set_analog_input sets) and
-- learns the px/count ratio as it goes.  It's a plumbing tool, not a good
-- player: it rarely clears a round.
--
-- Environment variables:
--   ARK3D_CAPTURE     path of ark3d_capture.lua to run alongside (optional)
--   ARK3D_SNAPS       space-separated frame numbers to take snapshots at
--   ARK3D_SNAP_EVERY  also take a snapshot every N frames
--
-- Sprite codes are the verified ones from Decoder/ark3d.c
-- (ark3d_default_calibration): the ball is 1b8, the Vaus's sprites sit at
-- y 232, and drop shadows use colour 8.

if os.getenv("ARK3D_CAPTURE") then
	dofile(os.getenv("ARK3D_CAPTURE"))
end

local machine = manager.machine
local ports = machine.ioport.ports
local function field(port, pattern)
	for _, f in pairs(ports[port].fields) do
		if f.name:find(pattern) then return f end
	end
	error("ark3d_bot: no field " .. pattern .. " in " .. port .. "; is this the arkanoid driver?")
end
local coin = field(":SYSTEM", "Coin 1")
local start = field(":SYSTEM", "1 Player Start")
local fire = field(":BUTTONS", "Button 1")
local dial = field(":P1", "Dial")
local sram = machine.memory.shares[":spriteram"]
local screen = machine.screens[":screen"]

local snaps = {}
for s in (os.getenv("ARK3D_SNAPS") or ""):gmatch("%d+") do snaps[tonumber(s)] = true end
local snap_every = tonumber(os.getenv("ARK3D_SNAP_EVERY") or "0") or 0

local BALL = 0x1b8
local VAUS_Y = 232
local SHADOW_COLOUR = 8
local FIELD_LEFT, FIELD_RIGHT = 8, 216

local counter, gain = 0, 1.0
local last_x, win_steps, win_move, win_frames = nil, 0, 0, 0
local n, idle, offset = 0, 0, 0
local ball_y_last

-- Vaus extent (sprite cells) and ball centre, ignoring shadows
local function sprites()
	local vx0, vx1, ball_x, ball_y
	for i = 0, 15 do
		local y, x, a, c = sram:read_u8(4 * i), sram:read_u8(4 * i + 1), sram:read_u8(4 * i + 2), sram:read_u8(4 * i + 3)
		if (x ~= 0 or y ~= 0) and (a >> 3) ~= SHADOW_COLOUR then
			local code = c + ((a & 3) << 8)
			local vx = x - 16
			if code == BALL then
				ball_x, ball_y = vx + 8, y
			elseif y == VAUS_Y and code >= 0x0f2 and code <= 0x0ff then
				vx0 = math.min(vx0 or 999, vx)
				vx1 = math.max(vx1 or -999, vx + 16)
			end
		end
	end
	return vx0, vx1, ball_x, ball_y
end

bot_subscription = emu.add_machine_frame_notifier(function()
	n = n + 1
	local frame = screen:frame_number()
	if snaps[frame] or (snap_every > 0 and frame % snap_every == 0) then machine.video:snapshot() end

	local vx0, vx1, ball_x, ball_y = sprites()

	-- no Vaus for a while: attract mode or game over, so insert a coin and start
	idle = vx0 and 0 or idle + 1
	local cycle = idle % 400
	coin:set_value((idle > 200 and cycle >= 200 and cycle < 206) and 1 or 0)
	start:set_value((idle > 200 and cycle >= 260 and cycle < 266) and 1 or 0)
	fire:set_value((n % 20 < 3) and 1 or 0)

	if not vx0 then
		last_x = nil
		return
	end
	local vx = (vx0 + vx1) / 2
	local half = (vx1 - vx0) / 2

	-- a new random aim offset each time the ball starts coming down
	if ball_y and ball_y_last then
		if ball_y < ball_y_last then
			offset = 0
		elseif ball_y > ball_y_last and offset == 0 then
			offset = (math.random() * 2 - 1) * half * 0.7
		end
	end
	ball_y_last = ball_y
	local goal = ball_x and (ball_x - offset) or 112
	goal = math.max(FIELD_LEFT + half, math.min(FIELD_RIGHT - half, goal))

	-- learn px/count, magnitude only (see PaddleController.swift)
	if last_x then
		win_move = win_move + (vx - last_x)
		win_frames = win_frames + 1
		if win_frames >= 8 then
			if math.abs(win_steps) >= 8 and vx > FIELD_LEFT + half + 2 and vx < FIELD_RIGHT - half - 2 then
				local m = win_move / win_steps
				if m > 0.25 and m < 4 then gain = gain * 0.6 + m * 0.4 end
			end
			win_steps, win_move, win_frames = 0, 0, 0
		end
	end
	last_x = vx

	local err = goal - vx
	local step = 0
	if math.abs(err) >= 1 then
		step = math.floor(err / gain * 0.5 + 0.5)
		if step == 0 then step = (err > 0) and 1 or -1 end
		step = math.max(-12, math.min(12, step))
	end
	counter = (counter + step) & 0xff
	win_steps = win_steps + step
	dial:set_value(counter)

	if n % 600 == 0 then
		print(string.format("ark3d_bot: frame %d vaus %.0f (w %d) ball %s goal %.0f gain %.2f", frame, vx, vx1 - vx0,
			ball_x and string.format("%d,%d", ball_x, ball_y) or "-", goal, gain))
	end
end)
