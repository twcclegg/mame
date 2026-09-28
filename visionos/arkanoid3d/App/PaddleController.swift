// license:BSD-3-Clause
//
// PaddleController - moves the Vaus to where the player points.
//
// Arkanoid's spinner is a relative control (IPT_DIAL, 8-bit counter on ports
// P1/P2, read by the 68705 MCU), so there's no "set the paddle to x".  Instead
// we own the counter: each emulated frame we compare the Vaus position (from
// sprite RAM) with the target and turn the error into counter steps, written
// with myosd_set_analog_input.  That overrides the controller mapping MAME
// would otherwise use for the dial, so the stick and d-pad are handled here
// too (as target velocity).
//
// How many pixels the Vaus moves per count, and in which direction, depends
// on the game's program; it's measured while playing (px/count over a window
// of frames) rather than assumed.  Starts at +1 px/count.  UNVERIFIED on
// hardware: the default step limits may need tuning (README "Next steps").

import Foundation
import GameController
import libmame

final class PaddleController: @unchecked Sendable {
    enum Source: Int, CaseIterable, Identifiable {
        case controller     // stick / d-pad only
        case pinch          // look at the field, pinch and drag
        case hand           // right index fingertip (immersive space only)
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .controller: return "Controller"
            case .pinch: return "Pinch & drag"
            case .hand: return "Hand"
            }
        }
    }

    private let lock = NSLock()
    private var _source: Source = .pinch
    private var pointerTarget: Float?           // view px, from a gesture or the hand

    var source: Source {
        get { lock.lock(); defer { lock.unlock() }; return _source }
        set { lock.lock(); _source = newValue; pointerTarget = nil; lock.unlock() }
    }

    /// Set from the main thread (gesture / hand tracking); nil when released.
    func setPointerTarget(_ viewX: Float?) {
        lock.lock(); pointerTarget = viewX; lock.unlock()
    }

    // MAME-thread state
    private var target: Float?
    private var counter: Int32 = 0
    private var gain: Float = 1                 // measured px per count (signed)
    private var windowSteps: Int32 = 0
    private var windowMove: Float = 0
    private var windowFrames = 0
    private var lastVausX: Float?

    static let stickSpeed: Float = 4            // px per frame at full deflection
    static let maxStep: Int32 = 12              // counts per frame
    static let ports = [":P1", ":P2"]          // P2 is the cocktail player's spinner

    func reset() {
        target = nil
        lastVausX = nil
        windowSteps = 0; windowMove = 0; windowFrames = 0
    }

    /// Called on the MAME thread once per frame, after decoding.
    func frame(state: UnsafePointer<ark3d_state>, layout: ark3d_layout) {
        let s = state.pointee
        guard s.vaus_visible != 0 else {
            lastVausX = nil
            return
        }
        let vausX = s.vaus_x
        let halfWidth = s.vaus_w / 2
        let minX = Float(layout.field_left) + halfWidth, maxX = Float(layout.field_right) - halfWidth

        lock.lock()
        let source = _source
        let pointer = pointerTarget
        lock.unlock()

        // controller input: velocity on the target (used in every mode)
        var stick: Float = 0
        if let gp = GCController.current?.extendedGamepad {
            let x = gp.leftThumbstick.xAxis.value
            if abs(x) > 0.15 { stick = x }
            if gp.dpad.left.isPressed { stick = -0.75 }
            if gp.dpad.right.isPressed { stick = 0.75 }
        }
        if stick != 0 {
            target = min(max((target ?? vausX) + stick * Self.stickSpeed, minX), maxX)
        } else if source != .controller, let pointer {
            target = min(max(pointer, minX), maxX)
        }
        // with no target, hold still -- but keep writing the override, so
        // MAME's own dial mapping never takes over (that would make the Vaus jump)
        let goal = target.map { min(max($0, minX), maxX) } ?? vausX

        // learn px/count from the last few frames (window long enough that the
        // game's reaction delay doesn't matter), ignoring moves into a wall
        if let last = lastVausX {
            windowMove += vausX - last
            windowFrames += 1
            if windowFrames >= 8 {
                if abs(windowSteps) >= 8 && vausX > minX + 2 && vausX < maxX - 2 {
                    let measured = windowMove / Float(windowSteps)
                    if abs(measured) > 0.1 && abs(measured) < 10 {
                        gain = gain * 0.6 + measured * 0.4
                        if abs(gain) < 0.25 { gain = measured }   // crossed zero: take the new sign
                    }
                }
                windowSteps = 0; windowMove = 0; windowFrames = 0
            }
        }
        lastVausX = vausX

        // proportional step, damped for the game's reaction delay
        let error = goal - vausX
        var step: Int32 = 0
        if abs(error) >= 1 {
            step = Int32((error / gain * 0.5).rounded())
            if step == 0 { step = error / gain > 0 ? 1 : -1 }
            step = min(max(step, -Self.maxStep), Self.maxStep)
        }
        counter = (counter &+ step) & 0xff
        windowSteps += step

        for port in Self.ports {
            myosd_set_analog_input(port, 0xff, counter)
        }

        // stop chasing once there, so the controller mapping isn't fighting a stale target
        if stick == 0 && pointer == nil && abs(error) < 1 { target = nil }
    }
}
