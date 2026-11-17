import AppKit
import Combine
import Contacts
import KeylaneCore
import SwiftUI

enum ContactsLauncherModule {
    private static let settingsID = "keylane.contacts"
    private static let searchPage = PageID(rawValue: "Contacts")
    private static let createPage = PageID(rawValue: "CreateContact")
    private static let createID = CommandID(rawValue: "create-contact")
    private static let sortItem = SettingsItem(id: "contacts-sort-order", page: settingsID, title: "联系人排序",
                                               keywords: "Contacts Sort By 姓氏 名字 通讯录")

    static func make(model: Model) -> LauncherModule {
        let controller = model.contacts
        let permission = PermissionFeature("contacts.enabled", authorization: .contacts, observeImmediately: false)
        let editor = ContactEditor()
        var permissionChanges: AnyCancellable?
        let search = LauncherModule.Command(declaration: .init(
            id: .init(rawValue: "contacts"), title: "搜索联系人", detail: "系统通讯录", symbol: "person.crop.circle",
            keywords: ["Contacts", "Address Book", "联系人", "通讯录"], destination: .page(searchPage), settingsPage: settingsID
        ), permission: permission)
        let create = LauncherModule.Command(declaration: .init(
            id: createID, title: "新建联系人", detail: "添加到系统通讯录", symbol: "person.badge.plus",
            keywords: ["Create Contact", "New Contact", "添加联系人"], destination: .page(createPage), settingsPage: settingsID
        ), available: { !editor.saving }, permission: permission, execute: { [weak model] _ in
            editor.prepare(returnTo: model?.pageID == searchPage ? searchPage : .root)
        })
        let selectedContact = controller.$visible.combineLatest(controller.$selectedID)
            .map { results, id in results.first { $0.id == id } }
        let searchView = LauncherPage(
            id: searchPage, placeholder: "搜索联系人…", badge: ("搜索联系人", "person.crop.circle"),
            contentPlacement: .underChrome,
            content: { [weak model] in
                AnyView(ContactsPage(controller: controller, permission: permission,
                                     showSettings: { model?.openSettings(page: settingsID) }))
            }, queryChanged: { controller.query = $0 }, leave: controller.stop, move: controller.move,
            submit: { [weak model] in
                guard let contact = controller.selected else { return }
                openContact(contact, controller: controller, model: model)
            }, actionContextTitle: { controller.selected?.name }, primaryTitle: { "在通讯录中打开" },
            primaryEnabled: { controller.selected != nil },
            actions: { [weak model] in
                guard let model else { return [] }
                return contactActions(controller, editor: editor, permission: permission, model: model)
            },
            updates: Publishers.MergeMany([ViewObservation.changes(selectedContact), permission.updates,
                                            ViewObservation.changes(editor.$saving)]).eraseToAnyPublisher(),
            enter: { query in
                controller.query = query
                if permission.available { controller.start() }
                return nil
            }, resume: { if permission.available { controller.start() } },
            actionShortcutsEnabled: true, loading: controller.$loading.eraseToAnyPublisher()
        )

        let back: () -> Void = { [weak model] in model?.pageID = editor.returnPage }
        let submit = { [weak model] in
            guard permission.available else { editor.error = "联系人访问权限不可用。"; return }
            editor.save { guard model?.pageID == createPage else { return }; back() }
        }
        let form = LauncherPage(
            id: createPage, placeholder: "", badge: ("新建联系人", "person.badge.plus"), contentPlacement: .form,
            content: { AnyView(ContactCreationView(editor: editor, back: back)) }, back: back,
            submit: submit, returnBindings: .init(primary: .command), primaryTitle: { "保存联系人" },
            primaryEnabled: { permission.available && editor.canSave },
            updates: Publishers.MergeMany([ViewObservation.changes(editor.$draft), ViewObservation.changes(editor.$saving),
                                            permission.updates]).eraseToAnyPublisher()
        )
        let settings = LauncherSettingsPage(
            id: settingsID, title: "联系人", symbol: "person.crop.circle", subtitle: "搜索和管理系统通讯录。",
            order: 129, items: [sortItem], titlebar: permission.titlebar("启用联系人"),
            centeredHeader: true, content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(ContactsPreferences(controller: controller, model: model, commands: [create, search]))
            })
        return .init(id: .init(rawValue: settingsID), commands: [search, create], pages: [searchView, form],
                     settings: [settings], services: [.init(start: { [weak model] in
            permission.startObserving()
            permissionChanges = permission.updates.receive(on: DispatchQueue.main).sink { [weak model] in
                if !permission.available {
                    controller.stop()
                } else if model?.pageID == searchPage, (NSApp.delegate as? Delegate)?.window?.isVisible == true {
                    controller.start()
                }
            }
        }, stop: {
            permissionChanges?.cancel()
            permissionChanges = nil
            permission.stopObserving()
            controller.stop()
        })], searchUpdates: [permission.updates, ViewObservation.changes(editor.$saving)])
    }

    private static func contactActions(_ controller: ContactsController, editor: ContactEditor,
                                       permission: PermissionFeature, model: Model) -> [LauncherAction] {
        let create = LauncherAction(id: "contact-new", title: "新建联系人", icon: "plus", shortcut: .init("n", modifiers: .command),
                                    enabled: permission.available && !editor.saving && !model.disabledCommands.contains(createID.rawValue),
                                    perform: { [weak model] in model?.runCommand(createID, origin: .search) })
        let refresh = LauncherAction(id: "contacts-refresh", title: "刷新联系人", icon: "arrow.clockwise",
                                     group: 3, enabled: permission.available, perform: controller.refresh)
        guard let contact = controller.selected else { return [create, refresh] }

        var actions: [LauncherAction] = [
            .init(id: "contacts-open", title: "在通讯录中打开", icon: "person.crop.circle", shortcut: .init(.return, modifiers: [])) { [weak model] in
                openContact(contact, controller: controller, model: model)
            },
            .init(id: "contact-edit", title: "编辑联系人", icon: "pencil", shortcut: .init("e", modifiers: .command)) { [weak model] in
                openContact(contact, editing: true, controller: controller, model: model)
            },
            create
        ]
        let phones = contact.phones.compactMap(ContactLink.phoneRecipient)
        let emails = contact.emails.compactMap(ContactLink.emailRecipient)
        let recipients = phones + emails
        let communication: [(ContactLink, String, String, KeyEquivalent, [String])] = [
            (.phone, "拨打电话", "phone", "p", phones),
            (.video, "FaceTime 视频通话", "video", "f", recipients),
            (.audio, "FaceTime 音频通话", "phone", "a", recipients),
            (.message, "发送信息", "message", "m", recipients)
        ]
        for (link, title, icon, key, values) in communication {
            var seen: Set<String> = []
            let items = values.compactMap { recipient -> LauncherAction? in
                guard seen.insert(recipient).inserted, let url = link.url(recipient: recipient) else { return nil }
                return .init(id: recipient, title: recipient, icon: icon) { [weak model] in
                    guard controller.authorizedSelection(contact.id) != nil else { return }
                    open(url, failure: "无法打开「\(title)」。", model: model)
                }
            }
            guard let first = items.first else { continue }
            actions.append(.init(id: link.rawValue, title: title, icon: icon, shortcut: .init(key, modifiers: [.shift, .command]),
                                 submenu: items.count > 1 ? .init(title: title, items: items) : nil,
                                 group: 1, perform: first.perform))
        }
        actions.append(.init(id: "contact-copy-name", title: "复制全名", icon: "doc.on.clipboard",
                             shortcut: .init("c", modifiers: [.shift, .command]), group: 2) {
            controller.copy(contact.name, for: contact.id)
        })
        actions += contact.phones.enumerated().map { index, value in
            .init(id: "phone-\(index)", title: contact.phones.count == 1 ? "复制电话号码" : "复制电话 " + value,
                  icon: "phone", shortcut: index == 0 ? .init("c", modifiers: [.option, .command]) : nil, group: 2) {
                controller.copy(value, for: contact.id)
            }
        }
        actions += contact.emails.enumerated().map { index, value in
            .init(id: "email-\(index)", title: contact.emails.count == 1 ? "复制邮箱" : "复制邮箱 " + value,
                  icon: "envelope", shortcut: index == 0 && contact.phones.isEmpty ? .init("c", modifiers: [.option, .command]) : nil, group: 2) {
                controller.copy(value, for: contact.id)
            }
        }
        actions.append(refresh)
        actions.append(.init(id: "contact-delete", title: "删除联系人", icon: "trash", shortcut: .init("x", modifiers: .control),
                             group: 4, enabled: !editor.saving, destructive: true) { [weak model] in
            guard controller.authorizedSelection(contact.id) != nil,
                  let window = NSApp.keyWindow, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = "删除「\(contact.name)」？"
            alert.informativeText = "此联系人将从系统通讯录中移除。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "删除").hasDestructiveAction = true
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn, permission.available else { return }
                editor.delete(contact.id) { success in
                    if success { controller.refresh() }
                    else { model?.error = "无法删除联系人，请检查通讯录权限或账户是否允许修改。" }
                }
            }
        })
        return actions
    }

    private static func openContact(_ contact: ContactSummary, editing: Bool = false,
                                    controller: ContactsController, model: Model?) {
        guard controller.authorizedSelection(contact.id) != nil, let url = ContactLink.card(contact.id, editing: editing) else { return }
        open(url, failure: "无法在通讯录中打开所选联系人。", model: model)
    }

    private static func open(_ url: URL, failure: String, model: Model?) {
        if NSWorkspace.shared.open(url) { (NSApp.delegate as? Delegate)?.hideLauncher() }
        else { model?.error = failure }
    }

    private struct ContactsPreferences: View {
        @ObservedObject var controller: ContactsController
        let model: Model
        let commands: [LauncherModule.Command]

        var body: some View {
            SettingsPageSections {
                SettingsGroup {
                    SettingsPicker("排序方式", detail: "按姓氏或名字排序和分组。", selection: $controller.sortOrder) {
                        ForEach(ContactSortOrder.allCases, id: \.self) { order in
                            Text(order.title).tag(order)
                        }
                    }
                }.settingsAnchor(sortItem)
                SettingsSectionTitle(title: "联系人命令")
                ExtensionCommandPreferences(model: model, commands: commands)
            }
        }
    }
}

