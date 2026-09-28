// license:BSD-3-Clause
//
// ControlPanel - the app's 2D window: pick an Arkanoid set, start it, open
// the table-top volume or the immersive arena, choose the paddle control.

import SwiftUI

struct ControlPanel: View {
    @State private var model = ArkModel.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        NavigationStack {
            Form {
                Section("Game") {
                    if model.sets.isEmpty {
                        Text("Copy your own Arkanoid ROM set (e.g. arkanoid.zip) into this app's roms folder with the Files app or Finder, then refresh. Clones need the parent set too.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Set", selection: $model.selected) {
                            ForEach(model.sets, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button(model.running ? "Running" : "Start", systemImage: "play.fill") {
                        model.launch()
                        if !model.volumeOpen { openWindow(id: Arkanoid3DApp.volumeID) }
                    }
                    .disabled(model.running || model.sets.isEmpty)
                }

                Section("View") {
                    Button(model.volumeOpen ? "Close table-top" : "Table-top", systemImage: "cube") {
                        if model.volumeOpen { dismissWindow(id: Arkanoid3DApp.volumeID) } else { openWindow(id: Arkanoid3DApp.volumeID) }
                    }
                    Button(model.arenaOpen ? "Leave arena" : "Arena (immersive)", systemImage: "visionpro") {
                        Task {
                            if model.arenaOpen {
                                await dismissImmersiveSpace()
                                model.arenaOpen = false
                            } else if case .opened = await openImmersiveSpace(id: Arkanoid3DApp.arenaID) {
                                model.arenaOpen = true
                            }
                        }
                    }
                    Toggle("Original screen", isOn: $model.showOriginalScreen)
                }

                Section {
                    Picker("Paddle", selection: $model.paddleSource) {
                        ForEach(PaddleController.Source.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Controller: stick or d-pad moves the Vaus, A fires / launches, Select inserts a coin, Start starts. Select+Start opens MAME's menu. Pinch & drag: look at the field, pinch and move sideways. Hand: follows your right index finger (arena only).")
                }
            }
            .navigationTitle("Arkanoid 3D")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
            }
        }
        .onAppear {
            model.refresh()
            // launch arguments (e.g. `xcrun simctl launch booted <id> arkanoid`) start directly
            let args = MAMEEngine.stripSystemArguments(Array(CommandLine.arguments.dropFirst()))
            if let first = args.first, !model.running {
                model.selected = first
                model.launch(extraArguments: Array(args.dropFirst()))
                openWindow(id: Arkanoid3DApp.volumeID)
            }
        }
    }
}
