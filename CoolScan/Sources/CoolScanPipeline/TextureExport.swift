import CoreGraphics
import Foundation
import ImageIO

enum TextureExport {
    /// Writes a CGImage as PNG next to the cooked `.untold` file, downscaling
    /// first when it exceeds `maxDimension` (Mac reconstructions produce 8K
    /// maps; the phone renderer caps at 1–2K). Returns the destination URL
    /// and the written size.
    @discardableResult
    static func writePNG(
        _ image: CGImage,
        named filename: String,
        into directory: URL,
        maxDimension: Int? = nil
    ) throws -> (url: URL, width: Int, height: Int) {
        let output = downscaled(image, maxDimension: maxDimension)
        let url = directory.appendingPathComponent(filename)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw CoolScanCookerError.textureExportFailed(filename)
        }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CoolScanCookerError.textureExportFailed(filename)
        }
        return (url, output.width, output.height)
    }

    /// Redraws the image so its longer edge is at most `maxDimension`.
    /// Keeps the source colour space when it is RGB so normal/roughness maps
    /// are not put through a colour conversion.
    static func downscaled(_ image: CGImage, maxDimension: Int?) -> CGImage {
        guard let maxDimension, maxDimension > 0,
              image.width > maxDimension || image.height > maxDimension
        else { return image }

        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        let colorSpace: CGColorSpace = {
            if let space = image.colorSpace, space.model == .rgb { return space }
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