enum ContactLink: String {
    case phone = "tel", video = "facetime", audio = "facetime-audio", message = "sms"

    func url(recipient: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "+@-._")
        guard let encoded = recipient.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else { return nil }
        return URL(string: rawValue + ":" + encoded)
    }

    static func card(_ identifier: String, editing: Bool) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ":._-")
        guard !identifier.isEmpty, let path = identifier.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "addressbook://" + path + (editing ? "?edit" : ""))
    }

    static func phoneRecipient(_ value: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-()."))
        let compact = value.unicodeScalars.filter { !separators.contains($0) }.map(String.init).joined()
        let digits = compact.dropFirst(compact.hasPrefix("+") ? 1 : 0)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return compact
    }

    static func emailRecipient(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }),
              text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return text
    }
}

private struct ContactDraft: Equatable, Sendable {
    var givenName = ""
    var familyName = ""
    var organization = ""
    var phone = ""
    var email = ""

    var isValid: Bool {
        [givenName, familyName, organization, phone, email].contains { !Self.trim($0).isEmpty }
    }

    func makeContact() -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = Self.trim(givenName)
        contact.familyName = Self.trim(familyName)
        contact.organizationName = Self.trim(organization)
        let number = Self.trim(phone)
        if !number.isEmpty {
            contact.phoneNumbers = [.init(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: number))]
        }
        let address = Self.trim(email)
        if !address.isEmpty { contact.emailAddresses = [.init(label: CNLabelOther, value: address as NSString)] }
        return contact
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private final class ContactEditor: ObservableObject {
    @Published var draft = ContactDraft()
    @Published private(set) var saving = false
    @Published var error = ""
    private(set) var returnPage: PageID = .root

    var canSave: Bool { !saving && draft.isValid }

    func prepare(returnTo page: PageID) {
        guard !saving else { return }
        returnPage = page
        draft = ContactDraft()
        error = ""
    }

    func save(completion: @escaping () -> Void) {
        guard canSave else { return }
        let snapshot = draft
        error = ""
        mutate({ store, request in
            request.add(snapshot.makeContact(), toContainerWithIdentifier: nil)
        }, completion: { [weak self] success in
            if success { completion() }
            else { self?.error = "无法保存联系人，请检查通讯录权限和默认账户。" }
        })
    }

    func delete(_ id: String, completion: @escaping (Bool) -> Void) {
        mutate({ store, request in
            let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: [CNContactIdentifierKey as NSString])
            guard let mutable = contact.mutableCopy() as? CNMutableContact else { throw CocoaError(.fileWriteUnknown) }
            request.delete(mutable)
        }, completion: completion)
    }

    private func mutate(_ configure: @escaping @Sendable (CNContactStore, CNSaveRequest) throws -> Void,
                        completion: @escaping (Bool) -> Void) {
        guard !saving else { return }
        saving = true
        let operation = Task.detached(priority: .userInitiated) {
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return false }
            do {
                let store = CNContactStore()
                let request = CNSaveRequest()
                try configure(store, request)
                try store.execute(request)
                return true
            } catch {
                return false
            }
        }
        Task { @MainActor [weak self] in
            let success = await operation.value
            guard let self else { return }
            self.saving = false
            completion(success)
        }
    }
}

private struct ContactCreationView: View {
    @ObservedObject var editor: ContactEditor
    let back: () -> Void
    @FocusState private var focused: Field?

    private enum Field: CaseIterable {
        case familyName, givenName, organization, phone, email

        var title: String {
            switch self {
            case .familyName: "姓氏"
            case .givenName: "名字"
            case .organization: "公司"
            case .phone: "电话"
            case .email: "邮箱"
            }
        }

        var keyPath: WritableKeyPath<ContactDraft, String> {
            switch self {
            case .familyName: \.familyName
            case .givenName: \.givenName
            case .organization: \.organization
            case .phone: \.phone
            case .email: \.email
            }
        }
    }

    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            ForEach(Field.allCases, id: \.self) { field in
                LauncherCreationField(field.title) {
                    LauncherCreationControl(focused: focused == field) {
                        TextField(field.title, text: $editor.draft[dynamicMember: field.keyPath])
                            .textFieldStyle(.plain).focused($focused, equals: field)
                    }
                    .disabled(editor.saving)
                }
            }
            if !editor.error.isEmpty {
                LauncherCreationField("") { Text(editor.error).foregroundStyle(.red) }
            }
        }
        .task { focused = .familyName }
    }
}
