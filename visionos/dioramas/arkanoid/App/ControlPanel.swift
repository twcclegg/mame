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
                        if !model.volumeOpen { openWindow(id: ArkanoidDioramaApp.volumeID) }
                    }
                    .disabled(model.running || model.sets.isEmpty)
                }

                Section("View") {
                    Button(model.volumeOpen ? "Close table-top" : "Table-top", systemImage: "cube") {
                        if model.volumeOpen { dismissWindow(id: ArkanoidDioramaApp.volumeID) } else { openWindow(id: ArkanoidDioramaApp.volumeID) }
                    }
                    Button(model.arenaOpen ? "Leave arena" : "Arena (immersive)", systemImage: "visionpro") {
                        Task {
                            if model.arenaOpen {
                                await dismissImmersiveSpace()
                                model.arenaOpen = false
                            } else if case .opened = await openImmersiveSpace(id: ArkanoidDioramaApp.arenaID) {
                                model.arenaOpen = true
                            }
                        }
                    }
                    Toggle("Original screen", isOn: $model.showOriginalScreen)
                    Toggle("Game background", isOn: $model.showGameBackground)
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
            .navigationTitle("Arkanoid Diorama")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
            }
        }
        .onAppear {
            model.refresh()
            // development: DIORAMA_CLOSEUP=1 opens the arena right in front of
            // the viewer (see PlayfieldView), e.g. for simulator screenshots
            let closeup = ProcessInfo.processInfo.environment["DIORAMA_CLOSEUP"] == "1"
            if model.startReplayIfRequested() {
                if !closeup { openWindow(id: ArkanoidDioramaApp.volumeID) }
            } else {
                // launch arguments (e.g. `xcrun simctl launch booted <id> arkanoid`) start directly
                let args = MAMEEngine.stripSystemArguments(Array(CommandLine.arguments.dropFirst()))
                if let first = args.first, !model.running {
                    model.selected = first
                    model.launch(extraArguments: Array(args.dropFirst()))
                    if !closeup { openWindow(id: ArkanoidDioramaApp.volumeID) }
                }
            }
            if closeup {
                Task {
                    if case .opened = await openImmersiveSpace(id: ArkanoidDioramaApp.arenaID) {
                        model.arenaOpen = true
                        // nothing between the viewer and the board
                        dismissWindow(id: ArkanoidDioramaApp.controlsID)
                    }
                }
            }
        }
    }
}
