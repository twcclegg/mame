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
                    if model.running {
                        ArcadeButtons(model: model)
                    }
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
                    Picker("Stick", selection: $model.stickMode) {
                        ForEach(PaddleController.StickMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Pinch / hand sensitivity") {
                        Slider(value: $model.paddleSensitivity, in: 0.5...5, step: 0.25)
                        Text(model.paddleSensitivity, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 44)
                    }
                } header: {
                    Text("Controls")
                } footer: {
                    Text("No controller needed: Coin, then Start. Pinch & drag: look at the field, pinch (launches / fires) and move sideways; the Vaus moves from where it is, like the arcade's spinner, so you can let go and pinch again. Hand (arena only): the Vaus follows your right index finger, pinch your left hand to fire. Controller: the left stick moves the Vaus (Stick: Speed = how far you push sets how fast, finer near the centre; Position = where you push is where it goes), the d-pad at a steady speed; A, RT or RB fires / launches; Select+Start opens MAME's menu.")
                }
            }
            .navigationTitle("Arkanoid Diorama")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
            }
        }
        .onAppear { model.refresh() }
    }
}

/// Coin, 1P start and fire, for playing without a controller (the control
/// window and the HUD over the board).
struct ArcadeButtons: View {
    let model: ArkModel

    var body: some View {
        HStack(spacing: 12) {
            Button("New game", systemImage: "arrow.counterclockwise") { model.newGame() }
            Button("Coin", systemImage: "centsign.circle") { model.insertCoin() }
            Button("Start", systemImage: "play.circle") { model.pressStart() }
            Button("Fire", systemImage: "scope") { model.fire() }
        }
        .buttonStyle(.bordered)
    }
}
