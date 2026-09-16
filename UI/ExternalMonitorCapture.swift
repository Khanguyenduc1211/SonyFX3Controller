import AVFoundation
import CoreMedia
import UIKit

final class ExternalMonitorCapture {
    struct ActiveSource {
        let deviceName: String
        let resolution: String
        let fps: Double
    }

    enum StartResult {
        case started(ActiveSource)
        case unavailable(String)
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "sony.monitorcontrol.uvc.session",
        qos: .userInitiated
    )

    private weak var hostView: UIView?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var activeDeviceID: String?
    private var observers: [NSObjectProtocol] = []

    var onDisconnected: (() -> Void)?
    var onConnected: (() -> Void)?

    init() {
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let device = note.object as? AVCaptureDevice,
                      self.isSupportedExternalDevice(device)
                else { return }

                self.onConnected?()
            }
        )

        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let device = note.object as? AVCaptureDevice,
                      device.uniqueID == self.activeDeviceID
                else { return }

                self.stop()
                self.onDisconnected?()
            }
        )
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to view: UIView) {
        hostView = view
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer.addSublayer(layer)
        previewLayer = layer
        updateLayout()
    }

    func updateLayout() {
        previewLayer?.frame = hostView?.bounds ?? .zero
    }

    func start(completion: @escaping (StartResult) -> Void) {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            completion(.unavailable("Sony Monitor & Control HD source requires iPad USB-C/UVC"))
            return
        }

        guard #available(iOS 17.0, *) else {
            completion(.unavailable("External UVC monitoring requires iPadOS 17 or later"))
            return
        }

        guard let device = discoverExternalDevice() else {
            completion(.unavailable("No external HDMI-to-UVC capture device detected"))
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure(device: device, completion: completion)

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard granted else {
                        completion(.unavailable("Camera permission denied for external UVC monitoring"))
                        return
                    }
                    self.configure(device: device, completion: completion)
                }
            }

        default:
            completion(.unavailable("Camera permission is disabled for external UVC monitoring"))
        }
    }

    func stop() {
        activeDeviceID = nil
        previewLayer?.isHidden = true

        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }

            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            session.commitConfiguration()
        }
    }

    @available(iOS 17.0, *)
    private func discoverExternalDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        ).devices.first
    }

    private func isSupportedExternalDevice(_ device: AVCaptureDevice) -> Bool {
        if #available(iOS 17.0, *) {
            return device.deviceType == .external && device.hasMediaType(.video)
        }
        return false
    }

    private func configure(
        device: AVCaptureDevice,
        completion: @escaping (StartResult) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                let input = try AVCaptureDeviceInput(device: device)

                self.session.beginConfiguration()
                defer { self.session.commitConfiguration() }

                for oldInput in self.session.inputs {
                    self.session.removeInput(oldInput)
                }

                if self.session.canSetSessionPreset(.hd1920x1080) {
                    self.session.sessionPreset = .hd1920x1080
                } else {
                    self.session.sessionPreset = .high
                }

                guard self.session.canAddInput(input) else {
                    DispatchQueue.main.async {
                        completion(.unavailable("External UVC device cannot be added to the capture session"))
                    }
                    return
                }

                self.session.addInput(input)

                let source = self.configureBest1080pFormat(device)

                self.activeDeviceID = device.uniqueID
                if !self.session.isRunning {
                    self.session.startRunning()
                }

                DispatchQueue.main.async {
                    self.previewLayer?.isHidden = false
                    self.updateLayout()
                    completion(.started(source))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.unavailable("Cannot open external UVC device: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func configureBest1080pFormat(_ device: AVCaptureDevice) -> ActiveSource {
        var selectedFormat: AVCaptureDevice.Format?
        var selectedFPS = 0.0

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == 1920, dimensions.height == 1080 else { continue }

            let maxFPS = format.videoSupportedFrameRateRanges
                .map(\.maxFrameRate)
                .max() ?? 0

            if maxFPS > selectedFPS {
                selectedFPS = maxFPS
                selectedFormat = format
            }
        }

        if let selectedFormat {
            do {
                try device.lockForConfiguration()
                device.activeFormat = selectedFormat

                if let fastest = selectedFormat.videoSupportedFrameRateRanges.max(
                    by: { $0.maxFrameRate < $1.maxFrameRate }
                ) {
                    device.activeVideoMinFrameDuration = fastest.minFrameDuration
                    device.activeVideoMaxFrameDuration = fastest.minFrameDuration
                    selectedFPS = fastest.maxFrameRate
                }

                device.unlockForConfiguration()
            } catch {
                // Keep the session-selected format when the UVC device does not
                // allow explicit format locking.
            }
        }

        let activeDimensions = CMVideoFormatDescriptionGetDimensions(
            device.activeFormat.formatDescription
        )

        let activeFPS: Double
        if device.activeVideoMinFrameDuration.isValid,
           device.activeVideoMinFrameDuration.seconds > 0 {
            activeFPS = 1.0 / device.activeVideoMinFrameDuration.seconds
        } else {
            activeFPS = selectedFPS
        }

        return ActiveSource(
            deviceName: device.localizedName,
            resolution: "\(activeDimensions.width)×\(activeDimensions.height)",
            fps: activeFPS
        )
    }
}
