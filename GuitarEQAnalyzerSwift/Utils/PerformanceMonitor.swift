import Foundation
import Darwin

/// Reads CPU % and resident memory for the current process.
/// Updates every second on the main thread.
final class PerformanceMonitor: ObservableObject {
    @Published private(set) var cpuPercent: Double = 0
    @Published private(set) var memoryMB: Double   = 0

    private var timer: DispatchSourceTimer?
    private var prevUserTime: UInt64 = 0
    private var prevSysTime:  UInt64 = 0
    private var prevAbsTime:  UInt64 = 0

    init() { start() }
    deinit  { timer?.cancel() }

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func sample() {
        let cpu = Self.processCPU()
        let mem = Self.processMemoryMB()
        DispatchQueue.main.async {
            self.cpuPercent = cpu
            self.memoryMB   = mem
        }
    }

    // ── CPU via thread_info ───────────────────────────────────────────────
    private static func processCPU() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kr == KERN_SUCCESS, let threads = threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: threads),
                          vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        }
        var total: Double = 0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    // ── Memory via task_vm_info ───────────────────────────────────────────
    private static func processMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
