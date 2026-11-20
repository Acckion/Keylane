import ApplicationServices

/// Match the selected range and field, even when another field contains identical text.
struct TranslationSelection {
    let element: AXUIElement
    let range: CFRange
    let text: String

    func matches(element: AXUIElement, range: CFRange, text: String) -> Bool {
        CFEqual(self.element, element) && self.range.location == range.location &&
            self.range.length == range.length && self.text == text
    }
}
