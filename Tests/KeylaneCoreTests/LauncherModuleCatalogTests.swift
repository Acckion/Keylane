import XCTest
@testable import KeylaneCore

final class LauncherModuleCatalogTests: XCTestCase {
    private let clipboard = ModuleID(rawValue: "keylane.clipboard")
    private let files = ModuleID(rawValue: "keylane.files")
    private let show = CommandID(rawValue: "clipboard")
    private let history = PageID(rawValue: "Clipboard")

    private func command(destination: LauncherCommandDeclaration.Destination = .action) -> LauncherCommandDeclaration {
        .init(id: show, title: "剪贴板历史", detail: "", symbol: "clipboard", keywords: [], destination: destination)
    }

    func testLegacyCommandAndPageIDsRemainIndependent() throws {
        let catalog = try LauncherModuleCatalog(modules: [
            .init(id: clipboard, commands: [command(destination: .page(history))], pages: [history])
        ])
        XCTAssertEqual(catalog.commands.first?.id.rawValue, "clipboard")
        XCTAssertEqual(catalog.commands.first?.destination, .page(history))
    }

    func testRejectsDuplicateCommandsAndMissingRoutes() {
        XCTAssertThrowsError(try LauncherModuleCatalog(modules: [
            .init(id: clipboard, commands: [command()]), .init(id: files, commands: [command()])
        ])) { XCTAssertEqual($0 as? LauncherModuleCatalog.ValidationError, .duplicateCommand(show)) }
        XCTAssertThrowsError(try LauncherModuleCatalog(modules: [
            .init(id: clipboard, commands: [command(destination: .page(history))])
        ])) { XCTAssertEqual($0 as? LauncherModuleCatalog.ValidationError, .missingPage(show, history)) }
        XCTAssertThrowsError(try LauncherModuleCatalog(modules: [
            .init(id: clipboard, commands: [command(destination: .settings("clipboard"))])
        ])) { XCTAssertEqual($0 as? LauncherModuleCatalog.ValidationError, .missingSettingsPage(show, "clipboard")) }
    }

    func testDynamicNamespaceCannotShadowAnotherProviderOrCommand() {
        XCTAssertThrowsError(try LauncherModuleCatalog(modules: [
            .init(id: files, providers: [.prefix("file:"), .prefix("file:network:")])
        ])) { XCTAssertEqual($0 as? LauncherModuleCatalog.ValidationError, .overlappingProvider(.prefix("file:network:"))) }
        XCTAssertThrowsError(try LauncherModuleCatalog(modules: [
            .init(id: clipboard, commands: [command()], providers: [.exact(show)])
        ])) { XCTAssertEqual($0 as? LauncherModuleCatalog.ValidationError, .providerOwnsStaticCommand(show)) }
    }
}
