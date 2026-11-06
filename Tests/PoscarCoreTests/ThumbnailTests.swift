import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PoscarCore

@Suite struct ThumbnailTests {
    @Test func previewsLargeImagesAsSmallJPEGs() throws {
        let png = try makePNG(width: 1600, height: 900)
        let attachment = MailAttachment(id: 3, filename: "photo.png", mimeType: "image/png", data: png, contentID: nil, isInline: false)
        let thumbnail = try #require(AttachmentThumbnails.thumbnail(for: attachment))
        let size = try pixelSize(of: thumbnail)
        #expect(size.width == 360)
        #expect(size.height == 203 || size.height == 202)
    }

    @Test func previewsFirstPDFPage() throws {
        let attachment = MailAttachment(
            id: 1, filename: "polisa.pdf", mimeType: "application/octet-stream", data: makePDF(), contentID: nil, isInline: false
        )
        let thumbnail = try #require(AttachmentThumbnails.thumbnail(for: attachment))
        let size = try pixelSize(of: thumbnail)
        #expect(size.height == 360)
        #expect(size.width < size.height)
    }

    @Test func skipsOtherFiles() {
        let attachment = MailAttachment(id: 2, filename: "notes.txt", mimeType: "text/plain", data: Data("hi".utf8), contentID: nil, isInline: false)
        #expect(AttachmentThumbnails.thumbnail(for: attachment) == nil)
        #expect(AttachmentThumbnails.make(for: [attachment]).isEmpty)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 50, y: 700, width: 300, height: 40))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func pixelSize(of jpeg: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }
}
