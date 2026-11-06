import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small JPEG previews of image and PDF attachments.
public enum AttachmentThumbnails {
    public static let maxPixelSize = 360

    /// Previews keyed by attachment id; attachments that can't be previewed are skipped.
    public static func make(for attachments: [MailAttachment]) -> [Int: Data] {
        var result: [Int: Data] = [:]
        for attachment in attachments {
            if let data = thumbnail(for: attachment) { result[attachment.id] = data }
        }
        return result
    }

    public static func thumbnail(for attachment: MailAttachment) -> Data? {
        switch kind(of: attachment) {
        case .image: imageThumbnail(attachment.data)
        case .pdf: pdfThumbnail(attachment.data)
        case nil: nil
        }
    }

    enum Kind {
        case image
        case pdf
    }

    /// Senders often label files `application/octet-stream`, so the extension decides as well.
    static func kind(of attachment: MailAttachment) -> Kind? {
        let ext = (attachment.filename as NSString).pathExtension
        let type = UTType(mimeType: attachment.mimeType) ?? UTType(filenameExtension: ext)
        let byExtension = UTType(filenameExtension: ext)
        if type?.conforms(to: .pdf) == true || byExtension?.conforms(to: .pdf) == true { return .pdf }
        if type?.conforms(to: .image) == true || byExtension?.conforms(to: .image) == true { return .image }
        return nil
    }

    static func imageThumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(image)
    }

    static func pdfThumbnail(_ data: Data) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }

        let scale = CGFloat(maxPixelSize) / max(box.width, box.height)
        let width = Int(box.width * scale)
        let height = Int(box.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage().flatMap(jpeg)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
