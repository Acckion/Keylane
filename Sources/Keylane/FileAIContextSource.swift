import Foundation
import Darwin
import KeylaneCore

enum FileAIContextSource {
    static func make(files: [URL], question: String, includePaths: Bool, includeContents: Bool) -> AIActionSource {
        func version() throws -> String {
            if !includeContents { return AIActionContext.digest(files.map(\.absoluteString).joined(separator: "\n")) }
            return try files.map { url in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let cloud = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                guard cloud.isUbiquitousItem != true || cloud.ubiquitousItemDownloadingStatus != .notDownloaded else { throw AIActionError.unavailable }
                var value = stat()
                guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw AIActionError.staleSource }
                return "\(url.path):\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)"
            }.joined(separator: "\n")
        }
        return .init(moduleID: .init(rawValue: "keylane.files"), load: {
            let preparation = Task.detached(priority: .userInitiated) {
                guard files.count <= 20 else { throw AIActionError.inputTooLarge }
                let before = try version()
                var remaining = 40_000
                let content = try files.map { file in
                    try Task.checkCancellation()
                    var text = includePaths ? file.path : file.lastPathComponent
                    if includeContents {
                        let body = try AIFileAttachment.read(file, maximumFileBytes: 2_000_000, maximumTextBytes: remaining).text
                        remaining -= body.utf8.count
                        text += "\n<file-content>\n" + body + "\n</file-content>"
                    }
                    return text
                }.joined(separator: "\n\n")
                guard try version() == before else { throw AIActionError.staleSource }
                return AIActionContext(sourceID: AIActionContext.digest(String(decoding: try JSONEncoder().encode(files.map(\.standardizedFileURL.absoluteString)), as: UTF8.self)), title: "\(files.count) 个所选文件", text: "Question:\n" + question + "\n\nFile context:\n" + content, fingerprint: before)
            }
            return try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        }, isCurrent: { context in
            try await Task.detached(priority: .userInitiated) { try version() == context.fingerprint }.value
        })
    }
}
