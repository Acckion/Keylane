import Foundation

/// One matcher per Grep operation. Regex progress callbacks bound backtracking work
/// and observe cancellation; no result is published when a match is interrupted.
struct AIFileTextMatcher {
    private let query: String
    private let caseSensitive: Bool
    private let expression: NSRegularExpression?
    private let deadline: TimeInterval
    private let now: () -> TimeInterval

    init(query: String, regex: Bool, caseSensitive: Bool, budget: TimeInterval = 1,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.query = query; self.caseSensitive = caseSensitive; self.now = now
        deadline = now() + budget
        if regex {
            guard query.utf8.count <= 512 else { throw AIFileToolError.invalidPattern }
            do { expression = try NSRegularExpression(pattern: query, options: caseSensitive ? [] : [.caseInsensitive]) }
            catch { throw AIFileToolError.invalidPattern }
        } else { expression = nil }
    }

    func contains(_ line: String, check: () throws -> Void) throws -> Bool {
        try check()
        guard let expression else { return caseSensitive ? line.contains(query) : line.localizedCaseInsensitiveContains(query) }
        guard now() < deadline else { throw AIFileToolError.regexBudget }
        var found = false, failure: Error?
        withoutActuallyEscaping(check) { current in
            expression.enumerateMatches(in: line, options: [.reportProgress, .reportCompletion],
                range: NSRange(line.startIndex..<line.endIndex, in: line)) { match, flags, stop in
                do {
                    try current()
                    guard now() < deadline, !flags.contains(.internalError) else { throw AIFileToolError.regexBudget }
                    if match != nil { found = true; stop.pointee = true }
                } catch { failure = error; stop.pointee = true }
            }
        }
        if let failure { throw failure }
        try check()
        guard now() < deadline else { throw AIFileToolError.regexBudget }
        return found
    }
}
