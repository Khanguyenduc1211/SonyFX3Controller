import UIKit
import ImageIO

final class LiveViewViewController: UIViewController {
    private let model = CameraViewModel.shared

    private let imageView = UIImageView()
    private let recLabel = UILabel()
    private let fpsLabel = UILabel()
    private let statusLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let infoStack = UIStackView()

    private let decodeQueue = DispatchQueue(
        label: "sony.liveview.jpeg.decode",
        qos: .userInteractive
    )

    private var stateObserver: NSObjectProtocol?
    private var frameInFlight = false
    private var decodeInFlight = false
    private var liveRunning = false
    private var generation = 0

    private var displayedFrames = 0
    private var fpsWindowStart = Date()
    private var currentFPS: Double = 0
    private var lastRoundTripMilliseconds: Double = 0
    private var lastOffStateRefresh = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "LIVE VIEW"
        view.backgroundColor = .black

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.translatesAutoresizingMaskIntoConstraints = false

        recLabel.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
        recLabel.textColor = .white
        recLabel.translatesAutoresizingMaskIntoConstraints = false

        fpsLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        fpsLabel.textColor = .lightGray
        fpsLabel.textAlignment = .right
        fpsLabel.translatesAutoresizingMaskIntoConstraints = false

        let topBar = UIView()
        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(recLabel)
        topBar.addSubview(fpsLabel)

