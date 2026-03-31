import SwiftUI
import AVFoundation

/// Full-screen camera view that scans a QR code and calls `onScan` with
/// the decoded string, then dismisses itself.
struct QRScannerView: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CameraPreview(onScan: { value in
                onScan(value)
                dismiss()
            })
            .ignoresSafeArea()

            // Scan-frame guide
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white, lineWidth: 3)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.4), radius: 8)

            VStack {
                Spacer()
                Text("Point at a Whistle QR code")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(.bottom, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Camera preview (UIViewRepresentable)

private struct CameraPreview: UIViewRepresentable {
    var onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = AVCaptureSession()
        context.coordinator.session = session

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return view
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer = previewLayer
        view.layer.addSublayer(previewLayer)

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }

    // MARK: Preview view

    final class PreviewView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer? {
            didSet { previewLayer?.frame = bounds }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }

    // MARK: Coordinator / delegate

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: (String) -> Void
        var session: AVCaptureSession?
        private var didFire = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !didFire,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            didFire = true
            session?.stopRunning()
            onScan(value)
        }
    }
}
