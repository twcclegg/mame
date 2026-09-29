// license:BSD-3-Clause
//
// ContentView - the main window: a ROM picker while idle, the game screen
// (with effect / theater controls in an ornament) while MAME runs.

import SwiftUI

struct ContentView: View {
    @State private var model = AppModel.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Group {
            if model.running {
                FrameView(frames: MAMEEngine.shared.frames)
                    .background(.black)
                    .ornament(attachmentAnchor: .scene(.bottom)) { controls }
            } else {
                GamePicker(model: model)
            }
        }
        .onAppear {
            PresentSettings.effect = model.effect
            model.refreshROMs()
            // launch arguments (e.g. from `xcrun simctl launch ... pacman`) start a game directly
            let args = MAMEEngine.stripSystemArguments(Array(CommandLine.arguments.dropFirst()))
            if !args.isEmpty && !model.running {
                model.launch(nil, extraArguments: args)
            }
            // Test hook only, off by default: MAMEVISION_AUTO_THEATER=1 opens
            // Theater automatically once a game is running, for driving this
            // from `simctl launch` (SIMCTL_CHILD_MAMEVISION_AUTO_THEATER=1)
            // where there's no way to tap the Theater button.
            if ProcessInfo.processInfo.environment["MAMEVISION_AUTO_THEATER"] == "1" {
                Task {
                    while !model.running { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .seconds(1))
                    if case .opened = await openImmersiveSpace(id: MAMEVisionApp.theaterID) {
                        model.theaterOpen = true
                    }
                }
            }
        }
        .onChange(of: model.effect) { _, effect in
            PresentSettings.effect = effect
        }
        .onChange(of: model.running) { _, running in
            // leave the theater when the game ends
            if !running && model.theaterOpen {
                Task { await dismissImmersiveSpace() }
                model.theaterOpen = false
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Effect", selection: $model.effect) {
                ForEach(ScreenEffect.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Button(model.theaterOpen ? "Exit Theater" : "Theater", systemImage: "sparkles.tv") {
                Task {
                    if model.theaterOpen {
                        await dismissImmersiveSpace()
                        model.theaterOpen = false
                    } else if case .opened = await openImmersiveSpace(id: MAMEVisionApp.theaterID) {
                        model.theaterOpen = true
                    }
                }
            }
        }
        .padding()
        .glassBackgroundEffect()
    }
}

struct GamePicker: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("MAME menu", systemImage: "list.bullet.rectangle") { model.launch(nil) }
                }
                Section("ROMs in Documents/roms") {
                    if model.roms.isEmpty {
                        Text("No ROMs yet. Copy .zip or .7z sets into this app's roms folder with the Files app or Finder, then refresh.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.roms, id: \.self) { rom in
                        Button(rom) { model.launch(rom) }
                    }
                }
            }
            .navigationTitle("MAME")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshROMs() }
            }
        }
    }
}
