import UIKit
import ImageIO

final class LiveViewViewController: UIViewController {
    private struct Parameter {
        let title: String
        let property: UInt16
    }

    private let model = CameraViewModel.shared

    private let imageView = UIImageView()
    private let topBar = UIView()
    private let liveLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    private let timecodeLabel = UILabel()
    private let batteryLabel = UILabel()
    private let statusLabel = UILabel()

    private let parameterBar = UIView()
    private let primaryControlBar = UIStackView()
    private var primaryButtons: [UIButton] = []
    private let parameterCollection: UICollectionView
    private let recordButton = UIButton(type: .system)

    private let editorPanel = UIView()
    private let editorTitle = UILabel()
    private let editorClose = UIButton(type: .system)
    private let valueCollection: UICollectionView

    private let decodeQueue = DispatchQueue(
        label: "sony.liveview.jpeg.decode",
        qos: .userInteractive
    )

    private var stateObserver: NSObjectProtocol?
    private var timecodeTimer: Timer?

    private var frameInFlight = false
    private var decodeInFlight = false
    private var controlInFlight = false
    private var liveRunning = false
    private var generation = 0

    private var displayedFrames = 0
    private var fpsWindowStart = Date()
    private var currentFPS: Double = 0
    private var lastRoundTripMilliseconds: Double = 0
    private var liveResolution = "—"
    private var lastOffStateRefresh = Date.distantPast

    private var selectedParameter: Parameter?
    private var editorValues: [Int64] = []

    private var primaryParameters: [Parameter] {
        [
            model.cineEIActive()
                ? Parameter(title: "EI", property: 0xD022)
                : Parameter(title: "ISO", property: 0xD21E),
            Parameter(title: "SHUTTER", property: 0xD20D),
            Parameter(title: "IRIS", property: 0x5007),
            Parameter(title: "K", property: 0xD20F)
        ]
    }

    private var parameters: [Parameter] {
        [
            Parameter(title: "FPS", property: 0xD286),
            Parameter(title: "FOCUS", property: 0x500A),
            Parameter(title: "WB MODE", property: 0x5005),
            Parameter(title: "AREA", property: 0xD22C),
            Parameter(title: "LOG", property: 0xE000),
            Parameter(title: "FORMAT", property: 0xD241),
            Parameter(title: "REC SET", property: 0xD242)
        ]
    }

    init() {
        let parameterLayout = UICollectionViewFlowLayout()
        parameterLayout.scrollDirection = .horizontal
        parameterLayout.minimumLineSpacing = 0
        parameterLayout.minimumInteritemSpacing = 0
        parameterLayout.itemSize = CGSize(width: 92, height: 70)
        parameterCollection = UICollectionView(frame: .zero, collectionViewLayout: parameterLayout)

        let valueLayout = UICollectionViewFlowLayout()
        valueLayout.scrollDirection = .horizontal
        valueLayout.minimumLineSpacing = 8
        valueLayout.minimumInteritemSpacing = 8
        valueLayout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
        valueCollection = UICollectionView(frame: .zero, collectionViewLayout: valueLayout)

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        configurePreview()
        configureTopHUD()
        configureParameterBar()
        configureEditor()
        configureStatus()

        stateObserver = NotificationCenter.default.addObserver(
            forName: .cameraViewModelDidChange,
            object: model,
            queue: .main
        ) { [weak self] _ in
            self?.renderCameraState()
            self?.kickLiveViewIfReady()
        }

        timecodeTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(updateTimecode),
            userInfo: nil,
            repeats: true
        )

