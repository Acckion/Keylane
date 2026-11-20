import Foundation
import Darwin

/// Resolve only macOS system aliases, never links inside a user-selected scope.
enum LocalFilePath {
    static func systemCanonical(_ path: String) -> String {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where lexical == alias || lexical.hasPrefix(alias + "/") {
            guard let pointer = realpath(alias, nil) else { return lexical }; defer { free(pointer) }
            return String(cString: pointer) + lexical.dropFirst(alias.count)
        }
        return lexical
    }
    static func indexAliases(_ path: String) -> [String] {
        let canonical = systemCanonical(path)
        var paths = Set([canonical, URL(fileURLWithPath: canonical).standardizedFileURL.path])
        for alias in ["/var", "/tmp", "/etc"] {
            guard let pointer = realpath(alias, nil) else { continue }
            let target = String(cString: pointer); free(pointer)
            if canonical == target || canonical.hasPrefix(target + "/") { paths.insert(alias + canonical.dropFirst(target.count)) }
        }
        return paths.sorted()
    }
}
