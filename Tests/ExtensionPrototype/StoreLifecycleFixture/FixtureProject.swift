import CryptoKit
import Foundation
import KeylaneCore

enum FixtureProject {
    static let slug = "store-lifecycle-synthetic"
    static let recipe = "test-noview-synthetic-v2"

    static func load() throws -> (RaycastStoreSource, RaycastStoreBuildProject) {
        let revision = String(repeating: "a", count: 40)
        let command = """
        import { Clipboard, getPreferenceValues, showHUD } from '@raycast/api';
        export default async function(props: { arguments: { token: string } }) {
          const token = props.arguments.token;
          const prefs = getPreferenceValues<{ uppercase: boolean, action: string, optionalPassword?: string }>();
          if (token !== '00112233445566778899aabbccddeeff' || prefs.uppercase !== true ||
              prefs.action !== 'copy' || Object.hasOwn(prefs, 'optionalPassword')) throw new Error('synthetic context mismatch');
          await Clipboard.copy('synthetic:' + token.toUpperCase());
          let denied = false;
          try { await Clipboard.paste('never-paste-synthetic'); }
          catch (error) { denied = /Capability unavailable/.test(String(error)); }
          if (!denied) throw new Error('paste was not denied');
          await showHUD('Paste was denied', {clearRootSearch:true});
        }
        """
        let files = [
            "package.json": Data(#"{"name":"store-lifecycle-synthetic","author":"fixture","title":"Signed Lifecycle Fixture","preferences":[{"name":"action","title":"Action","type":"textfield","required":true},{"name":"uppercase","title":"Uppercase","type":"checkbox","default":true},{"name":"optionalPassword","title":"Unused test field","type":"password"}],"commands":[{"name":"entry","title":"Entry","mode":"no-view","arguments":[{"name":"token","type":"text","required":true}]}]}"#.utf8),
            "src/entry.ts": Data(command.utf8),
            "src/inert.ts": Data("export const inert = 42;".utf8)
        ]
        let tree = files.map { path, body -> [String: Any] in
            let blob = Insecure.SHA1.hash(data: Data("blob \(body.count)\0".utf8) + body).map { String(format: "%02x", $0) }.joined()
            return ["path": path, "sha": blob, "size": body.count, "mode": "100644", "type": "blob"]
        } + [["path": "src", "sha": revision, "mode": "040000", "type": "tree"]]
        let source = try RaycastStoreSource(slug: slug, catalog: .init(revision: revision, slugs: [slug]))
        let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: revision,
            recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha": revision, "truncated": false, "tree": tree]))
        return (source, try .init(source: .init(snapshot: snapshot, files: files), supportedRuntimeAPIVersions: [], tarballs: [:]))
    }
}
