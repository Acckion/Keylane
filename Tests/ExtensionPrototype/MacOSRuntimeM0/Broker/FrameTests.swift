import Foundation
import Darwin

@main struct FrameTests {
    static func main() {
        func frame(_ data: Data) -> Data {
            var size = UInt32(data.count).bigEndian
            return Data(bytes: &size, count: 4) + data
        }
        func check(_ bytes: Data, expected: Int) {
            var pair: [Int32] = [0,0]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            defer { close(pair[0]); close(pair[1]) }
            precondition(bytes.withUnsafeBytes { write(pair[0], $0.baseAddress, $0.count) } == bytes.count)
            shutdown(pair[0], SHUT_WR)
            let result = M0FrameChannel.receive(fd: pair[1])
            switch result {
            case .end: precondition(expected == 0)
            case .invalid: precondition(expected == -1)
            case .data(let body): precondition(expected == body.count)
            }
        }
        check(Data(), expected: 0)
        for n in 1...3 { check(Data(repeating: 0, count: n), expected: -1) }
        check(Data(repeating: 0, count: 4), expected: -1)
        check(Data(repeating: 255, count: 4), expected: -1)
        check(frame(Data(repeating: 65, count: 4096)), expected: 4096)
        check(frame(Data(repeating: 65, count: 4097)), expected: -1)
        check(Data([0,0,0,4]), expected: -1)
        check(Data([0,0,0,4,65,66]), expected: -1)
        check(frame(Data([65])), expected: 1)
        guard case .invalid = M0FrameChannel.receive(fd: -1) else { fatalError("Read error is not clean EOF") }
        print("PASS bounded framing, exact limit, clean EOF and truncated header/body rejection")
    }
}
