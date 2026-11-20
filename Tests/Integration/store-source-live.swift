import Darwin
import Foundation

/// Opt-in metadata/source acquisition only. Compile with the four Store source
/// types, not with extension code. No files downloaded here are executed or installed.
@main
struct StoreSourceLiveQA {
    static func main() async {
        guard ProcessInfo.processInfo.environment["KEYLANE_STORE_LIVE_QA"] == "1" else {
            print("SKIP: set KEYLANE_STORE_LIVE_QA=1 for public read-only network verification")
            return
        }
        guard CommandLine.arguments.count == 3 else {
            print("Usage: store-source-live <full-chmod-commit> <full-uuid-commit>")
            exit(64)
        }
        var failed = false
        let catalog = RaycastPublicCatalog()
        do {
            let index = try await catalog.loadIndex()
            print("CATALOG revision=\(index.revision) count=\(index.slugs.count)")
            for (slug, revision) in zip(["chmod-lookup", "uuid-generator"], CommandLine.arguments.dropFirst()) {
                guard index.slugs.contains(slug) else {
                    failed = true
                    print("SOURCE \(slug): not present in current complete directory")
                    continue
                }
                let source = try RaycastStoreSource(slug: slug, catalog: .init(revision: revision, slugs: [slug]))
                do {
                    let package = try await catalog.prepareSource(source)
                    let lock = package.files["package-lock.json"].flatMap {
                        (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                    }
                    print("SOURCE slug=\(slug) revision=\(revision) files=\(package.files.count) bytes=\(package.files.values.reduce(0) { $0 + $1.count })")
                    print("ATTRIBUTION name=\(package.metadata.name) author=\(package.metadata.author ?? "not declared") license=\(package.metadata.license ?? "not declared") licenseFiles=\(package.licensePaths)")
                    print("LOCK present=\(package.files["package-lock.json"] != nil) version=\(lock?["lockfileVersion"] ?? "unknown") commands=\(package.metadata.commands.map(\.name))")
                } catch RaycastPublicCatalog.Failure.rateLimited {
                    print("STOP: GitHub rate limit, no retry")
                    exit(2)
                } catch {
                    failed = true
                    print("SOURCE_FAILED slug=\(slug) revision=\(revision) error=\(error)")
                }
            }
        } catch RaycastPublicCatalog.Failure.rateLimited {
            print("STOP: GitHub rate limit, no retry")
            exit(2)
        } catch {
            failed = true
            print("CATALOG_FAILED \(error)")
        }
        print("No extension execution, build, installation or dependency scripts occurred.")
        if failed { exit(1) }
    }
}
