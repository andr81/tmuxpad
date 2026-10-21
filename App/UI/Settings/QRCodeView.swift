import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR-код строки; модули масштабируются без сглаживания.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240)
                .accessibilityLabel("QR-код публичного ключа")
        }
    }

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    QRCodeView(text: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample tmuxpad-iPad")
}