        renderCameraState()
        updateTimecode()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        startLiveView()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        stopLiveView()
    }

    deinit {
        timecodeTimer?.invalidate()
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
    }

    private func configurePreview() {
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureTopHUD() {
        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.66)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        liveLabel.text = "LIVE"
        liveLabel.font = .systemFont(ofSize: 12, weight: .bold)
        liveLabel.textColor = .white
        liveLabel.translatesAutoresizingMaskIntoConstraints = false

        diagnosticsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        diagnosticsLabel.numberOfLines = 2
        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false

        timecodeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        timecodeLabel.textColor = .white
        timecodeLabel.textAlignment = .center
        timecodeLabel.translatesAutoresizingMaskIntoConstraints = false

        batteryLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        batteryLabel.textColor = .white
        batteryLabel.textAlignment = .right
        batteryLabel.translatesAutoresizingMaskIntoConstraints = false

        topBar.addSubview(liveLabel)
        topBar.addSubview(diagnosticsLabel)
        topBar.addSubview(timecodeLabel)
        topBar.addSubview(batteryLabel)

        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),

            liveLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 14),
            liveLabel.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 7),

            diagnosticsLabel.leadingAnchor.constraint(equalTo: liveLabel.leadingAnchor),
            diagnosticsLabel.topAnchor.constraint(equalTo: liveLabel.bottomAnchor, constant: 2),

            timecodeLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            timecodeLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            batteryLabel.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -14),
            batteryLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ])
    }

    private func configureParameterBar() {
        parameterBar.backgroundColor = UIColor.black.withAlphaComponent(0.90)
        parameterBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(parameterBar)

        primaryControlBar.axis = .horizontal
        primaryControlBar.distribution = .fillEqually
        primaryControlBar.alignment = .fill
        primaryControlBar.spacing = 1
        primaryControlBar.translatesAutoresizingMaskIntoConstraints = false

        for index in 0..<4 {
            let button = UIButton(type: .system)
            button.tag = index
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
            button.tintColor = .white
            button.backgroundColor = UIColor.white.withAlphaComponent(0.05)
            button.layer.borderWidth = 0.5
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
            button.addTarget(self, action: #selector(primaryControlTapped(_:)), for: .touchUpInside)
            primaryButtons.append(button)
            primaryControlBar.addArrangedSubview(button)
        }

        parameterCollection.backgroundColor = .clear
        parameterCollection.showsHorizontalScrollIndicator = false
        parameterCollection.alwaysBounceHorizontal = true
        parameterCollection.dataSource = self
        parameterCollection.delegate = self
        parameterCollection.register(
            LiveParameterCell.self,
            forCellWithReuseIdentifier: LiveParameterCell.reuseIdentifier
        )
        parameterCollection.translatesAutoresizingMaskIntoConstraints = false

        recordButton.setTitle("●", for: .normal)
        recordButton.titleLabel?.font = .systemFont(ofSize: 28, weight: .bold)
        recordButton.tintColor = .red
        recordButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        recordButton.layer.borderWidth = 2
        recordButton.layer.borderColor = UIColor.white.withAlphaComponent(0.75).cgColor
        recordButton.layer.cornerRadius = 27
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.addTarget(self, action: #selector(toggleRecord), for: .touchUpInside)

        parameterBar.addSubview(primaryControlBar)
        parameterBar.addSubview(parameterCollection)
        parameterBar.addSubview(recordButton)

        NSLayoutConstraint.activate([
            parameterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            parameterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            parameterBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            parameterBar.heightAnchor.constraint(equalToConstant: 142),

            primaryControlBar.leadingAnchor.constraint(equalTo: parameterBar.leadingAnchor, constant: 8),
            primaryControlBar.trailingAnchor.constraint(equalTo: parameterBar.trailingAnchor, constant: -8),
            primaryControlBar.topAnchor.constraint(equalTo: parameterBar.topAnchor, constant: 7),
            primaryControlBar.heightAnchor.constraint(equalToConstant: 62),

            recordButton.trailingAnchor.constraint(equalTo: parameterBar.trailingAnchor, constant: -12),
            recordButton.bottomAnchor.constraint(equalTo: parameterBar.bottomAnchor, constant: -8),
            recordButton.widthAnchor.constraint(equalToConstant: 54),
            recordButton.heightAnchor.constraint(equalToConstant: 54),

            parameterCollection.leadingAnchor.constraint(equalTo: parameterBar.leadingAnchor, constant: 8),
            parameterCollection.trailingAnchor.constraint(equalTo: recordButton.leadingAnchor, constant: -10),
            parameterCollection.topAnchor.constraint(equalTo: primaryControlBar.bottomAnchor, constant: 5),
            parameterCollection.bottomAnchor.constraint(equalTo: parameterBar.bottomAnchor, constant: -6)
        ])
    }

    @objc private func primaryControlTapped(_ sender: UIButton) {
        let items = primaryParameters
        guard sender.tag >= 0, sender.tag < items.count else { return }
        openEditor(for: items[sender.tag])
        renderPrimaryControls()
    }

    private func renderPrimaryControls() {
        let items = primaryParameters
        for (index, button) in primaryButtons.enumerated() {
            guard index < items.count else {
                button.isHidden = true
                continue
            }

            button.isHidden = false
            let parameter = items[index]
            let available = model.current(for: parameter.property) != nil
            let values = model.values(for: parameter.property)
            let editable = available && model.writable(parameter.property) && !values.isEmpty
            let value = available ? model.displayCurrent(for: parameter.property) : "—"

            button.setTitle("\(parameter.title)\n\(value)", for: .normal)
            button.isEnabled = editable
            button.alpha = available ? (editable ? 1.0 : 0.62) : 0.32

            let selected = selectedParameter?.property == parameter.property
            button.backgroundColor = selected
                ? UIColor.white.withAlphaComponent(0.18)
                : UIColor.white.withAlphaComponent(0.05)
        }
    }

    private func configureEditor() {
        editorPanel.backgroundColor = UIColor.black.withAlphaComponent(0.92)
        editorPanel.layer.borderWidth = 1
        editorPanel.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        editorPanel.translatesAutoresizingMaskIntoConstraints = false
        editorPanel.isHidden = true
        view.addSubview(editorPanel)

        editorTitle.font = .systemFont(ofSize: 12, weight: .bold)
        editorTitle.textColor = .white
        editorTitle.translatesAutoresizingMaskIntoConstraints = false

        editorClose.setTitle("DONE", for: .normal)
        editorClose.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        editorClose.tintColor = .white
        editorClose.translatesAutoresizingMaskIntoConstraints = false
        editorClose.addTarget(self, action: #selector(closeEditor), for: .touchUpInside)

        valueCollection.backgroundColor = .clear
        valueCollection.showsHorizontalScrollIndicator = false
        valueCollection.dataSource = self
        valueCollection.delegate = self
        valueCollection.register(
            LiveValueCell.self,
            forCellWithReuseIdentifier: LiveValueCell.reuseIdentifier
        )
        valueCollection.translatesAutoresizingMaskIntoConstraints = false

        editorPanel.addSubview(editorTitle)
        editorPanel.addSubview(editorClose)
        editorPanel.addSubview(valueCollection)

        NSLayoutConstraint.activate([
            editorPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorPanel.bottomAnchor.constraint(equalTo: parameterBar.topAnchor),
            editorPanel.heightAnchor.constraint(equalToConstant: 92),

            editorTitle.leadingAnchor.constraint(equalTo: editorPanel.leadingAnchor, constant: 14),
            editorTitle.topAnchor.constraint(equalTo: editorPanel.topAnchor, constant: 8),

            editorClose.trailingAnchor.constraint(equalTo: editorPanel.trailingAnchor, constant: -14),
            editorClose.centerYAnchor.constraint(equalTo: editorTitle.centerYAnchor),

            valueCollection.leadingAnchor.constraint(equalTo: editorPanel.leadingAnchor, constant: 10),
            valueCollection.trailingAnchor.constraint(equalTo: editorPanel.trailingAnchor, constant: -10),
            valueCollection.topAnchor.constraint(equalTo: editorTitle.bottomAnchor, constant: 7),
            valueCollection.bottomAnchor.constraint(equalTo: editorPanel.bottomAnchor, constant: -8)
        ])
    }

    private func configureStatus() {
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        statusLabel.layer.cornerRadius = 5
        statusLabel.clipsToBounds = true
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: editorPanel.topAnchor, constant: -8),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            statusLabel.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func startLiveView() {
        generation &+= 1
        liveRunning = true
        frameInFlight = false
        decodeInFlight = false
        controlInFlight = false
        displayedFrames = 0
        currentFPS = 0
        lastRoundTripMilliseconds = 0
        liveResolution = "—"
        fpsWindowStart = Date()
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

        if model.writable(0xD26A),
           model.current(for: 0xD26A) != 0x02 {
            statusLabel.text = "LIVE VIEW HQ…"
            controlInFlight = true
            model.set(0xD26A, to: 0x02) { [weak self] message in
                guard let self, self.liveRunning, token == self.generation else { return }
                self.controlInFlight = false
                self.statusLabel.text = message
                self.kickLiveViewIfReady()
            }
        } else {
            kickLiveViewIfReady()
        }
    }

    private func kickLiveViewIfReady() {
        guard liveRunning,
              model.connected,
              !frameInFlight,
              !controlInFlight
        else { return }

        if model.current(for: 0xD221) == 1 {
            requestNextFrame(generation: generation)
            return
        }

        statusLabel.text = model.current(for: 0xD221) == nil
            ? "WAITING LIVE VIEW"
            : "LIVE VIEW OFF"

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
              !controlInFlight,
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

            DispatchQueue.main.async { [weak self] in
                self?.requestNextFrame(generation: token)
            }
        }
    }

    private func decodeIfPossible(_ data: Data, generation token: Int) {
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
                self.liveResolution = "\(cgImage.width)×\(cgImage.height)"
                self.displayedFrames += 1

                let elapsed = Date().timeIntervalSince(self.fpsWindowStart)
                if elapsed >= 1.0 {
                    self.currentFPS = Double(self.displayedFrames) / elapsed
                    self.displayedFrames = 0
                    self.fpsWindowStart = Date()
                    self.renderDiagnostics()
                }
            }
        }
    }

    private func renderCameraState() {
        renderPrimaryControls()
        parameterCollection.reloadData()
        renderDiagnostics()
        renderBattery()
        renderRecordButton()

        if selectedParameter != nil {
            reloadEditorKeepingSelection()
        }
    }

    private func renderDiagnostics() {
        let quality = model.current(for: 0xD26A) == 0x02 ? "HQ" : "LIVE"
        diagnosticsLabel.text = String(
            format: "%@  %.1f FPS\n%@  %.0f ms",
            quality,
            currentFPS,
            liveResolution,
            lastRoundTripMilliseconds
        )
    }

    private func renderBattery() {
        if let raw = model.current(for: 0xD20E) {
            batteryLabel.text = "BAT \(raw)%"
        } else {
            batteryLabel.text = "BAT —"
        }
    }

    private func renderRecordButton() {
        let recording = model.recordState == 1
        recordButton.setTitle(recording ? "■" : "●", for: .normal)
        recordButton.tintColor = recording ? .red : .red
        recordButton.isEnabled =
            model.connected &&
            !controlInFlight &&
            (model.recordState == 0 || model.recordState == 1)
        recordButton.alpha = recordButton.isEnabled ? 1.0 : 0.45
        liveLabel.text = recording ? "● REC" : "LIVE"
        liveLabel.textColor = recording ? .red : .white
    }

    @objc private func updateTimecode() {
        guard model.recordState == 1, let started = model.recordingStartedAt else {
            timecodeLabel.text = "00:00:00"
            return
        }

        let total = max(0, Int(Date().timeIntervalSince(started)))
        timecodeLabel.text = String(
            format: "%02d:%02d:%02d",
            total / 3600,
            (total / 60) % 60,
            total % 60
        )
    }

    @objc private func toggleRecord() {
        guard model.connected,
              !controlInFlight,
              model.recordState == 0 || model.recordState == 1
        else {
            statusLabel.text = "REC UNAVAILABLE"
            return
        }

        controlInFlight = true
        renderRecordButton()

        model.record(model.recordState != 1) { [weak self] message in
            guard let self else { return }
            self.controlInFlight = false
            self.statusLabel.text = message
            self.renderCameraState()
            self.kickLiveViewIfReady()
        }
    }

    private func openEditor(for parameter: Parameter) {
        let values = model.values(for: parameter.property)

        guard model.connected,
              model.current(for: parameter.property) != nil
        else {
            statusLabel.text = "\(parameter.title) UNAVAILABLE"
            return
        }

        guard model.writable(parameter.property), !values.isEmpty else {
            statusLabel.text = "\(parameter.title) READ ONLY"
            return
        }

        selectedParameter = parameter
        editorValues = values
        editorTitle.text =
            "\(parameter.title)   \(model.displayCurrent(for: parameter.property))"
        editorPanel.isHidden = false
        valueCollection.reloadData()

        DispatchQueue.main.async { [weak self] in
            self?.scrollEditorToCurrent(animated: false)
        }
    }

    private func reloadEditorKeepingSelection() {
        guard let parameter = selectedParameter else { return }

        let freshValues = model.values(for: parameter.property)
        if !freshValues.isEmpty {
            editorValues = freshValues
        }

        editorTitle.text =
            "\(parameter.title)   \(model.displayCurrent(for: parameter.property))"
        valueCollection.reloadData()
    }

    private func scrollEditorToCurrent(animated: Bool) {
        guard let parameter = selectedParameter,
              let current = model.current(for: parameter.property),
              let index = editorValues.firstIndex(of: current),
              index < valueCollection.numberOfItems(inSection: 0)
        else { return }

        valueCollection.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: .centeredHorizontally,
            animated: animated
        )
    }

    private func applyEditorValue(_ value: Int64) {
        guard let parameter = selectedParameter,
              !controlInFlight,
              model.writable(parameter.property)
        else { return }

        if model.current(for: parameter.property) == value {
            return
        }

        controlInFlight = true
        statusLabel.text =
            "\(parameter.title) → \(model.displayValue(for: parameter.property, value: value))"
        renderRecordButton()

        model.set(parameter.property, to: value) { [weak self] message in
            guard let self else { return }
            self.controlInFlight = false
            self.statusLabel.text = message
            self.renderCameraState()
            self.scrollEditorToCurrent(animated: true)
            self.kickLiveViewIfReady()
        }
    }

    @objc private func closeEditor() {
        selectedParameter = nil
        editorValues = []
        editorPanel.isHidden = true
        renderPrimaryControls()
        parameterCollection.reloadData()
    }
}

