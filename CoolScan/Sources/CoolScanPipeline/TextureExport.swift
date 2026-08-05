import CoreGraphics
import Foundation
import ImageIO

enum TextureExport {
    /// Writes a CGImage as PNG next to the cooked `.untold` file. Returns the
    /// destination URL.
    static func writePNG(_ image: CGImage, named filename: String, into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw CoolScanCookerError.textureExportFailed(filename)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CoolScanCookerError.textureExportFailed(filename)
        }
        return url
    }
}
