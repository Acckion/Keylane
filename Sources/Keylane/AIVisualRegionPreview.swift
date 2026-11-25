import AppKit
import SwiftUI

/// Normalized top-left coordinates shared by the visual picker and isolated preview fixtures.
struct AIVisualRegionPreview: View {
    let image: CGImage
    @Binding var region: CGRect
    var body: some View {
        let ratio = Double(image.width) / Double(image.height)
        let width = min(566, 300 * ratio), height = width / ratio
        Image(nsImage: NSImage(cgImage: image, size: .zero)).resizable()
            .frame(width: width, height: height).overlay(alignment: .topLeading) {
                Rectangle().fill(.blue.opacity(0.08)).border(.blue, width: 2)
                    .frame(width: region.width * width, height: region.height * height)
                    .offset(x: region.minX * width, y: region.minY * height)
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 3).onChanged { value in
                let x = min(max(0, value.startLocation.x), width), y = min(max(0, value.startLocation.y), height)
                let endX = min(max(0, value.location.x), width), endY = min(max(0, value.location.y), height)
                region = CGRect(x: min(x, endX) / width, y: min(y, endY) / height,
                                width: abs(endX - x) / width, height: abs(endY - y) / height)
            }).accessibilityLabel("图像范围预览，拖动可框选区域")
            .frame(maxWidth: .infinity)
    }
}
