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
// Measured on the real game (a Lua bot driving the same loop through the
// same analog override, visionos/dioramas/arkanoid/lua/ark3d_bot.lua): about +1 px
// per count, positive to the right.  The magnitude is still learned while
// playing (px/count over a window of frames); the sign is not, because a
// window with a wrong sign (e.g. the Vaus being re-centred for a new life)
// used to flip it, after which the loop pushed the Vaus into a wall, where it
// can't learn, forever.

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
    private var dragDelta: Float?               // view px since the pinch began (relative, like the spinner)
    private var _sensitivity: Float = 2

    /// Vaus px per px of pinch movement (and the hand's gain about the field's centre).
    var sensitivity: Float {
        get { lock.lock(); defer { lock.unlock() }; return _sensitivity }
        set { lock.lock(); _sensitivity = newValue; lock.unlock() }
    }

    var source: Source {
        get { lock.lock(); defer { lock.unlock() }; return _source }
        set { lock.lock(); _source = newValue; pointerTarget = nil; dragDelta = nil; lock.unlock() }
    }

    /// Set from the main thread (hand tracking); nil when released.
    func setPointerTarget(_ viewX: Float?) {
        lock.lock(); pointerTarget = viewX; lock.unlock()
    }

    /// Set from the main thread while pinching: how far (view px) the pinch has
    /// moved since it began; nil when released.  The Vaus moves by that much
    /// times `sensitivity` from wherever it was, so a pinch never makes it jump
    /// and a short hand movement can cross the field.
    func setDrag(_ delta: Float?) {
        lock.lock(); dragDelta = delta; lock.unlock()
    }

    // MAME-thread state
    private var target: Float?
    private var dragAnchor: Float?              // Vaus x when the pinch began
    private var counter: Int32 = 0
    private var gain: Float = 1                 // measured px per count (the game: about +1)
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
        var pointer = pointerTarget
        let drag = dragDelta
        let gainScale = _sensitivity
        lock.unlock()

        if let drag {
            let anchor = dragAnchor ?? vausX
            dragAnchor = anchor
            pointer = anchor + drag * gainScale
        } else {
            dragAnchor = nil
            if let p = pointer {
                // the hand: scaled about the field's centre, so the right hand
                // needn't sweep the whole (1 m) field
                let centre = Float(layout.field_left + layout.field_right) / 2
                pointer = centre + (p - centre) * gainScale
            }
        }

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
        if let last = lastVausX, s.vaus_phase == Int32(ARK3D_VAUS_NORMAL.rawValue) {
            windowMove += vausX - last
            windowFrames += 1
            if windowFrames >= 8 {
                if abs(windowSteps) >= 8 && vausX > minX + 2 && vausX < maxX - 2 {
                    let measured = windowMove / Float(windowSteps)
                    if measured > 0.25 && measured < 4 {
                        gain = gain * 0.6 + measured * 0.4
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
