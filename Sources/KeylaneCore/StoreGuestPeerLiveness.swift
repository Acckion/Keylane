import Darwin
import Dispatch

/// Non-consuming private socket liveness probe. Broker reads retain sole
/// ownership of payload bytes; this can only observe peer/socket closure.
public enum StoreGuestPeerLiveness {
    /// Keep a true monotonic timeout distinct from peer shutdown and other
    /// poll errors. EINTR reuses the original deadline instead of extending it.
    public static func waitForSocket(_ fd: Int32, events: Int16, until deadline: DispatchTime) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw StoreGuestHelperStatus.deadline }
            let remaining = (deadline.uptimeNanoseconds - now) / 1_000_000 + 1
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(clamping: remaining))
            if result == 0 { throw StoreGuestHelperStatus.deadline }
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & events != 0 else {
                throw StoreGuestHelperStatus.channel
            }
            return
        }
    }

    public static func peerClosed(_ fd: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, 0)
        if result == 0 { return false }
        if result < 0 { return errno != EINTR }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        guard descriptor.revents & Int16(POLLIN) != 0 else { return false }
        var byte: UInt8 = 0
        let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if count >= 0 { return count == 0 }
        return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR
    }
}
