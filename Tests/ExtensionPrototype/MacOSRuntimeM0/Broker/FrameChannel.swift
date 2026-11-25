import Foundation
import Darwin

// Native framing distinguishes clean idle EOF from a truncated header/body.
// The signed parent owns the deadline; invalid lengths are checked before allocation.
enum M0FrameChannel {
    enum Frame { case end, invalid, data(Data) }
    private enum Read { case end, invalid, data(Data) }
    private static func exact(_ count: Int, fd: Int32) -> Read {
        var data = Data(count: count)
        var position = 0
        var readError = false
        let failed = data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
            while position < count {
                let n = read(fd, bytes.baseAddress! + position, count - position)
                if n < 0 && errno == EINTR { continue }
                if n < 0 { readError = true; return true }
                if n == 0 { return true }
                position += n
            }
            return false
        }
        if !failed { return .data(data) }
        return position == 0 && !readError ? .end : .invalid
    }
    static func receive(fd: Int32) -> Frame {
        switch exact(4, fd: fd) {
        case .end: return .end
        case .invalid: return .invalid
        case .data(let header):
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= 4096 else { return .invalid }
            guard case .data(let body) = exact(Int(length), fd: fd) else { return .invalid }
            return .data(body)
        }
    }
}
