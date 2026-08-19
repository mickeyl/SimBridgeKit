import AppKit

public extension NSImage {
    /// A copy whose backing bitmap matches the given point size (at 2×), so
    /// repeated drawing never pays for downsampling a full-resolution source.
    ///
    /// Panel views draw brand icons from multi-megabyte `.icns` files; handing
    /// SwiftUI the original makes every layout pass rescale a 1024-pixel
    /// representation. Pre-scale once, then drawing is cheap.
    func sbkScaled(toPointSize points: CGFloat) -> NSImage {
        let pixels = Int(points * 2)
        guard let source = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixels,
                  height: pixels,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return self }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let scaled = context.makeImage() else { return self }
        return NSImage(cgImage: scaled, size: NSSize(width: points, height: points))
    }
}
