import UIKit

final class LiveViewViewController: UIViewController {
    private let model = CameraViewModel.shared

    private let imageView = UIImageView()
    private let recLabel = UILabel()
    private let fpsLabel = UILabel()
    private let statusLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let infoStack = UIStackView()

    private var frameTimer: Timer?
    private var stateObserver: NSObjectProtocol?
    private var frameInFlight = false
    private var frameCount = 0
    private var fpsWindowStart = Date()
    private var currentFPS: Double = 0

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
        frameTimer?.invalidate()
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
        frameTimer?.invalidate()
        frameInFlight = false
        frameCount = 0
        currentFPS = 0
        fpsWindowStart = Date()
        fpsLabel.text = "0.0 fps"

        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.requestFrame()
        }
        frameTimer?.tolerance = 0.02
        requestFrame()
    }

    private func stopLiveView() {
        frameTimer?.invalidate()
        frameTimer = nil
        frameInFlight = false
    }

    private func requestFrame() {
        guard model.connected, !frameInFlight else { return }

        guard model.current(for: 0xD221) == 1 else {
            statusLabel.text = model.current(for: 0xD221) == nil
                ? "Waiting for Sony Live View status (D221)…"
                : "FX3 Live View status is OFF (D221 != 1)."
            return
        }

        frameInFlight = true
        model.requestLiveViewFrame { [weak self] data, message in
            guard let self else { return }
            self.frameInFlight = false

            guard let data, let image = UIImage(data: data) else {
                self.statusLabel.text = message
                return
            }

            self.imageView.image = image
            self.statusLabel.text = "LIVE • \(Int(image.size.width))×\(Int(image.size.height))"
            self.frameCount += 1

            let elapsed = Date().timeIntervalSince(self.fpsWindowStart)
            if elapsed >= 1.0 {
                self.currentFPS = Double(self.frameCount) / elapsed
                self.frameCount = 0
                self.fpsWindowStart = Date()
                self.fpsLabel.text = String(format: "%.1f fps", self.currentFPS)
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
