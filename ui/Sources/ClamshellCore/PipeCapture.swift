import Foundation

/// Drains one pipe to EOF on a background queue.
///
/// Keeping the reader off the caller's thread is what makes large output safe:
/// the child never blocks on a full pipe buffer while the parent waits for exit.
///
/// Reading uses `poll` with a short timeout instead of a blocking read, so
/// `stop()` can end the loop even when a surviving descendant still holds the
/// write end open and EOF never arrives.
final class PipeCapture: @unchecked Sendable {
    /// How long `poll` blocks before the stop flag is checked again.
    private static let pollInterval: Int32 = 200

    private let descriptor: Int32
    private let lock = NSLock()
    private var data = Data()
    private var stopped = false

    init(_ pipe: Pipe) {
        descriptor = pipe.fileHandleForReading.fileDescriptor
    }

    /// Read until the write end closes or `stop()` is called.
    func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !isStopped {
            var target = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&target, 1, Self.pollInterval)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            if ready == 0 {
                continue
            }
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                lock.lock()
                data.append(contentsOf: buffer[0 ..< count])
                lock.unlock()
            } else if count == 0 {
                return
            } else if errno != EAGAIN, errno != EINTR {
                return
            }
        }
    }

    /// Ask `drain()` to return without waiting for EOF.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Captured output, trimmed of surrounding whitespace and newlines.
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        let decoded = String(bytes: data, encoding: .utf8) ?? ""
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
