import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

public struct QRCodeView: View {
    public let content: String
    public var size: CGFloat = 220

    private let context = CIContext()

    public init(content: String, size: CGFloat = 220) {
        self.content = content
        self.size = size
    }

    public var body: some View {
        Group {
            if let nsImage = generateQRCode(from: content) {
                Image(nsImage: nsImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.12))
                        .frame(width: size, height: size)
                    VStack(spacing: 8) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("Session Inactive")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let scale = max(8.0, (size * 2.0) / outputImage.extent.width)
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
