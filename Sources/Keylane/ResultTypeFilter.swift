import SwiftUI
import KeylaneCore
import UniformTypeIdentifiers

struct ResultFilterOption: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var help: String? = nil
    static let clipboard: [Self] = [
        .init(id: "all", title: "全部类型", symbol: "list.bullet"),
        .init(id: "text", title: "仅文字", symbol: "textformat"),
        .init(id: "image", title: "仅图片", symbol: "photo"),
        .init(id: "files", title: "仅文件", symbol: "doc"),
        .init(id: "link", title: "仅链接", symbol: "link"),
        .init(id: "email", title: "仅邮箱", symbol: "at"),
        .init(id: "color", title: "仅颜色", symbol: "eyedropper")
    ]
    static let files: [Self] = [
        .init(id: "all", title: "全部类型", symbol: "list.bullet"),
        .init(id: "folder", title: "文件夹", symbol: "folder"),
        .init(id: "file", title: "文件", symbol: "doc"),
        .init(id: "archive", title: "压缩包", symbol: "shippingbox"),
        .init(id: "document", title: "文稿", symbol: "doc.text"),
        .init(id: "image", title: "图片", symbol: "photo"),
        .init(id: "audio", title: "音频", symbol: "music.note"),
        .init(id: "video", title: "视频", symbol: "film")
    ]
}

/// Shared searchable type selector for secondary screens.
struct ResultTypeFilter: View {
    @Binding var selection: String
    let options: [ResultFilterOption]
    @Environment(\.colorSchemeContrast) private var contrast
    @Binding var open: Bool
    var navigation = "arrows"
    var width: CGFloat = 138
    var searchPlaceholder = "搜索类型…"
    @State private var query = ""
    private var current: ResultFilterOption { options.first { $0.id == selection } ?? ResultFilterOption(id: "all", title: "全部类型", symbol: "list.bullet") }
    private var matches: [ResultFilterOption] { ResultFilterPanel.matches(options, query: query) }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if open {
                ResultFilterPanel(selection: selection, options: matches, query: $query,
                                  searchPlaceholder: searchPlaceholder, navigation: navigation,
                                  choose: { open = false; selection = $0.id }, dismiss: { open = false })
                    .transition(.opacity)
            } else {
                NativeHoverButton(title: "筛选：\(current.title)", action: { query = ""; open = true }) {
                    HStack(spacing: 9) {
                        Image(systemName: current.symbol)
                        Text(current.title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    }.font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(contrast == .increased ? 1 : 0.8))
                }
                .frame(width: width, height: VisualStyle.launcherControlDiameter)
                .transition(.opacity)
            }
        }
        .frame(width: open ? 220 : width,
               height: open ? 62 + CGFloat(min(8, max(1, matches.count))) * 43 : VisualStyle.launcherControlDiameter,
               alignment: .topTrailing)
        .modifier(LauncherMenuSurface(open: open))
    }
}

struct ResultFilterPanel: View {
    let selection: String
    let options: [ResultFilterOption]
    @Binding var query: String
    let searchPlaceholder: String
    var emptyTitle = "没有匹配类型"
    var navigation = "arrows"
    var width: CGFloat = 220
    let choose: (ResultFilterOption) -> Void
    let dismiss: () -> Void
    @State private var highlighted = 0

    static func matches(_ options: [ResultFilterOption], query: String) -> [ResultFilterOption] {
        options.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                SearchField(text: $query, placeholder: searchPlaceholder, focusToken: 0, compact: true,
                            navigation: navigation, submit: {
                                if options.indices.contains(highlighted) { choose(options[highlighted]) }
                            }, move: { delta in
                                highlighted = NavigationBounds.move(highlighted, by: delta, count: options.count)
                                if options.indices.contains(highlighted) { proxy.scrollTo(options[highlighted].id) }
                            }, escape: dismiss)
                    .padding(14)
                    .onChange(of: query) { _, _ in
                        highlighted = 0
                        if let first = options.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                Divider()
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            LauncherMenuRow(title: option.title, symbol: option.symbol, selected: highlighted == index,
                                            style: .filter, activate: { choose(option) }, highlight: { highlighted = index }) {
                                if let help = option.help {
                                    Image(systemName: "info.circle").help(help).accessibilityLabel(help)
                                } else if selection == option.id { Image(systemName: "checkmark").font(.caption) }
                            }.id(option.id)
                        }
                        if options.isEmpty { Text(emptyTitle).foregroundStyle(.secondary).padding(14) }
                    }.padding(8)
                }.frame(height: CGFloat(min(8, max(1, options.count))) * 43 + 16)
            }.frame(width: width, alignment: .top)
        }
    }

}

enum FileResultTypeFilter {
    static func includes(_ file: SpotlightFile, selection: String) -> Bool {
        if selection == "all" { return true }
        if selection == "folder" { return file.isDirectory }
        if selection == "file" { return !file.isDirectory }
        guard !file.isDirectory, let type = file.contentType else { return false }
        switch selection {
        case "archive": return type.conforms(to: .archive)
        case "document": return type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .compositeContent)
        case "image": return type.conforms(to: .image)
        case "audio": return type.conforms(to: .audio)
        case "video": return type.conforms(to: .movie)
        default: return true
        }
    }
}


/// Menu entries share pointer, keyboard and accessibility selection behavior.
struct LauncherMenuRow<Trailing: View>: View {
    enum Style { case action, filter }

    let title: String
    let symbol: String
    let selected: Bool
    var style: Style = .action
    var enabled = true
    var destructive = false
    var artwork: NSImage? = nil
    let activate: () -> Void
    let highlight: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: activate) {
            HStack(spacing: style == .action ? VisualStyle.actionSpacing : 11) {
                if artwork != nil || !symbol.isEmpty {
                    Group {
                        if let artwork { Image(nsImage: artwork).resizable().scaledToFit().frame(width: 18, height: 18) }
                        else { Image(systemName: symbol).font(VisualStyle.actionSymbol).symbolRenderingMode(.monochrome) }
                    }
                    .frame(width: style == .action ? VisualStyle.actionIconWidth : 20, height: 20)
                }
                Text(title).font(VisualStyle.rowText)
                Spacer()
                trailing()
            }
            .padding(.horizontal, style == .action ? 11 : 10)
            .frame(height: style == .action ? 39 : 40)
            .background(selected ? Color.primary.opacity(contrast == .increased ? 0.24 : 0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: VisualStyle.selectionRadius))
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { inside in if inside && enabled { highlight() } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The same anchored surface and motion for every launcher corner menu.
struct LauncherMenuSurface: ViewModifier {
    let open: Bool
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: open ? 21 : 18)
        content
            .clipShape(shape)
            .glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
            .glassEffectTransition(.identity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: open)
    }
}
