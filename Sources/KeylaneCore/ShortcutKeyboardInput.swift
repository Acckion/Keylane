/// The selected chord is independent of the modifiers currently held on the physical keyboard.
public struct ShortcutKeyboardInput: Equatable {
    public private(set) var selected: Shortcut
    public private(set) var previewModifiers: UInt32?
    private var heldModifiers: UInt32 = 0
    private var awaitingKey = false

    public init(selected: Shortcut) {
        self.selected = selected
    }

    public mutating func modifiersChanged(_ modifiers: UInt32) {
        if modifiers & ~heldModifiers != 0 { awaitingKey = true }
        if modifiers == 0 { awaitingKey = false }
        heldModifiers = modifiers
        previewModifiers = awaitingKey ? modifiers : nil
    }

    public mutating func select(_ shortcut: Shortcut) {
        selected = shortcut
        previewModifiers = nil
        awaitingKey = false
    }

    public mutating func resetPreview() {
        heldModifiers = 0
        awaitingKey = false
        previewModifiers = nil
    }
}
