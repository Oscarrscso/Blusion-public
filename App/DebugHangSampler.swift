#if DEBUG
import Darwin
import Foundation

/// Debug builds only. When the main thread stops answering for two seconds, takes stack samples of it from a background thread and
/// writes them to `Documents/hang-<time>.txt`, so a freeze on a device can be read afterwards without Instruments:
///
///     xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier app.blusion.player \
///         --source Documents/<file> --destination <local file>
///
/// A sample suspends the main thread for microseconds, walks its frame-pointer chain with safe reads and resumes it; names are looked
/// up afterwards. Nothing here allocates while the main thread is suspended (it might hold the allocator's lock).
enum DebugHangSampler {
    private static let capacity = 96
    private static let sampleCount = 25

    @MainActor
    static func start() {
        let mainThread = mach_thread_self()
        let pong = Pong()
        Thread.detachNewThread {
            Thread.current.name = "debug.hang-sampler"
            let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: capacity * sampleCount)
            let depths = UnsafeMutablePointer<Int>.allocate(capacity: sampleCount)
            var reportedStall = false
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async { pong.touch() }
                let silent = pong.silence()
                if silent < 2 {
                    reportedStall = false
                    continue
                }
                guard !reportedStall else { continue }
                reportedStall = true
                var taken = 0
                for index in 0..<sampleCount {
                    depths[index] = sample(thread: mainThread, into: buffer + index * capacity, capacity: capacity)
                    taken += 1
                    Thread.sleep(forTimeInterval: 0.1)
                }
                write(buffer: buffer, depths: depths, count: taken, silentFor: silent)
            }
        }
    }

    /// One stack of the thread, innermost frame first. Returns the number of frames, 0 when it could not be read.
    private static func sample(thread: thread_act_t, into frames: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }
        #if arch(arm64)
        var state = arm_thread_state64_t()
        let flavor = ARM_THREAD_STATE64
        #else
        var state = x86_thread_state64_t()
        let flavor = x86_THREAD_STATE64
        #endif
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: state) / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(flavor), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        #if arch(arm64)
        let mask: UInt = 0x7F_FFFF_FFFF   // return addresses of system code carry pointer-authentication bits above bit 39
        var depth = 0
        frames[depth] = UInt(state.__pc) & mask
        depth += 1
        frames[depth] = UInt(state.__lr) & mask
        depth += 1
        var frame = UInt(state.__fp)
        #else
        let mask = UInt.max
        frames[0] = UInt(state.__rip)
        var depth = 1
        var frame = UInt(state.__rbp)
        #endif
        var pair: (UInt, UInt) = (0, 0)
        while depth < capacity, frame != 0, frame % 8 == 0 {
            var read: vm_size_t = 0
            let status = withUnsafeMutablePointer(to: &pair) {
                vm_read_overwrite(mach_task_self_, vm_address_t(frame), 16, vm_address_t(UInt(bitPattern: $0)), &read)
            }
            guard status == KERN_SUCCESS, read == 16 else { break }
            frames[depth] = pair.1 & mask
            depth += 1
            guard pair.0 > frame else { break }
            frame = pair.0
        }
        return depth
    }

    private static func write(buffer: UnsafeMutablePointer<UInt>, depths: UnsafeMutablePointer<Int>, count: Int, silentFor: TimeInterval) {
        var text = "Main thread silent for \(silentFor) s at \(Date())\n"
        var tally: [String: Int] = [:]
        for index in 0..<count {
            text += "\n--- sample \(index + 1), \(depths[index]) frames\n"
            var seen = Set<String>()
            for frame in 0..<depths[index] {
                let address = buffer[index * capacity + frame]
                var info = Dl_info()
                let name: String
                let image: String
                if address != 0, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                    name = info.dli_sname.map { String(cString: $0) } ?? String(format: "0x%lx", address)
                    image = info.dli_fname.map { ($0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } as NSString).lastPathComponent } ?? "?"
                } else {
                    name = String(format: "0x%lx", address)
                    image = "?"
                }
                text += String(format: "%3d  %@  %@  (0x%lx)\n", frame, image, name, address)
                if seen.insert("\(image) \(name)").inserted { tally["\(image) \(name)", default: 0] += 1 }
            }
        }
        text += "\n=== frames present in the most samples (of \(count)) ===\n"
        for (name, hits) in tally.sorted(by: { $0.value > $1.value }).prefix(45) { text += "\(hits)  \(name)\n" }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        try? text.write(to: documents.appendingPathComponent("hang-\(stamp).txt"), atomically: true, encoding: .utf8)
    }

    /// When the main thread last answered.
    private final class Pong: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        func touch() { lock.withLock { last = Date() } }
        func silence() -> TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
    }
}
#endif
