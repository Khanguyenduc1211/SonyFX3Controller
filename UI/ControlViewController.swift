import UIKit

final class ControlViewController: UIViewController {
    private let model = CameraViewModel.shared
    private let record = UIButton(type: .system)
    private let timer = UILabel()
    private let details = UILabel()
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var timerTicker: Timer?
    private var stateObserver: NSObjectProtocol?
    private var propertyButtons: [UInt16: UIButton] = [:]
    private var propertyNames: [UInt16: String] = [:]

    private let controls: [(String, UInt16)] = [
        ("ISO", 0xD21E),
        ("Base ISO", 0xD020),
        ("Cine EI", 0xD022),
        ("Shutter", 0xD20D),
        ("Iris", 0x5007),
        ("White balance", 0x5005),
        ("Color temperature", 0xD20F),
        ("WB G/M", 0xD210),
        ("WB A/B", 0xD21C),
        ("Exposure mode", 0x500E)
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SONY FX3 / FX30"
        view.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(showConnection)
        )

        record.setTitle("REC", for: .normal)
        record.titleLabel?.font = .systemFont(ofSize: 25, weight: .bold)
        record.tintColor = .white
        record.backgroundColor = Theme.red
        record.layer.cornerRadius = 16
        record.heightAnchor.constraint(equalToConstant: 72).isActive = true
        record.addTarget(self, action: #selector(toggleRecord), for: .touchUpInside)

        timer.textColor = Theme.primary
        timer.textAlignment = .center
        timer.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)

        details.numberOfLines = 0
        details.textColor = Theme.secondary

        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(record)
        stack.addArrangedSubview(timer)
        for (name, property) in controls {
            stack.addArrangedSubview(makeRow(name, property: property))
        }
        stack.addArrangedSubview(details)

        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32)
        ])

        stateObserver = NotificationCenter.default.addObserver(
            forName: .cameraViewModelDidChange,
            object: model,
            queue: .main
        ) { [weak self] _ in
            self?.render()
        }

        timerTicker = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(render),
            userInfo: nil,
            repeats: true
        )
        render()
    }

    deinit {
        timerTicker?.invalidate()
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    private func makeRow(_ title: String, property: UInt16) -> UIButton {
        let button = UIButton(type: .system)
        button.tag = Int(property)
        button.contentHorizontalAlignment = .left
        button.backgroundColor = Theme.panel
        button.tintColor = Theme.primary
        button.layer.cornerRadius = 12
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        button.addTarget(self, action: #selector(editProperty(_:)), for: .touchUpInside)
        propertyButtons[property] = button
        propertyNames[property] = title
        return button
    }

    @objc private func showConnection() {
        present(UINavigationController(rootViewController: CameraConnectionViewController()), animated: true)
    }

    @objc private func toggleRecord() {
        guard model.connected, model.recordState == 0 || model.recordState == 1 else {
            details.text = "Recording control is unavailable until D21D reports a valid state."
            return
        }
        model.record(model.recordState != 1) { [weak self] message in
            self?.details.text = message
        }
    }

    @objc private func editProperty(_ sender: UIButton) {
        let property = UInt16(sender.tag)
        let values = model.values(for: property)
        guard model.writable(property), !values.isEmpty else {
            details.text = "This setting is unavailable in the current camera mode."
            return
        }

        navigationController?.pushViewController(
            ValuePickerViewController(
                title: propertyNames[property] ?? "Setting",
                values: values,
                current: model.current(for: property)
            ) { [weak self] value in
                self?.model.set(property, to: value) { message in
                    self?.details.text = message
                }
            },
            animated: true
        )
    }

    private func displayValue(_ property: UInt16, _ value: Int64) -> String {
        if property == 0xD020 {
            if value == 1 { return "HIGH" }
            if value == 2 { return "LOW" }
        }
        return String(value)
    }

    @objc private func render() {
        let recording = model.recordState == 1
        let recKnown = model.recordState == 0 || model.recordState == 1

        record.isEnabled = model.connected && recKnown
        record.alpha = record.isEnabled ? 1 : 0.45
        record.backgroundColor = recording ? Theme.red : (record.isEnabled ? Theme.green : Theme.panel)
        record.setTitle(
            model.recordState == 2 ? "REC UNAVAILABLE" : (recording ? "STOP" : "REC"),
            for: .normal
        )

        if recording, let started = model.recordingStartedAt {
            let seconds = Int(Date().timeIntervalSince(started))
            timer.text = String(
                format: "REC %02d:%02d:%02d",
                seconds / 3600,
                (seconds / 60) % 60,
                seconds % 60
            )
        } else if recording {
            timer.text = "REC --:--:--"
        } else {
            timer.text = model.connected ? "READY" : "NOT CONNECTED"
        }

        for (property, button) in propertyButtons {
            let name = propertyNames[property] ?? String(format: "0x%04X", property)
            if let current = model.current(for: property) {
                button.setTitle("  \(name)   •   \(displayValue(property, current))", for: .normal)
            } else {
                button.setTitle("  \(name)   •   —", for: .normal)
            }
            button.isEnabled = model.connected &&
                model.writable(property) &&
                !model.values(for: property).isEmpty
            button.alpha = button.isEnabled ? 1 : 0.45
        }
    }
}