        NSLayoutConstraint.activate([
            recLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 14),
            recLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            fpsLabel.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            fpsLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 42)
        ])

        infoStack.axis = .horizontal
        infoStack.distribution = .fillEqually
        infoStack.spacing = 8
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        for (name, property) in [
            ("ISO", UInt16(0xD21E)),
            ("SHUTTER", UInt16(0xD20D)),
            ("IRIS", UInt16(0x5007)),
            ("WB", UInt16(0x5005))
        ] {
            infoStack.addArrangedSubview(makeInfoCell(name: name, property: property))
        }

        recordButton.setTitle("REC", for: .normal)
        recordButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        recordButton.tintColor = .white
        recordButton.backgroundColor = Theme.red
        recordButton.layer.cornerRadius = 12
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addTarget(self, action: #selector(toggleRecord), for: .touchUpInside)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .lightGray
        statusLabel.numberOfLines = 2
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let bottom = UIStackView(arrangedSubviews: [infoStack, recordButton, statusLabel])
        bottom.axis = .vertical
        bottom.spacing = 12
        bottom.translatesAutoresizingMaskIntoConstraints = false
        bottom.isLayoutMarginsRelativeArrangement = true
        bottom.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        bottom.backgroundColor = Theme.background

        view.addSubview(imageView)
        view.addSubview(topBar)
        view.addSubview(bottom)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottom.topAnchor),

            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            infoStack.heightAnchor.constraint(equalToConstant: 54),
            recordButton.heightAnchor.constraint(equalToConstant: 48)
        ])

        stateObserver = NotificationCenter.default.addObserver(
            forName: .cameraViewModelDidChange,
            object: model,
            queue: .main
        ) { [weak self] _ in
            self?.renderState()
            self?.kickLiveViewIfReady()
        }

        renderState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startLiveView()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopLiveView()
    }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
    }

    private func makeInfoCell(name: String, property: UInt16) -> UIView {
        let title = UILabel()
        title.text = name
        title.font = .systemFont(ofSize: 10, weight: .medium)
        title.textColor = Theme.secondary

        let value = UILabel()
        value.tag = Int(property)
        value.text = "—"
        value.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        value.textColor = Theme.primary
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.7

        let stack = UIStackView(arrangedSubviews: [title, value])
        stack.axis = .vertical
        stack.spacing = 3
        stack.alignment = .center
        stack.backgroundColor = Theme.panel
        stack.layer.cornerRadius = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 7, left: 4, bottom: 7, right: 4)
        return stack
    }

    private func startLiveView() {
        generation &+= 1
        liveRunning = true
        frameInFlight = false
        decodeInFlight = false
        displayedFrames = 0
        currentFPS = 0
        lastRoundTripMilliseconds = 0
        fpsWindowStart = Date()
        fpsLabel.text = "0.0 fps"
        model.setLiveViewActive(true)

        let token = generation
        configureHighestCameraQuality(generation: token)
    }

    private func stopLiveView() {
        generation &+= 1
        liveRunning = false
        frameInFlight = false
        model.setLiveViewActive(false)
    }

    private func configureHighestCameraQuality(generation token: Int) {
        guard liveRunning, token == generation else { return }

        // D26A is Sony's Live View image-quality property in the working FX3
        // implementation: 0x01 = Low, 0x02 = High. Keep the camera-reported
        // property authoritative; only request HIGH when the camera exposes it
        // as writable/enabled.
        if model.writable(0xD26A),
           model.current(for: 0xD26A) != 0x02 {
            statusLabel.text = "Requesting Sony Live View HIGH quality…"
            model.set(0xD26A, to: 0x02) { [weak self] message in
                guard let self, self.liveRunning, token == self.generation else { return }
                self.statusLabel.text = message
                self.kickLiveViewIfReady()
            }
        } else {
            kickLiveViewIfReady()
        }
    }

    private func kickLiveViewIfReady() {
        guard liveRunning, model.connected, !frameInFlight else { return }

        if model.current(for: 0xD221) == 1 {
            requestNextFrame(generation: generation)
            return
        }

        statusLabel.text = model.current(for: 0xD221) == nil
            ? "Waiting for Sony Live View status (D221)…"
            : "FX3 Live View status is OFF (D221 != 1)."

        // While no frame stream is running, refresh slowly so firmware that
        // omits the D221 event can still recover. Once frames start, normal
        // 0x9209 polling remains suspended to keep the command channel free.
        if Date().timeIntervalSince(lastOffStateRefresh) >= 1.0 {
            lastOffStateRefresh = Date()
            model.refresh { [weak self] _ in
                self?.kickLiveViewIfReady()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                self?.kickLiveViewIfReady()
            }
        }
    }

    private func requestNextFrame(generation token: Int) {
        guard liveRunning,
              token == generation,
              model.connected,
              !frameInFlight,
              model.current(for: 0xD221) == 1
        else { return }

        frameInFlight = true
        let requestStarted = CFAbsoluteTimeGetCurrent()

        model.requestLiveViewFrame { [weak self] data, message in
            guard let self else { return }
            self.frameInFlight = false

            guard self.liveRunning, token == self.generation else { return }

            self.lastRoundTripMilliseconds =
                (CFAbsoluteTimeGetCurrent() - requestStarted) * 1000.0

            if let data {
                self.decodeIfPossible(data, generation: token)
            } else {
                self.statusLabel.text = message
            }

            // No fixed timer/throttle. Yield one main-loop turn so REC/property
            // commands can enter the shared serial PTP queue, then immediately
            // request the next Sony frame. This gives natural back-pressure:
            // only one camera frame request exists at a time.
            DispatchQueue.main.async { [weak self] in
                self?.requestNextFrame(generation: token)
            }
        }
    }

    private func decodeIfPossible(_ data: Data, generation token: Int) {
        // Never queue old frames behind a slow decoder. Dropping a frame keeps
        // latency bounded; the newest frame is more valuable for monitoring.
        guard !decodeInFlight else { return }
        decodeInFlight = true

        decodeQueue.async { [weak self] in
            guard let self else { return }

            let options = [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary

            let source = CGImageSourceCreateWithData(data as CFData, options)
            let cgImage = source.flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, options)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.decodeInFlight = false

                guard self.liveRunning,
                      token == self.generation,
                      let cgImage
                else { return }

                self.imageView.image = UIImage(cgImage: cgImage)
                self.displayedFrames += 1

                let elapsed = Date().timeIntervalSince(self.fpsWindowStart)
                if elapsed >= 1.0 {
                    self.currentFPS = Double(self.displayedFrames) / elapsed
                    self.displayedFrames = 0
                    self.fpsWindowStart = Date()
                }

                let quality = self.model.current(for: 0xD26A) == 0x02 ? "HQ" : "LIVE"
                self.fpsLabel.text = String(
                    format: "%.1f fps • %.0f ms",
                    self.currentFPS,
                    self.lastRoundTripMilliseconds
                )
                self.statusLabel.text =
                    "\(quality) • \(cgImage.width)×\(cgImage.height)"
            }
        }
    }

    @objc private func toggleRecord() {
        guard model.connected, model.recordState == 0 || model.recordState == 1 else {
            statusLabel.text = "REC unavailable until D21D reports a valid state."
            return
        }

        recordButton.isEnabled = false
        model.record(model.recordState != 1) { [weak self] message in
            self?.recordButton.isEnabled = true
            self?.statusLabel.text = message
        }
    }

    private func renderState() {
        let recording = model.recordState == 1
        recLabel.text = recording ? "● REC" : "STBY"
        recLabel.textColor = recording ? Theme.red : .white

        recordButton.setTitle(recording ? "STOP" : "REC", for: .normal)
        recordButton.backgroundColor = recording ? Theme.red : Theme.panel
        recordButton.isEnabled =
            model.connected && (model.recordState == 0 || model.recordState == 1)
        recordButton.alpha = recordButton.isEnabled ? 1.0 : 0.45

        updateInfoLabels(in: infoStack)
    }

    private func updateInfoLabels(in view: UIView) {
        if let label = view as? UILabel, label.tag != 0 {
            let property = UInt16(label.tag)
            label.text = model.displayCurrent(for: property)
        }

        for child in view.subviews {
            updateInfoLabels(in: child)
        }
    }
}
