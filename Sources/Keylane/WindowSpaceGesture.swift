import CoreGraphics
import Darwin
import Foundation

/// Dock gesture fields and the macOS 27 IOHID payload are informed by iss.
/// See THIRD_PARTY_NOTICES.md for attribution and terms.
enum WindowSpaceGesture {
    private enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

    private enum Field {
        static let type = CGEventField(rawValue: 55)!
        static let subtype = CGEventField(rawValue: 110)!
        static let scrollY = CGEventField(rawValue: 119)!
        static let motion = CGEventField(rawValue: 123)!
        static let progress = CGEventField(rawValue: 124)!
        static let x = CGEventField(rawValue: 125)!
        static let velocityX = CGEventField(rawValue: 129)!
        static let phase = CGEventField(rawValue: 132)!
        static let phaseAlias = CGEventField(rawValue: 134)!
        static let flags = CGEventField(rawValue: 135)!
        static let flavor = CGEventField(rawValue: 138)!
        static let deltaX = CGEventField(rawValue: 139)!
        static let timestamp = CGEventField(rawValue: 169)!
    }

    static func post(direction: Int) -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        let modern = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        let phases: [Phase] = modern ? [.began, .changed, .ended] : [.began, .ended]
        let sequence = phases.compactMap { stage -> [CGEvent]? in
            guard let envelope = CGEvent(source: nil),
                  let dock = makeDockEvent(stage, next: direction > 0, modern: modern) else { return nil }
            envelope.setIntegerValueField(Field.type, value: 29)
            return [dock, envelope]
        }
        guard sequence.count == phases.count else { return false }
        for pair in sequence {
            for event in pair { event.post(tap: .cgSessionEventTap) }
        }
        return true
    }

    private static func makeDockEvent(_ phase: Phase, next: Bool, modern: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(Field.type, value: 30)
        event.setIntegerValueField(Field.subtype, value: 23)
        event.setIntegerValueField(Field.motion, value: 1)
        event.setIntegerValueField(Field.phase, value: phase.rawValue)
        if modern {
            let progress = next ? -1.0 : 1.0
            let velocity = phase == .ended ? progress * 9999 : 0
            let time = mach_absolute_time()
            event.setIntegerValueField(Field.phaseAlias, value: phase.rawValue)
            event.setDoubleValueField(Field.flavor, value: 3)
            event.setDoubleValueField(Field.timestamp, value: Double(time))
            event.setDoubleValueField(Field.x, value: 0.1)
            event.setDoubleValueField(Field.progress, value: progress)
            event.setDoubleValueField(Field.velocityX, value: velocity)
            return augment(event, time: time, phase: phase, progress: progress, velocity: velocity)
        }
        let direction: Float = next ? .leastNonzeroMagnitude : -.leastNonzeroMagnitude
        event.setIntegerValueField(Field.flags, value: Int64(Int32(bitPattern: direction.bitPattern)))
        event.setDoubleValueField(Field.scrollY, value: 0)
        event.setDoubleValueField(Field.deltaX, value: Double(Float.leastNonzeroMagnitude))
        if phase == .ended {
            event.setDoubleValueField(Field.progress, value: next ? 2 : -2)
            event.setDoubleValueField(Field.velocityX, value: next ? 400 : -400)
        }
        return event
    }

    private static func augment(_ event: CGEvent, time: UInt64, phase: Phase,
                                progress: Double, velocity: Double) -> CGEvent? {
        guard let serialized = event.data as Data?, serialized.prefix(4).elementsEqual([0, 0, 0, 2]) else { return nil }
        let finishes = phase == .ended
        var payload = Data()
        payload.appendLE(event.timestamp == 0 ? time : event.timestamp)
        payload.appendLE(UInt64(0))   // sender
        payload.appendLE(UInt32(0))   // queue flags
        payload.appendLE(UInt32(0))   // attributes length
        payload.appendLE(UInt32(finishes ? 2 : 1))
        payload.appendLE(UInt32(40))  // fluid touch event length
        payload.appendLE(UInt32(23))
        payload.appendLE(UInt32(phase.rawValue) << 24)
        payload.appendLE(UInt32(0))   // depth and reserved bytes
        payload.appendLE(Int32(0.1 * 65536))
        payload.appendLE(UInt32(0))   // position Y
        payload.appendLE(UInt32(0))   // position Z
        payload.appendLE(UInt32(0))   // swipe mask
        payload.appendLE(UInt16(1))  // horizontal motion
        payload.appendLE(UInt16(3))  // Dock primary gesture
        payload.appendLE(Int32(progress * 65536))
        if finishes {
            payload.appendLE(UInt32(28))
            payload.appendLE(UInt32(9))
            payload.appendLE(UInt32(0))
            payload.appendLE(UInt32(1))
            payload.appendLE(Int32(velocity * 65536))
            payload.appendLE(UInt32(0))
            payload.appendLE(UInt32(0))
        }
        var data = serialized
        data.append(contentsOf: [0, UInt8(payload.count), 0x10, 0x6D]) // big-endian field length and field 4205
        data.append(payload)
        return CGEvent(withDataAllocator: nil, data: data as CFData)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ number: T) {
        var value = number.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
