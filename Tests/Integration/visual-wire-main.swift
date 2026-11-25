
// CI runs the same wire fixture as the signed product-linked visual test, without credentials or signing.
var visualWireFinished = false
Task { @MainActor in
    do {
        let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let data = NSMutableData()
        let encoder = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(encoder))
        let image = try AIImageInput(data: data as Data, mediaType: "image/jpeg", width: 24, height: 16)
        try await verifyVisualWire(image: image)
        try await verifyVisualConversationRegressions(image: image)
        try await verifyVisualResourceComposition(image: image)
    } catch { fatalError("Visual wire fixture: \(error)") }
    visualWireFinished = true
}
wait("Shared visual wire protocol and capability fixtures") { visualWireFinished }