extension LiveViewViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        1
    }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        collectionView === parameterCollection
            ? parameters.count
            : editorValues.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if collectionView === parameterCollection {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: LiveParameterCell.reuseIdentifier,
                for: indexPath
            ) as! LiveParameterCell

            let parameter = parameters[indexPath.item]
            let available = model.current(for: parameter.property) != nil
            let editable =
                available &&
                model.writable(parameter.property) &&
                !model.values(for: parameter.property).isEmpty

            cell.configure(
                title: parameter.title,
                value: available
                    ? model.displayCurrent(for: parameter.property)
                    : "—",
                enabled: editable,
                selected: selectedParameter?.property == parameter.property
            )
            return cell
        }

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: LiveValueCell.reuseIdentifier,
            for: indexPath
        ) as! LiveValueCell

        guard let parameter = selectedParameter else { return cell }
        let value = editorValues[indexPath.item]
        cell.configure(
            text: model.displayValue(for: parameter.property, value: value),
            selected: model.current(for: parameter.property) == value
        )
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        if collectionView === parameterCollection {
            openEditor(for: parameters[indexPath.item])
            parameterCollection.reloadData()
        } else if indexPath.item < editorValues.count {
            applyEditorValue(editorValues[indexPath.item])
        }
    }
}

private final class LiveParameterCell: UICollectionViewCell {
    static let reuseIdentifier = "LiveParameterCell"

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.font = .systemFont(ofSize: 9, weight: .medium)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.65
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(titleLabel)
        contentView.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),

            valueLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            valueLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -7)
        ])

        contentView.layer.borderWidth = 0.5
        contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        value: String,
        enabled: Bool,
        selected: Bool
    ) {
        titleLabel.text = title
        valueLabel.text = value

        titleLabel.textColor = enabled
            ? UIColor.white.withAlphaComponent(0.62)
            : UIColor.white.withAlphaComponent(0.28)
        valueLabel.textColor = enabled
            ? .white
            : UIColor.white.withAlphaComponent(0.38)

        contentView.backgroundColor = selected
            ? UIColor.white.withAlphaComponent(0.12)
            : .clear
    }
}

private final class LiveValueCell: UICollectionViewCell {
    static let reuseIdentifier = "LiveValueCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])

        contentView.layer.cornerRadius = 7
        contentView.layer.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, selected: Bool) {
        label.text = text

        if selected {
            contentView.backgroundColor = .white
            contentView.layer.borderColor = UIColor.white.cgColor
            label.textColor = .black
        } else {
            contentView.backgroundColor = UIColor.white.withAlphaComponent(0.05)
            contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
            label.textColor = .white
        }
    }
}
