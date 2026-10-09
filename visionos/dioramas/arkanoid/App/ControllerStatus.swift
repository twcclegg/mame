// license:BSD-3-Clause
//
// ControllerStatus - what the GameController framework sees, live: for
// finding out why a controller does nothing (none connected, connected but
// no input reaching the app, or input reaching it but not the game).  Shown
// on the HUD and in Settings, and logged to Documents/controller.log.

import Foundation
import GameController
import SwiftUI

@MainActor
final class ControllerStatus {
    static let shared = ControllerStatus()

    private var log: FileHandle?
    private var lastLine = ""
    private var observers: [NSObjectProtocol] = []

    private init() {
        let url = MAMEEngine.prepareDocuments().appendingPathComponent("controller.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        log = try? FileHandle(forWritingTo: url)
        write("started; \(GCController.controllers().count) controller(s)")
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent,
                     .GCControllerDidStopBeingCurrent] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let c = note.object as? GCController
                MainActor.assumeIsolated {
                    self?.write("\(name.rawValue): \(c.map(Self.describe) ?? "?")")
                }
            })
        }
    }

    private func write(_ line: String) {
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        print("controller: \(line)")
        log?.write(Data(stamped.utf8))
    }

    static func describe(_ c: GCController) -> String {
        "\(c.vendorName ?? "unnamed") [\(c.productCategory)\(c.extendedGamepad != nil ? ", extended" : ", NO extended profile")]"
    }

    /// One line for the UI; also logged whenever it changes.
    func summary() -> String {
        let pads = GCController.controllers()
        guard !pads.isEmpty else {
            note("no controllers")
            return "Controller: none seen by the app"
        }
        let current = GCController.current
        var parts = ["\(pads.count) controller\(pads.count == 1 ? "" : "s")"]
        parts.append("current: " + (current.map(Self.describe) ?? "none"))
        if let gp = (current ?? pads.first)?.extendedGamepad {
            let x = gp.leftThumbstick.xAxis.value, y = gp.leftThumbstick.yAxis.value
            var pressed: [String] = []
            if gp.buttonA.isPressed { pressed.append("A") }
            if gp.buttonB.isPressed { pressed.append("B") }
            if gp.buttonX.isPressed { pressed.append("X") }
            if gp.buttonY.isPressed { pressed.append("Y") }
            if gp.leftShoulder.isPressed { pressed.append("LB") }
            if gp.rightShoulder.isPressed { pressed.append("RB") }
            if gp.leftTrigger.isPressed { pressed.append("LT") }
            if gp.rightTrigger.isPressed { pressed.append("RT") }
            if gp.buttonMenu.isPressed { pressed.append("Menu") }
            if gp.dpad.left.isPressed { pressed.append("←") }
            if gp.dpad.right.isPressed { pressed.append("→") }
            parts.append(String(format: "stick %+.2f %+.2f", x, y))
            if let ds = gp as? GCDualSenseGamepad {
                parts.append(String(format: "touchpad %+.2f %+.2f", ds.touchpadPrimary.xAxis.value, ds.touchpadPrimary.yAxis.value))
            }
            parts.append(pressed.isEmpty ? "no buttons" : pressed.joined(separator: " "))
        }
        let line = parts.joined(separator: " · ")
        note(line)
        return line
    }

    private func note(_ line: String) {
        if line != lastLine {
            lastLine = line
            write(line)
        }
    }
}

/// The live line, refreshed ten times a second.
struct ControllerStatusView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            Text(ControllerStatus.shared.summary())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
