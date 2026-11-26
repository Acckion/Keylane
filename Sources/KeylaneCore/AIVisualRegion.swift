import Foundation

public enum AIVisualRegion {
    public static func pixelRect(_ normalized: CGRect, width: Int, height: Int) throws -> CGRect {
        guard normalized.minX.isFinite, normalized.minY.isFinite, normalized.width.isFinite, normalized.height.isFinite,
              normalized.minX >= 0, normalized.minY >= 0, normalized.maxX <= 1, normalized.maxY <= 1,
              normalized.width > 0, normalized.height > 0, width > 0, height > 0 else { throw AIResponseError.invalidImage }
        // Stay inside the requested region; outward rounding could capture an extra edge pixel.
        let left = ceil(normalized.minX * Double(width)), top = ceil(normalized.minY * Double(height))
        let right = floor(normalized.maxX * Double(width)), bottom = floor(normalized.maxY * Double(height))
        guard right - left >= 8, bottom - top >= 8 else { throw AIResponseError.invalidImage }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    public static func globalRect(_ normalized: CGRect, window: CGRect) -> CGRect {
        .init(x: window.minX + normalized.minX * window.width, y: window.minY + normalized.minY * window.height,
              width: normalized.width * window.width, height: normalized.height * window.height)
    }
}

public enum AIVisualAccessibilityPolicy {
    public static func canVisit(role: String, subrole: String, hidden: Bool, protected: Bool) -> Bool {
        !hidden && !protected && role != "AXSecureTextField" && subrole != "AXSecureTextField"
    }
    public static func canReadValue(role: String) -> Bool {
        ["AXStaticText", "AXTextArea", "AXTextField", "AXButton", "AXLink", "AXCheckBox", "AXRadioButton",
         "AXCell", "AXHeading", "AXPopUpButton", "AXMenuButton", "AXComboBox"].contains(role)
    }
}
