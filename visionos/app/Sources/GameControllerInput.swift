// license:BSD-3-Clause
//
// GameControllerInput - fills libmame's myosd_input_state from connected
// game controllers (GCExtendedGamepad).  Called on the MAME thread from the
// input_poll callback.
//
// Mapping (the Home/PS/Xbox button is reserved by visionOS, so the MAME
// menu goes on a combo instead):
//   A B X Y, L1 R1, L2 R2, L3 R3   -> MAME buttons 1-10
//   Menu (≡ / Options / Start)      -> Start
//   View / Share / Create / Select  -> Select (Coin)
//   Select + Start                  -> MAME menu (TAB)
//   Select + L1                     -> Exit game / back (ESC)
//   Select + R1                     -> Pause (P)

import Foundation
import GameController
import libmame

final class GameControllerInput: @unchecked Sendable {
    private let lock = NSLock()
    private var controllers: [GCController] = []

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        GCController.startWirelessControllerDiscovery {}
        refresh()
    }

    private func refresh() {
        let pads = GCController.controllers().filter { $0.extendedGamepad != nil }
        lock.lock()
        controllers = Array(pads.prefix(Int(MYOSD_NUM_JOY)))
        lock.unlock()
        for (i, c) in pads.prefix(Int(MYOSD_NUM_JOY)).enumerated() {
            c.playerIndex = GCControllerPlayerIndex(rawValue: i) ?? .indexUnset
        }
    }

    // on-screen / gesture buttons for player 1 (MYOSD_* bits), for playing
    // without a controller: held while set, or pressed until a deadline
    private var virtualHeld: UInt32 = 0
    private var virtualPulses: [UInt32: TimeInterval] = [:]

    /// Presses `bits` for player 1 while `held` is true (e.g. fire while pinching).
    func setVirtual(_ bits: UInt32, held: Bool) {
        lock.lock()
        if held { virtualHeld |= bits } else { virtualHeld &= ~bits }
        lock.unlock()
    }

    /// Presses `bits` for player 1 briefly (a tap on a Coin or Start button);
    /// long enough for any game to see it.
    func pulseVirtual(_ bits: UInt32, seconds: TimeInterval = 0.15) {
        lock.lock()
        virtualPulses[bits] = ProcessInfo.processInfo.systemUptime + seconds
        lock.unlock()
    }

    func poll(into state: UnsafeMutablePointer<myosd_input_state>) {
        lock.lock()
        let pads = controllers
        let now = ProcessInfo.processInfo.systemUptime
        virtualPulses = virtualPulses.filter { $0.value > now }
        let virtual = virtualPulses.keys.reduce(virtualHeld, |)
        lock.unlock()

        let joyCount = Int(MYOSD_NUM_JOY)
        let axes = Int(MYOSD_AXIS_NUM.rawValue)
        var status = [UInt](repeating: 0, count: joyCount)
        var analog = [Float](repeating: 0, count: joyCount * axes)
        var keys: [myosd_keycode] = []

        for (i, pad) in pads.prefix(joyCount).enumerated() {
            guard let gp = pad.extendedGamepad else { continue }
            var bits: UInt32 = 0
            let select = gp.buttonOptions?.isPressed ?? false
            let start = gp.buttonMenu.isPressed

            // directions from the d-pad and (digitally) the left stick
            let lx = gp.leftThumbstick.xAxis.value, ly = gp.leftThumbstick.yAxis.value
            if gp.dpad.up.isPressed    || ly >  0.5 { bits |= MYOSD_UP.rawValue }
            if gp.dpad.down.isPressed  || ly < -0.5 { bits |= MYOSD_DOWN.rawValue }
            if gp.dpad.left.isPressed  || lx < -0.5 { bits |= MYOSD_LEFT.rawValue }
            if gp.dpad.right.isPressed || lx >  0.5 { bits |= MYOSD_RIGHT.rawValue }

            if select && (start || gp.leftShoulder.isPressed || gp.rightShoulder.isPressed) {
                // combos: report only the resulting key, not the buttons
                if start { keys.append(MYOSD_KEY_CONFIGURE) }
                if gp.leftShoulder.isPressed { keys.append(MYOSD_KEY_ESC) }
                if gp.rightShoulder.isPressed { keys.append(MYOSD_KEY_P) }
            } else {
                if select { bits |= MYOSD_SELECT.rawValue }
                if start { bits |= MYOSD_START.rawValue }
                if gp.leftShoulder.isPressed { bits |= MYOSD_L1.rawValue }
                if gp.rightShoulder.isPressed { bits |= MYOSD_R1.rawValue }
            }
            if gp.buttonA.isPressed { bits |= MYOSD_A.rawValue }
            if gp.buttonB.isPressed { bits |= MYOSD_B.rawValue }
            if gp.buttonX.isPressed { bits |= MYOSD_X.rawValue }
            if gp.buttonY.isPressed { bits |= MYOSD_Y.rawValue }
            if gp.leftTrigger.isPressed { bits |= MYOSD_L2.rawValue }
            if gp.rightTrigger.isPressed { bits |= MYOSD_R2.rawValue }
            if gp.leftThumbstickButton?.isPressed ?? false { bits |= MYOSD_L3.rawValue }
            if gp.rightThumbstickButton?.isPressed ?? false { bits |= MYOSD_R3.rawValue }
            status[i] = UInt(bits)

            // analog: libmame flips Y itself (up is positive here)
            let base = i * axes
            analog[base + Int(MYOSD_AXIS_LX.rawValue)] = lx
            analog[base + Int(MYOSD_AXIS_LY.rawValue)] = ly
            analog[base + Int(MYOSD_AXIS_RX.rawValue)] = gp.rightThumbstick.xAxis.value
            analog[base + Int(MYOSD_AXIS_RY.rawValue)] = gp.rightThumbstick.yAxis.value
            analog[base + Int(MYOSD_AXIS_LZ.rawValue)] = gp.leftTrigger.value
            analog[base + Int(MYOSD_AXIS_RZ.rawValue)] = gp.rightTrigger.value
        }

        status[0] |= UInt(virtual)

        // copy into the C struct (fixed-size C arrays import as tuples, so go through raw bytes)
        withUnsafeMutableBytes(of: &state.pointee.joy_status) { raw in
            let dst = raw.bindMemory(to: UInt.self)
            for i in 0..<min(dst.count, status.count) { dst[i] = status[i] }
        }
        withUnsafeMutableBytes(of: &state.pointee.joy_analog) { raw in
            let dst = raw.bindMemory(to: Float.self)
            for i in 0..<min(dst.count, analog.count) { dst[i] = analog[i] }
        }
        // keyboard: only the synthesized combo keys for now
        withUnsafeMutableBytes(of: &state.pointee.keyboard) { raw in
            for i in raw.indices { raw[i] = 0 }
            for k in keys { raw[Int(k.rawValue)] = 0x80 }
        }
    }
}
