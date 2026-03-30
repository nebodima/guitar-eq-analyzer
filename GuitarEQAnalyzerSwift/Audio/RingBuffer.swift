import Foundation

final class RingBuffer {
    private var storage: [Float]
    private var writeIndex: Int = 0
    private var hasWrapped = false
    private let lock = NSLock()

    init(capacity: Int) {
        self.storage = Array(repeating: 0, count: max(capacity, 1))
    }

    var capacity: Int { storage.count }

    func append(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        var remaining = count
        var sourceOffset = 0
        while remaining > 0 {
            let space = storage.count - writeIndex
            let chunk = min(space, remaining)
            let src = UnsafeBufferPointer(start: samples.advanced(by: sourceOffset), count: chunk)
            storage.replaceSubrange(writeIndex..<(writeIndex + chunk), with: src)
            writeIndex += chunk
            sourceOffset += chunk
            remaining -= chunk
            if writeIndex >= storage.count {
                writeIndex = 0
                hasWrapped = true
            }
        }
    }

    func snapshot(last count: Int) -> [Float] {
        let requested = max(1, min(count, storage.count))
        lock.lock()
        defer { lock.unlock() }

        if !hasWrapped && writeIndex < requested {
            let pad = Array(repeating: Float.zero, count: requested - writeIndex)
            return pad + Array(storage.prefix(writeIndex))
        }

        let end = writeIndex
        let start = (end - requested + storage.count) % storage.count
        if start < end {
            return Array(storage[start..<end])
        } else {
            return Array(storage[start..<storage.count] + storage[0..<end])
        }
    }
}
