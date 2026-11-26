import AppKit
import KeylaneCore

setbuf(stdout, nil)
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!).appendingPathComponent("benchmark")
let scope = root.appendingPathComponent("scope")
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
for i in 0..<96 { try Data(String(repeating: "bounded benchmark text \(i) ", count: 2000).utf8).write(to: scope.appendingPathComponent("text-\(i).txt")) }
for i in 0..<80 { try Data(repeating: 65, count: 64_000).write(to: scope.appendingPathComponent("binary-\(i).bin")) }
for i in 0..<24 {
    let url = scope.appendingPathComponent("pdf-\(i).pdf")
    let pdf = CGContext(url as CFURL, mediaBox: nil, nil)!
    for page in 0..<2 {
        pdf.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
        ("PDF benchmark page \(page) " + String(repeating: "bounded document text ", count: 500) as NSString).draw(at: NSPoint(x: 30, y: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
        NSGraphicsContext.restoreGraphicsState(); pdf.endPDFPage()
    }
    pdf.closePDF()
}
let files = try FileManager.default.contentsOfDirectory(at: scope, includingPropertiesForKeys: [.contentModificationDateKey]).sorted { $0.path < $1.path }
let filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
let records = try files.map { url -> FileIndexRecord in
    let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!.timeIntervalSince1970
    return .init(path: url.path, name: url.lastPathComponent, volume: "/", modified: modified, directory: false, symlink: false)
}
func cpu() -> Double { var x = rusage(); getrusage(RUSAGE_SELF, &x); return Double(x.ru_utime.tv_sec + x.ru_stime.tv_sec) + Double(x.ru_utime.tv_usec + x.ru_stime.tv_usec) / 1e6 }
func run(_ mode: String, round: Int) throws {
    let db = try FileSearchIndex(url: root.appendingPathComponent("\(mode)-\(round).sqlite"))
    let start = Date(); let cpuStart = cpu()
    try db.transaction {
        for record in records {
            try autoreleasepool {
                if mode == "inline" {
                    try db.put(record, body: FileSearchIndex.content(at: filesByPath[record.path]!), root: scope.path, epoch: "c:scan")
                } else { try db.stageMetadata(record, root: scope.path, epoch: "c:scan", contentSearch: true) }
            }
        }
    }
    let metadataWall = Date().timeIntervalSince(start); let metadataCPU = cpu() - cpuStart
    if mode == "deferred" {
        while true {
            let jobs = try db.nextContentJobs()
            if jobs.isEmpty { break }
            let session = FileContentReader.Session()
            let updates = try jobs.map { job in try autoreleasepool { FileSearchIndex.ContentUpdate(job: job, body: try session.read(job)) } }
            _ = try db.applyContent(updates)
        }
    }
    print("MEASURE mode=\(mode) round=\(round) files=\(records.count) metadata_wall=\(metadataWall) metadata_cpu=\(metadataCPU) total_wall=\(Date().timeIntervalSince(start)) total_cpu=\(cpu() - cpuStart)")
}
for round in 1...5 {
    if round % 2 == 0 { try run("deferred", round: round); try run("inline", round: round) }
    else { try run("inline", round: round); try run("deferred", round: round) }
}
