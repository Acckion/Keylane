import Foundation
import KeylaneCore

enum CalendarAutomation {
    // Calendar's scripting dictionary addresses events by UID and may return
    // the series master for a recurring occurrence. Check the start before
    // showing or modifying the returned event.
    static let script = #"""
    function run(argv) {
        const [calendarID, nativeID, externalID, epochMilliseconds, ...addresses] = argv;
        const app = Application("com.apple.iCal");
        const date = new Date(Number(epochMilliseconds));
        const calendar = app.calendars.byId(calendarID);
        let event = null;
        for (const uid of [nativeID, externalID].filter(Boolean)) {
            const candidate = calendar.events.byId(uid);
            if (app.exists(candidate) && Math.abs(candidate.startDate().getTime() - date.getTime()) < 1000) {
                event = candidate;
                break;
            }
        }

        if (addresses.length === 0) {
            if (!event) {
                app.viewCalendar({at: date});
                app.activate();
                return "date";
            }
            event.show();
            return "event";
        }

        if (!event || !calendar.writable()) return "unavailable";
        const attendeeEmails = () => new Set(event.attendees.email()
            .filter(email => typeof email === "string").map(email => email.toLowerCase()));
        const existing = attendeeEmails();
        for (const address of addresses) {
            const key = address.toLowerCase();
            if (existing.has(key)) continue;
            event.attendees.push(app.Attendee({email: address}));
            existing.add(key);
        }
        app.reloadCalendars();
        const saved = attendeeEmails();
        return addresses.every(address => saved.has(address.toLowerCase())) ? "added" : "unavailable";
    }
    """#

    enum Outcome: String {
        case event, date, added, unavailable
    }

    enum Failure: Error {
        case permissionDenied, commandFailed
    }

    static func run(event: AgendaEvent, addresses: [String] = []) -> Result<Outcome, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script,
                             event.calendarID, event.nativeID, event.externalID ?? "",
                             String(Int64(event.start.timeIntervalSince1970 * 1000))] + addresses
        let output = Pipe()
        // The command only writes a single status or a short diagnostic.
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let outcome = Outcome(rawValue: response.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return .success(outcome)
            }
            if response.contains("(-1743)") { return .failure(Failure.permissionDenied) }
            return .failure(Failure.commandFailed)
        } catch {
            return .failure(error)
        }
    }
}
