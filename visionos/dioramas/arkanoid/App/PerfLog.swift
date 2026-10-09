// license:BSD-3-Clause
//
// PerfLog - frame rates, for finding out why motion isn't smooth: emulated
// frames per second (MAME thread; ~60 when MAME keeps up) against rendered
// frames per second (RealityKit updates; ~90 on Vision Pro), the longest
// render frame, and how many render frames saw no new emulated frame.
// Every 2 s to Documents/perf.log (and stdout).

import Foundation

final class PerfLog: @unchecked Sendable {
    static let shared = PerfLog()

    private let lock = NSLock()
    private var emulated = 0
    private var rendered = 0
    private var stale = 0                       // render frames with no new state
    private var longest: Float = 0
    private var start = ProcessInfo.processInfo.systemUptime
    private let file: FileHandle?

    private init() {
        let url = MAMEEngine.prepareDocuments().appendingPathComponent("perf.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }

    /// MAME thread, once per emulated frame.
    func emulatedFrame() {
        lock.lock(); emulated += 1; lock.unlock()
    }

    /// Main thread, once per render update.
    func renderedFrame(dt: Float, newState: Bool) {
        lock.lock()
        rendered += 1
        if !newState { stale += 1 }
        longest = max(longest, dt)
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - start
        guard elapsed >= 2 else { lock.unlock(); return }
        let line = String(format: "emulated %.1f fps, rendered %.1f fps, longest render frame %.1f ms, %d%% render frames without a new emulated one",
                          Double(emulated) / elapsed, Double(rendered) / elapsed, longest * 1000,
                          rendered > 0 ? stale * 100 / rendered : 0)
        emulated = 0; rendered = 0; stale = 0; longest = 0; start = now
        lock.unlock()
        print("perf: \(line)")
        file?.write(Data("\(Date().formatted(date: .omitted, time: .standard)) \(line)\n".utf8))
    }
}
