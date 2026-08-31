import SwiftUI
import QRCode

/// Renders a string as a QR code, styled with rounded/dot modules and tinted
/// to `tint` instead of a raw black-on-white barcode look. Plain CoreImage
/// only draws hard square modules with no styling hooks, so this leans on
/// the QRCode package (github.com/dagronf/QRCode) for pixel/eye shaping.
struct QRCodeView: View {
    let content: String
    var tint: Color = QRCodeView.brandDarkGrey

    /// Set when a caller is going to overlay a logo badge on top: bumps
    /// error correction to "M" (15% redundancy) — plenty of margin for a
    /// small badge (~3-4% of the code's area here) without paying "H"'s
    /// much higher module count. Left at the lowest level otherwise, which
    /// keeps the module count — and so the apparent density — as low as
    /// the content allows.
    var hasCenterMark: Bool = false

    /// Sampled from AppIcon.appiconset's background (averaged, excluding
    /// the bolt mark and transparent corners) — see InviteQRMark.imageset.
    static let brandDarkGrey = Color(red: 0x2A / 255, green: 0x30 / 255, blue: 0x40 / 255)

    var body: some View {
        if let image = makeQRCode(from: content) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Text("QR unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
        }
    }

    private func makeQRCode(from string: String) -> UIImage? {
        let doc = QRCode.Document(
            utf8String: string,
            errorCorrection: hasCenterMark ? .medium : .low
        )

        let tintColor = UIColor(tint).cgColor
        doc.design.style.background = QRCode.FillStyle.Solid(UIColor.white.cgColor)
        doc.design.style.onPixels = QRCode.FillStyle.Solid(tintColor)
        doc.design.style.eye = QRCode.FillStyle.Solid(tintColor)
        doc.design.style.pupil = QRCode.FillStyle.Solid(tintColor)

        // A gap between modules (dots, not solid squares) reads as
        // noticeably less dense at the same module count.
        doc.design.shape.onPixels = QRCode.PixelShape.Circle(inset: 0.15)
        doc.design.shape.eye = QRCode.EyeShape.RoundedRect()

        guard let cg = doc.cgImage(CGSize(width: 800, height: 800)) else { return nil }
        return UIImage(cgImage: cg)
    }
}
