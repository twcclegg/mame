// license:BSD-3-Clause
//
// QuickStart - launch straight into a game: the Vaus on the field, the ball
// on it, waiting for the player.  No boot test, coin, start, intro or
// "ROUND 1 READY".
//
// The first time, the game is run unthrottled (MYOSD_THROTTLE 0, sound
// muted) while coins and 1P start are pressed for it, until the decoded state
// shows round 1 ready to launch; that moment is saved as a state ("ready",
// Documents/sta/<set>/ready.sta).  Later launches load it (-state ready) and
// are there at once.  Either way the machine is then held (host pause) until
// the player does something: a pinch, a button, the stick.
//
// A state that fails to load (one from an older libmame, say) leaves MAME
// booting normally, and the first-time path takes over and saves a new one.

import Foundation
import GameController
import os
import libmame

private let log = Logger(subsystem: "org.mamedev.diorama.arkanoid", category: "quickstart")

final class QuickStart: @unchecked Sendable {
    static let stateName = "ready"

    enum Phase { case off, starting, holding, done }

    private let lock = NSLock()
    private var _phase: Phase = .off
    private var frames = 0
    private var readyFrames = 0
    private var holdFrames = 0

    /// Coin and start are pressed every this many frames until a round is on.
    static let creditCycle = 180
    /// Give up (and play normally) if no round is ready after this many frames.
    static let giveUpFrames = 60 * 90

    var phase: Phase {
        lock.lock(); defer { lock.unlock() }
        return _phase
    }

    static func stateURL(set: String) -> URL {
        MAMEEngine.prepareDocuments().appendingPathComponent("sta/\(set)/\(stateName).sta")
    }

    /// Extra MAME arguments for launching `set` this way.  Call just before
    /// starting MAME.
    func arguments(for set: String) -> [String] {
        lock.lock()
        _phase = .starting
        frames = 0; readyFrames = 0; holdFrames = 0
        lock.unlock()
        // fast until the ready moment (a loaded state gets there in a frame or two)
        myosd_set(Int32(MYOSD_THROTTLE), 0)
        var args = ["-skip_gameinfo"]
        if FileManager.default.fileExists(atPath: Self.stateURL(set: set).path) {
            args += ["-state", Self.stateName]
        }
        return args
    }

    /// Back to round 1, ready: loads the saved state (or, without one, gets a
    /// game going as at launch) and holds again.  Any thread, while MAME runs.
    func restart(set: String) {
        lock.lock()
        let wasHolding = _phase == .holding
        _phase = .starting
        frames = 0; readyFrames = 0; holdFrames = 0
        lock.unlock()
        // the load resumes the machine; drop our hold too, so the next one takes
        if wasHolding { MAMEEngine.shared.setPaused(false) }
        myosd_set(Int32(MYOSD_THROTTLE), 0)
        if FileManager.default.fileExists(atPath: Self.stateURL(set: set).path) {
            myosd_load_state(Self.stateName)
        }
    }

    /// The player did something: let the game go.  Any thread.
    func release() {
        lock.lock()
        let wasHolding = _phase == .holding
        if _phase != .off { _phase = .done }
        lock.unlock()
        if wasHolding {
            MAMEEngine.shared.setPaused(false)
            log.info("released by the player")
        }
    }

    func stop() {
        lock.lock(); _phase = .off; lock.unlock()
        myosd_set(Int32(MYOSD_THROTTLE), 1)
    }

    /// MAME thread, once per emulated frame, after decoding.
    func frame(state: UnsafePointer<ark3d_state>) {
        lock.lock()
        let phase = _phase
        lock.unlock()

        switch phase {
        case .off, .done:
            return
        case .holding:
            // a controller counts as the player doing something (gestures and
            // buttons call release() themselves)
            holdFrames += 1
            if holdFrames > 2, Self.controllerActive() { release() }
            return
        case .starting:
            break
        }

        frames += 1
        let s = state.pointee
        if s.in_play == 0 && s.vaus_visible == 0 {
            // boot test, attract mode or the intro: get a game going
            let c = frames % Self.creditCycle
            if c == Self.creditCycle / 2 { MAMEEngine.shared.input.pulseVirtual(MYOSD_SELECT.rawValue) }
            if c == Self.creditCycle - 10 { MAMEEngine.shared.input.pulseVirtual(MYOSD_START.rawValue) }
        }

        // ready: round on, banner gone, the ball held on the Vaus
        let held = s.ball_count >= 1 && s.balls.0.vx == 0 && s.balls.0.vy == 0 && s.balls.0.speed <= 0
        if s.in_play != 0 && s.vaus_phase == Int32(ARK3D_VAUS_NORMAL.rawValue) && s.banner_round == 0
            && s.banner_ready == 0 && held {
            readyFrames += 1
        } else {
            readyFrames = 0
        }

        if readyFrames >= 2 {
            let loaded = frames < 30          // came from the saved state, nothing to save
            if !loaded { myosd_save_state(Self.stateName) }
            myosd_set(Int32(MYOSD_THROTTLE), 1)
            // hold after the save has run (MAME's scheduler does it within a frame or so)
            MAMEEngine.shared.setPaused(true)
            lock.lock(); if _phase == .starting { _phase = .holding }; lock.unlock()
            log.info("ready after \(self.frames) frames\(loaded ? " (saved state)" : ", saved", privacy: .public); holding for the player")
        } else if frames >= Self.giveUpFrames {
            log.warning("no round ready after \(self.frames) frames; playing normally")
            stop()
        }
    }

    private static func controllerActive() -> Bool {
        guard let gp = GCController.current?.extendedGamepad else { return false }
        return gp.buttonA.isPressed || gp.buttonB.isPressed || gp.buttonX.isPressed || gp.buttonY.isPressed
            || gp.buttonMenu.isPressed || gp.dpad.left.isPressed || gp.dpad.right.isPressed
            || abs(gp.leftThumbstick.xAxis.value) > 0.3
    }
}
