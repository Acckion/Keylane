let probeHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!, isDirectory: true)
precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == probeHome.resolvingSymlinksInPath())
precondition(Bundle.main.bundleIdentifier?.hasPrefix("org.keylane.test.iphone-applications.") == true)
let _ = NSApplication.shared
func expect(_ value: Bool, _ label: String) { if !value { print("FAIL " + label); exit(1) }; print("PASS " + label) }
func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    expect(condition(), "asynchronous request completes")
}
let defaults = UserDefaults.standard
let deviceID = UUID().uuidString
let response = try JSONSerialization.data(withJSONObject: ["info": ["outcome": "success"], "result": ["devices": [["identifier": deviceID, "properties": ["hardware": ["deviceType": "iPhone", "reality": "physical"], "state": ["name": "Fixture"], "connection": ["pairingState": "paired", "state": "connected"]]]]]])
let phoneApp = IPhoneApplication(bundleID: "com.example.same", name: "Same")
let callsLock = NSLock()
var calls: [[String]] = []
let phone = IPhoneApplications(defaults: defaults, scan: { [phoneApp] }, command: { args, _ in
    callsLock.withLock { calls.append(args) }
    return response
})
let model = Model(iPhoneApplications: phone)
let local = probeHome.appendingPathComponent("Same.app")
model.apps = [local]
model.applicationsEnabled = true
expect(!phone.enabled, "experimental feature defaults off")
expect(model.commands.contains { $0.id == local.path } && !model.commands.contains { $0.id == phoneApp.id }, "off preserves local app")
phone.enabled = true
wait { !phone.busy }
expect(model.commands.contains { $0.id == local.path } && model.commands.contains { $0.id == phoneApp.id }, "same-name apps have separate identities")
model.setAlias(phoneApp.id, value: "phone-only")
model.query = "phone-only"
expect(model.commands.map(\.id) == [phoneApp.id], "phone alias does not bind local app")
model.toggleFavorite(phoneApp.id)
expect(model.favorites.contains(phoneApp.id) && !model.favorites.contains(local.path), "phone favorite remains separate")
let provider = phone.provider(model: model)
let row = provider.entries(.init(query: "", page: .root, aliases: [:], favorites: [], usage: [:]))[0]
let actions = provider.actions?(row) ?? []
expect(Set(actions.map(\.id)) == ["open", "favorite", "settings"], "phone has no Mac uninstall, Finder, quit or restart actions")
model.disabledCommands.insert(phoneApp.id)
expect(provider.resolve(.init(rawValue: phoneApp.id), .shortcut) == nil, "disabled phone shortcut cannot resolve")
model.disabledCommands.remove(phoneApp.id)
provider.resolve(.init(rawValue: phoneApp.id), .shortcut)?()
wait { !phone.busy }
expect(callsLock.withLock { calls.last == ["device", "process", "launch", "--device", deviceID, phoneApp.bundleID] }, "launch uses selected device and bundle ID as separate arguments")
let before = callsLock.withLock { calls.count }
phone.enabled = false
expect(provider.resolve(.init(rawValue: phoneApp.id), .shortcut) == nil && provider.entries(.init(query: "", page: .root, aliases: [:], favorites: [], usage: [:])).isEmpty, "off removes results and rejects stale shortcuts")
expect(callsLock.withLock { calls.count } == before, "off makes no device request")
model.query = ""
expect(model.commands.contains { $0.id == local.path }, "local app survives phone opt-out")
expect(model.aliases[phoneApp.id] == "phone-only" && model.favorites.contains(phoneApp.id), "phone preferences retained without rebinding")
let runner = probeHome.appendingPathComponent("fake-xcrun")
try "#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".write(to: runner, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
let started = Date()
do { _ = try IPhoneDeviceCommand.run([], timeout: 0, executable: runner); expect(false, "timeout must fail") }
catch { expect(error as? IPhoneLaunchError == .timeout, "hung child reports timeout") }
expect(Date().timeIntervalSince(started) < 5, "wall-clock deadline kills unresponsive child")
let scanStarted = DispatchSemaphore(value: 0), releaseScan = DispatchSemaphore(value: 0)
let stalePhone = IPhoneApplications(defaults: defaults, scan: {
    scanStarted.signal(); _ = releaseScan.wait(timeout: .now() + 3); return [phoneApp]
}, command: { _, _ in response })
stalePhone.enabled = true
expect(scanStarted.wait(timeout: .now() + 2) == .success, "scan started in background")
stalePhone.enabled = false
releaseScan.signal()
RunLoop.main.run(until: .now.addingTimeInterval(0.1))
expect(stalePhone.apps.isEmpty && !stalePhone.busy, "opt-out discards in-flight discovery result")
print("IPHONE_APPLICATION_INTEGRATION_OK")
