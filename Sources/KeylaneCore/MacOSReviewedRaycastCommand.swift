import Foundation

/// The macOS preview qualifies one reviewed command at a pinned official revision.
package enum MacOSReviewedRaycastCommand {
    package struct Entry: Sendable {
        package var mode: RaycastExtensionManifest.Mode { .noView }
        package static let runtimeImport = "@raycast/api"
        package let slug: String
        package let revision: String
        package let apiVersion: String
        package let commandID: String
        package let argument: String?
        package let capabilities: Set<String>
        var additionalArguments: [String] = []
        package var argumentNames: [String] { argument.map { [$0] + additionalArguments } ?? [] }
        package var argumentIsOptional: Bool { slug == "lorem-ipsum" && argument != nil }
    }

    package static let entries: [Entry] = [
        .init(slug: "uuid-generator",
              revision: "886cbd73fe377ad1d8f0c17083e6cd4c96748a33",
              apiVersion: "1.93.2",
              commandID: "extension:raycast:jmaeso/uuid-generator/formatUuid",
              argument: "uuid",
              capabilities: ["preferences.read", "feedback.toast", "clipboard.write"]),
        .init(slug: "uuid-generator",
              revision: "886cbd73fe377ad1d8f0c17083e6cd4c96748a33",
              apiVersion: "1.93.2",
              commandID: "extension:raycast:jmaeso/uuid-generator/parseTypeID",
              argument: "typeID",
              capabilities: ["preferences.read", "feedback.toast", "clipboard.write"]),
        .init(slug: "uuid-generator",
              revision: "886cbd73fe377ad1d8f0c17083e6cd4c96748a33",
              apiVersion: "1.93.2",
              commandID: "extension:raycast:jmaeso/uuid-generator/packTypeID",
              argument: "suffix",
              capabilities: ["preferences.read", "feedback.toast", "clipboard.write"],
              additionalArguments: ["uuid"]),
        .init(slug: "silent-mention",
              revision: "6fa104a181b1d68d1b012a363eb5c8f7cfa92409",
              apiVersion: "1.85.2",
              commandID: "extension:raycast:peduarte/silent-mention/copy-zero-width-space",
              argument: nil,
              capabilities: ["feedback.toast", "clipboard.write"]),
        .init(slug: "silent-mention",
              revision: "6fa104a181b1d68d1b012a363eb5c8f7cfa92409",
              apiVersion: "1.85.2",
              commandID: "extension:raycast:peduarte/silent-mention/index",
              argument: "text",
              capabilities: ["feedback.toast", "clipboard.write"]),
        .init(slug: "lorem-ipsum",
              revision: "6fa104a181b1d68d1b012a363eb5c8f7cfa92409",
              apiVersion: "2.12.1",
              commandID: "extension:raycast:AntonNiklasson/lorem-ipsum/markdown",
              argument: nil,
              capabilities: ["preferences.read", "feedback.toast", "clipboard.write", "navigation.close"]),
        .init(slug: "lorem-ipsum",
              revision: "6fa104a181b1d68d1b012a363eb5c8f7cfa92409",
              apiVersion: "2.12.1",
              commandID: "extension:raycast:AntonNiklasson/lorem-ipsum/html",
              argument: nil,
              capabilities: ["preferences.read", "feedback.toast", "clipboard.write", "navigation.close"]),
        .init(slug: "lorem-ipsum",
              revision: "6fa104a181b1d68d1b012a363eb5c8f7cfa92409",
              apiVersion: "2.12.1",
              commandID: "extension:raycast:AntonNiklasson/lorem-ipsum/paragraphs",
              argument: "numberOfParagraphs",
              capabilities: ["preferences.read", "feedback.toast", "clipboard.write", "navigation.close"]),
        .init(slug: "lorem-ipsum",
              revision: "6fa104a181b1d68d1b012a363eb5c8f7cfa92409",
              apiVersion: "2.12.1",
              commandID: "extension:raycast:AntonNiklasson/lorem-ipsum/sentences",
              argument: "numberOfSentences",
              capabilities: ["preferences.read", "feedback.toast", "clipboard.write", "navigation.close"]),
        .init(slug: "lorem-ipsum",
              revision: "6fa104a181b1d68d1b012a363eb5c8f7cfa92409",
              apiVersion: "2.12.1",
              commandID: "extension:raycast:AntonNiklasson/lorem-ipsum/words",
              argument: "numberOfWords",
              capabilities: ["preferences.read", "feedback.toast", "clipboard.write", "navigation.close"])
    ]

    package static let slug = entries[0].slug
    package static let revision = entries[0].revision
    package static let apiVersion = entries[0].apiVersion
    package static let commandID = entries[0].commandID
    package static let argument = entries[0].argument!

    package static func entry(for source: RaycastStoreSource) -> Entry? {
        entries.first { $0.slug == source.slug && $0.revision == source.revision }
    }

    static func buildEntries(for source: RaycastStoreSource, apiVersion: String) throws -> [Entry] {
        let reviewed = entries.filter { $0.slug == source.slug && $0.revision == source.revision }
        guard let first = reviewed.first, reviewed.allSatisfy({
            $0.apiVersion == apiVersion && $0.capabilities == first.capabilities
        }) else { throw RaycastStoreBuildDependencies.Failure.unsupportedRuntimeAPI(apiVersion) }
        return reviewed
    }

    package static func entry(forCommandID commandID: String) -> Entry? {
        entries.first { $0.commandID == commandID }
    }

    package static func entry(forSlug slug: String) -> Entry? {
        entries.first { $0.slug == slug }
    }

    package static func supports(_ source: RaycastStoreSource) -> Bool {
        entry(for: source) != nil
    }

    /// Git tree verified against the pinned official revision at review time.
    /// Source bodies are still fetched at install time and checked against these blob IDs.
    static func snapshot(for source: RaycastStoreSource) throws -> RaycastStoreSnapshot {
        guard let entry = entry(for: source) else {
            throw RaycastStoreArtifactSeal.Failure.identity
        }
        if entry.slug == "lorem-ipsum" {
            let treeSHA = "221b62ebbf88e5f92eff9e55097757ac2fb16596"
            let data = """
            {"sha":"\(treeSHA)","truncated":false,"tree":[
            {"path":"assets","mode":"040000","type":"tree","sha":"f8a85594e21f682c4ad4fc8a5f2f0cbe19baef46"},
            {"path":"assets/icon.png","mode":"100644","type":"blob","sha":"093368f48f750b9e25a382f3934e4dc1c9eb36e0","size":18521},
            {"path":"package-lock.json","mode":"100644","type":"blob","sha":"0c1d5a65e84ecf45393fe5f140198cd4b4d13e71","size":123290},
            {"path":"package.json","mode":"100644","type":"blob","sha":"e614983775f0e27634bb1cd553850d22475448df","size":3684},
            {"path":"src","mode":"040000","type":"tree","sha":"f3310efaa4c7fd4463cd2b8e0b7d44da91a529d8"},
            {"path":"src/html.tsx","mode":"100644","type":"blob","sha":"276b8a4244190b98e84efda24d5e96c24bf0ecc3","size":330},
            {"path":"src/paragraphs.tsx","mode":"100644","type":"blob","sha":"d0f96abc9a46f370580736cae6e04916b3f19af3","size":648},
            {"path":"src/sentences.tsx","mode":"100644","type":"blob","sha":"defe7e09a7ddd3b0752492e0362c477a9f06f3a0","size":642},
            {"path":"src/words.tsx","mode":"100644","type":"blob","sha":"1214b6eee8bf7dfc9ab06e6466064840de8f68da","size":618},
            {"path":"src/markdown.tsx","mode":"100644","type":"blob","sha":"a0d39296df78296aea822dd0e4ff74be6345b0d5","size":346},
            {"path":"src/utils.tsx","mode":"100644","type":"blob","sha":"533c37d0755a8ea23ba0fd48307af3b07ff5700f","size":6744}
            ]}
            """
            return try RaycastStoreSnapshot(source: source, treeSHA: treeSHA, recursiveTreeJSON: Data(data.utf8))
        }
        if entry.slug == "silent-mention" {
            let treeSHA = "4875d9084dc7681cb50c7b7048ea480f43f96aa3"
            let data = """
            {"sha":"\(treeSHA)","truncated":false,"tree":[
            {"path":"assets","mode":"040000","type":"tree","sha":"989ccae2c80045fa76582b2e5d905a7b3ec92a02"},
            {"path":"assets/extension-icon.png","mode":"100644","type":"blob","sha":"29bbc2308d781532ed966b39635ba8268561bc5b","size":286382},
            {"path":"package-lock.json","mode":"100644","type":"blob","sha":"a2861ff445e7be1b531988e5656c56b661cad088","size":77960},
            {"path":"package.json","mode":"100644","type":"blob","sha":"5770335e4e8234b94207fab7f6623cc8e70c9a64","size":1556},
            {"path":"src","mode":"040000","type":"tree","sha":"38b558fa1fabad669cb881e12471e929b4832f47"},
            {"path":"src/copy-zero-width-space.ts","mode":"100644","type":"blob","sha":"08fcf92401c1958d9a07fcd244f5685f81eb2352","size":208},
            {"path":"src/index.ts","mode":"100644","type":"blob","sha":"b3e6a7b6eaf3ae2991649b9c275e0a453f347127","size":731}
            ]}
            """
            return try RaycastStoreSnapshot(source: source, treeSHA: treeSHA, recursiveTreeJSON: Data(data.utf8))
        }
        guard entry.slug == "uuid-generator" else { throw RaycastStoreArtifactSeal.Failure.identity }
        let treeSHA = "aad7cb32ee3544821ece7739d3e3d62046b1a303"
        let data = """
        {"sha":"\(treeSHA)","truncated":false,"tree":[
        {"path":".eslintrc.json","mode":"100644","type":"blob","sha":"58618541a63ebb66cb90ea3ae2374446b5f4aeae","size":54},
        {"path":".gitignore","mode":"100644","type":"blob","sha":"1bdecee6756eae48c878646beac8a5181d9b6c74","size":505},
        {"path":".prettierrc","mode":"100644","type":"blob","sha":"fc0f5030683fa6196d08943646300755fce2f207","size":48},
        {"path":"CHANGELOG.md","mode":"100644","type":"blob","sha":"19cc6393f4c1fc22b234ce5867f351c1d19ee77a","size":1407},
        {"path":"README.md","mode":"100644","type":"blob","sha":"eb7697b928ea41e6426d7ca1c8ff1daef9cb5b05","size":709},
        {"path":"assets","mode":"040000","type":"tree","sha":"270b09085b67b8de870610f2851504d7a3ab7bd2"},
        {"path":"assets/command-icon.png","mode":"100644","type":"blob","sha":"aa34e2bfe5f5f2320234f6d374e89c9c39c81d78","size":17477},
        {"path":"package-lock.json","mode":"100644","type":"blob","sha":"6807aee7bbb4a60183416ee4a82ee86abb350c28","size":119748},
        {"path":"package.json","mode":"100644","type":"blob","sha":"07cc04c3c82f95e85fc89138a2ca31289463fd49","size":5710},
        {"path":"src","mode":"040000","type":"tree","sha":"a8017ab1040e031cd5aef62e1884e2679a41ddc1"},
        {"path":"src/formatUuid.ts","mode":"100644","type":"blob","sha":"6fa2ff2db3349297bea6b7e50b9c5ff09ecf69ed","size":1343},
        {"path":"src/generate.tsx","mode":"100644","type":"blob","sha":"6e9e7419499dbb5171926e5e6e7963287bfb3bf7","size":1906},
        {"path":"src/generateTypeID.ts","mode":"100644","type":"blob","sha":"96e4397160b8963983e6ceb597d226da3a0044e1","size":2289},
        {"path":"src/generateUlid.tsx","mode":"100644","type":"blob","sha":"30954b9df080d62b2271edb80945c0d5bda0c448","size":1957},
        {"path":"src/generateV5.tsx","mode":"100644","type":"blob","sha":"dea68434a7f6389fc3832107d6e8f990796666f5","size":2418},
        {"path":"src/generateV7.tsx","mode":"100644","type":"blob","sha":"5f02dc6739f21913ee0796e73b812ccffcf39158","size":2059},
        {"path":"src/packTypeID.ts","mode":"100644","type":"blob","sha":"26ec562ce2cd2b3d3cac2176d4e80211899e4e0f","size":2535},
        {"path":"src/parseTypeID.ts","mode":"100644","type":"blob","sha":"898f28375806cddaeee13730b72d72a06fd5ab93","size":987},
        {"path":"src/utils","mode":"040000","type":"tree","sha":"852fafcf9de962b0ba15e1a15dc3bac8bf48be59"},
        {"path":"src/utils/uuidUtils.ts","mode":"100644","type":"blob","sha":"5398f48ca726ae663b5aded1ec332edb4e8f12e6","size":548},
        {"path":"src/uuidHistory.ts","mode":"100644","type":"blob","sha":"55a0c2b0efabd7c3cc131d6357bd184c370f43a1","size":2962},
        {"path":"src/viewHistory.tsx","mode":"100644","type":"blob","sha":"485497e55477199b19c049de4570bbfad1d8e160","size":3427},
        {"path":"tsconfig.json","mode":"100644","type":"blob","sha":"abb15806beca5a20e5408097fbaf39c6c7517129","size":409}
        ]}
        """
        return try RaycastStoreSnapshot(source: source, treeSHA: treeSHA, recursiveTreeJSON: Data(data.utf8))
    }

    /// Previously retrieved official manifest, checked again against the pinned blob.
    static func cachedManifest(for source: RaycastStoreSource) -> Data? {
        guard entry(for: source)?.slug == "lorem-ipsum" else { return nil }
        let manifest = #"""
        {
          "$schema": "https://www.raycast.com/schemas/extension.json",
          "name": "lorem-ipsum",
          "title": "Lorem Ipsum",
          "description": "Generate Lorem Ipsum placeholder text as paragraphs, sentences or words and copy it to the clipboard, or generate placeholder text with AI.",
          "icon": "icon.png",
          "author": "AntonNiklasson",
          "contributors": [
            "GastroGeek",
            "stelo",
            "enkia",
            "j3lte"
          ],
          "keywords": [
            "generator",
            "paragraphs",
            "sentences",
            "words",
            "text",
            "lorem",
            "ipsum"
          ],
          "platforms": [
            "macOS",
            "Windows"
          ],
          "categories": [
            "Data",
            "Design Tools",
            "Developer Tools",
            "Web"
          ],
          "license": "MIT",
          "commands": [
            {
              "name": "paragraphs",
              "title": "Generate Paragraphs",
              "subtitle": "Lorem Ipsum",
              "description": "Generate random paragraphs and copy them to the clipboard",
              "mode": "no-view",
              "arguments": [
                {
                  "name": "numberOfParagraphs",
                  "type": "text",
                  "required": false,
                  "placeholder": "No. of paragraphs"
                }
              ]
            },
            {
              "name": "sentences",
              "title": "Generate Sentences",
              "subtitle": "Lorem Ipsum",
              "description": "Generate random sentences and copy them to the clipboard",
              "mode": "no-view",
              "arguments": [
                {
                  "name": "numberOfSentences",
                  "type": "text",
                  "required": false,
                  "placeholder": "No. of sentences"
                }
              ]
            },
            {
              "name": "words",
              "title": "Generate Words",
              "subtitle": "Lorem Ipsum",
              "description": "Generate random words and copy them to the clipboard",
              "mode": "no-view",
              "arguments": [
                {
                  "name": "numberOfWords",
                  "type": "text",
                  "required": false,
                  "placeholder": "No. of words"
                }
              ]
            },
            {
              "name": "markdown",
              "title": "Generate Markdown",
              "subtitle": "Lorem Ipsum",
              "description": "Generate random placeholder content as a Markdown document",
              "mode": "no-view"
            },
            {
              "name": "html",
              "title": "Generate HTML",
              "subtitle": "Lorem Ipsum",
              "description": "Generate random placeholder content as an HTML document",
              "mode": "no-view"
            },
            {
              "name": "ai-generate",
              "title": "Generate with AI",
              "subtitle": "Lorem Ipsum",
              "description": "Use AI to generate some placeholder text",
              "mode": "no-view",
              "arguments": [
                {
                  "name": "topic",
                  "type": "text",
                  "required": false,
                  "placeholder": "any topic"
                }
              ]
            }
          ],
          "preferences": [
            {
              "name": "action",
              "type": "dropdown",
              "title": "Default Action",
              "description": "What you would like to happen when running the command",
              "data": [
                {
                  "value": "clipboard",
                  "title": "Copy to Clipboard"
                },
                {
                  "value": "paste",
                  "title": "Paste to Active App"
                },
                {
                  "value": "pasteAndCopy",
                  "title": "Paste and Copy to Clipboard"
                }
              ],
              "default": "clipboard",
              "required": false
            }
          ],
          "dependencies": {
            "@raycast/api": "^2.12.1",
            "lorem-ipsum": "^3.0.0"
          },
          "devDependencies": {
            "@raycast/eslint-config": "^2.2.0",
            "@types/node": "^26.6.6",
            "@types/react": "^19.3.0",
            "eslint": "^10.14.0",
            "prettier": "^3.10.1",
            "typescript": "^6.0.3"
          },
          "scripts": {
            "build": "ray build -e dist",
            "dev": "ray develop",
            "fix-lint": "ray lint --fix",
            "lint": "ray lint"
          }
        }
        """#
        return Data((manifest + "\n").utf8)
    }

    static func manifest(data: Data, files: Set<String>, source: RaycastStoreSource,
                         apiVersion: String?, sealedEntries: Set<String>? = nil) throws -> RaycastExtensionManifest {
        guard let apiVersion else { return try .readStoreManifest(data, files: files) }
        let reviewed = try buildEntries(for: source, apiVersion: apiVersion)
        guard let entry = reviewed.first,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commands = object["commands"] as? [[String: Any]] else {
            throw RaycastStoreArtifactSeal.Failure.recipe
        }
        var preferences = object["preferences"] as? [[String: Any]] ?? []
        var reviewedIDs = Set(reviewed.map(\.commandID))
        if (entry.slug == "lorem-ipsum" && sealedEntries == ["src/markdown.tsx"]) ||
            (entry.slug == "uuid-generator" && sealedEntries == ["src/formatUuid.ts"]) ||
            (entry.slug == "silent-mention" && sealedEntries == ["src/copy-zero-width-space.ts"]) {
            reviewedIDs = [entry.commandID]
        }
        let reviewedNames = Set(reviewedIDs.compactMap { $0.split(separator: "/").last.map(String.init) })
        object["commands"] = commands.filter { ($0["name"] as? String).map(reviewedNames.contains) == true }
        if entry.slug == "uuid-generator" {
            for index in preferences.indices where preferences[index]["name"] as? String == "defaultAction" {
                let options = preferences[index]["data"] as? [[String: Any]]
                preferences[index]["data"] = options?.filter { $0["value"] as? String == "copy" }
            }
        }
        if entry.slug == "lorem-ipsum" {
            for index in preferences.indices where preferences[index]["name"] as? String == "action" {
                let options = preferences[index]["data"] as? [[String: Any]]
                preferences[index]["data"] = options?.filter { $0["value"] as? String == "clipboard" }
            }
        }
        object["preferences"] = preferences
        let verified = try RaycastExtensionManifest.readStoreManifest(JSONSerialization.data(withJSONObject: object), files: files)
        let reviewedByID = Dictionary(uniqueKeysWithValues: reviewed.map { ($0.commandID, $0) })
        guard Set(verified.commands.map(\.id)) == reviewedIDs,
              verified.commands.allSatisfy({ reviewedByID[$0.id]?.mode == $0.mode }) else {
            throw RaycastStoreArtifactSeal.Failure.command
        }
        return verified
    }
}
