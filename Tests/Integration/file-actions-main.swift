import AppKit
let app = NSApplication.shared
let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["KEYLANE_FILE_ACTION_TEST_ROOT"]!)
let file = root.appendingPathComponent("中文文件操作验收.txt")
try Data("Only a synthetic file-action fixture.\n".utf8).write(to:file)
let model = FileActionsModel(); model.configure(file,page:"open")
precondition(model.isAvailable)
let compatibleCount = model.applications.count
model.configure(root.appendingPathComponent("missing.txt"),page:"open")
precondition(!model.validate() && model.status.contains("移走"))
model.configure(file,page:"open"); model.selectedApplication = root.appendingPathComponent("Missing.app").path
model.openSelected(); precondition(!model.opening && model.status.contains("不可用"))
model.selectedApplication = root.appendingPathComponent("KeylaneOpenHelper.app").path
var opened = false; model.opened = { opened = true }
model.openSelected()
let deadline = Date().addingTimeInterval(15)
while !opened && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
precondition(opened,model.status)
let receiptURL = root.appendingPathComponent("receipt.json")
while !FileManager.default.fileExists(atPath:receiptURL.path) && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
let receipt = try Data(contentsOf:receiptURL)
let paths = try JSONSerialization.jsonObject(with:receipt) as! [String]
precondition(paths.count == 1 && URL(fileURLWithPath:paths[0]).resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
let original = try String(contentsOf:file,encoding:.utf8)
precondition(original == "Only a synthetic file-action fixture.\n")
let picker = NSSharingServicePicker(items:[file])
precondition(!picker.standardShareMenuItem.title.isEmpty)
try FileManager.default.removeItem(at:file)
model.configure(file,page:"share"); precondition(!model.isAvailable)
print("PASS file actions: real NSWorkspace open delivered file to own helper, original unchanged, compatible applications=\(compatibleCount), native share menu creation passed, missing file/app feedback; nothing shared")
