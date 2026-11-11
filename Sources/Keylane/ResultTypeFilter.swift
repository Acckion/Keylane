import SwiftUI
import KeylaneCore
import UniformTypeIdentifiers

struct ResultFilterOption: Identifiable {
    let id: String
    let title: String
    let symbol: String
    static let clipboard: [Self] = [
        .init(id: "all", title: "全部类型", symbol: "list.bullet"),
        .init(id: "text", title: "仅文字", symbol: "textformat"),
        .init(id: "image", title: "仅图片", symbol: "photo"),
        .init(id: "files", title: "仅文件", symbol: "doc")
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
    var width: CGFloat = 138
    var searchPlaceholder = "搜索类型…"
    @State private var query = ""
    @State private var hovered: String?
    @FocusState private var searchFocused: Bool
    private var current: ResultFilterOption { options.first { $0.id == selection } ?? ResultFilterOption(id: "all", title: "全部类型", symbol: "list.bullet") }
    private var matches: [ResultFilterOption] { options.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if open {
            VStack(spacing: 0) {
                TextField(searchPlaceholder, text: $query).textFieldStyle(.plain)
                    .font(.system(size: 14)).focused($searchFocused).padding(14)
                    .onSubmit { if let first = matches.first { choose(first) } }
                Divider()
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(matches) { option in
                            Button { choose(option) } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: option.symbol).frame(width: 20)
                                    Text(option.title)
                                    Spacer()
                                    if selection == option.id { Image(systemName: "checkmark").font(.caption) }
                                }.font(.system(size: 14)).padding(10)
                                    .background(.primary.opacity(hovered == option.id ? 0.1 : selection == option.id ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).onHover { hovered = $0 ? option.id : nil }
                        }
                        if matches.isEmpty { Text("没有匹配类型").foregroundStyle(.secondary).padding(14) }
                    }.padding(8)
                }.frame(height: CGFloat(min(8, max(1, matches.count))) * 43 + 16)
            }.frame(width: 220, alignment: .top)
                .onAppear { searchFocused = true }
                .transition(.opacity)
            } else {
                NativeHoverButton(title: "筛选：\(current.title)", action: { query = ""; hovered = nil; open = true }) {
                    HStack(spacing: 9) {
                        Image(systemName: current.symbol)
                        Text(current.title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    }.font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(contrast == .increased ? 1 : 0.8))
                }
                .frame(width: width, height: 36)
                .transition(.opacity)
            }
        }
        .frame(width: open ? 220 : width,
               height: open ? 62 + CGFloat(min(8, max(1, matches.count))) * 43 : 36,
               alignment: .topTrailing)
        .modifier(LauncherMenuSurface(open: open))
    }
    private func choose(_ option: ResultFilterOption) { open = false; selection = option.id }
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


/// The same anchored surface and motion for every launcher corner menu.
struct LauncherMenuSurface: ViewModifier {
    let open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: open ? 21 : 18)
        content
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
            .glassEffectTransition(.identity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: open)
    }
}
