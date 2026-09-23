import SwiftUI
import AVFoundation

/// Owns the capture session and hands back JPEG data for each snap.
final class CameraController: NSObject, ObservableObject {
    enum CameraError: LocalizedError {
        case noDevice
        case denied

        var errorDescription: String? {
            switch self {
            case .noDevice: return "No camera found on this device."
            case .denied: return "Camera access denied. Enable it in Settings."
            }
        }
    }

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "seefood.camera.session")
    private var captureHandler: ((Data) -> Void)?
    @Published var isRunning = false

    func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty { self.configureSession() }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.isRunning = self.session.isRunning }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()
    }

    func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configureAndStart() : self?.reportDenied()
                }
            }
        default:
            reportDenied()
        }
    }

    private func reportDenied() {
        // Surface through the same pipeline as classify errors via NotificationCenter.
        NotificationCenter.default.post(name: .cameraError, object: CameraError.denied)
    }

    func capturePhoto(handler: @escaping (Data) -> Void) {
        captureHandler = handler
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension Notification.Name {
    static let cameraError = Notification.Name("seefood.cameraError")
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.captureHandler?(data)
            self?.captureHandler = nil
        }
    }
}

/// AVCaptureVideoPreviewLayer wrapped for SwiftUI.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
