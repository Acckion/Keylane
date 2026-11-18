import AppKit
import Combine
import SwiftUI

/// Full-height native sidebars give each column its own titlebar section.
final class AIChatSplitViewController: NSSplitViewController {
    let historyItem: NSSplitViewItem
    let conversationItem: NSSplitViewItem
    let settingsItem: NSSplitViewItem
    private var changes: [AnyCancellable] = []
    private var collapsedChanges: [NSKeyValueObservation] = []

    init(controller: QuickAIController, configuration: AIConfiguration,
         interaction: AIInteractionPreferences, composer: AIChatComposer,
         presentation: AIChatPresentation) {
        func host(_ column: AIChatView.Column) -> NSViewController {
            NSHostingController(rootView: AIChatView(column: column, controller: controller,
                configuration: configuration, interaction: interaction,
                composer: composer, presentation: presentation))
        }
        historyItem = NSSplitViewItem(sidebarWithViewController: host(.sidebar))
        conversationItem = NSSplitViewItem(viewController: host(.conversation))
        settingsItem = NSSplitViewItem(inspectorWithViewController: host(.settings))
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        historyItem.minimumThickness = 210
        historyItem.maximumThickness = 320
        historyItem.preferredThicknessFraction = 0.23
        historyItem.allowsFullHeightLayout = true
        historyItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        historyItem.holdingPriority = .defaultHigh
        historyItem.isCollapsed = !presentation.sidebarVisible
        conversationItem.minimumThickness = 400
        conversationItem.automaticallyAdjustsSafeAreaInsets = true
        settingsItem.minimumThickness = 280
        settingsItem.maximumThickness = 380
        settingsItem.preferredThicknessFraction = 0.28
        settingsItem.allowsFullHeightLayout = true
        settingsItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        settingsItem.holdingPriority = .defaultHigh
        settingsItem.isCollapsed = !presentation.settingsVisible
        addSplitViewItem(historyItem)
        addSplitViewItem(conversationItem)
        addSplitViewItem(settingsItem)
        changes = [
            presentation.$sidebarVisible.removeDuplicates().sink { [weak self] visible in
                self?.historyItem.isCollapsed = !visible
            },
            presentation.$settingsVisible.removeDuplicates().sink { [weak self] visible in
                self?.settingsItem.isCollapsed = !visible
            }
        ]
        collapsedChanges = [
            historyItem.observe(\.isCollapsed, options: [.new]) { item, _ in
                if presentation.sidebarVisible == item.isCollapsed { presentation.sidebarVisible = !item.isCollapsed }
            },
            settingsItem.observe(\.isCollapsed, options: [.new]) { item, _ in
                if presentation.settingsVisible == item.isCollapsed { presentation.settingsVisible = !item.isCollapsed }
            }
        ]
    }

    required init?(coder: NSCoder) { fatalError("Use the controller initializer") }
}
