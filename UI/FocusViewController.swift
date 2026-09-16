import UIKit

final class FocusViewController: UIViewController {
    private let model = CameraViewModel.shared
    private let status = UILabel()
    private let afHold = UIButton(type: .system)
    private var lastY: CGFloat?
    private var stateObserver: NSObjectProtocol?
    private var propertyButtons: [UInt16: UIButton] = [:]
    private let propertyNames: [UInt16: String] = [
        0x500A: "Focus mode",
        0xD22C: "Focus area",
        0xE042: "MF position"
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Focus"
        view.backgroundColor = Theme.background

        let focusMode = button("Focus mode", 0x500A)
        let focusArea = button("Focus area", 0xD22C)
        let focusPosition = button("MF position", 0xE042)

        afHold.setTitle("Hold for AF", for: .normal)
        afHold.backgroundColor = Theme.blue
        afHold.tintColor = .white
        afHold.layer.cornerRadius = 12
        afHold.heightAnchor.constraint(equalToConstant: 52).isActive = true
        afHold.addTarget(self, action: #selector(afDown), for: .touchDown)
        afHold.addTarget(self, action: #selector(afUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let pull = UIView()
        pull.panelStyle()
        pull.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "Manual focus pull\nSwipe up = FAR • Swipe down = NEAR"
        label.textAlignment = .center
        label.numberOfLines = 2
        label.textColor = Theme.primary
        label.translatesAutoresizingMaskIntoConstraints = false
        pull.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: pull.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pull.centerYAnchor),
            pull.heightAnchor.constraint(equalToConstant: 190)
        ])

        pull.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pullFocus(_:))))

        status.numberOfLines = 0
        status.textColor = Theme.secondary

        let stack = UIStackView(arrangedSubviews: [
            focusMode, focusArea, focusPosition, afHold, pull, status
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)
        ])

        stateObserver = NotificationCenter.default.addObserver(
            forName: .cameraViewModelDidChange,
            object: model,
            queue: .main
        ) { [weak self] _ in
            self?.render()
        }
        render()
    }

    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    private func button(_ title: String, _ property: UInt16) -> UIButton {
        let button = UIButton(type: .system)
        button.tag = Int(property)
        button.contentHorizontalAlignment = .left
        button.tintColor = Theme.primary
        button.panelStyle()
        button.heightAnchor.constraint(equalToConstant: 50).isActive = true
        button.addTarget(self, action: #selector(edit(_:)), for: .touchUpInside)
        propertyButtons[property] = button
        return button
    }

    @objc private func edit(_ sender: UIButton) {
        let property = UInt16(sender.tag)
        let values = model.values(for: property)
        guard model.writable(property), !values.isEmpty else {
            status.text = "Camera has not exposed this control in the current mode."
            return
        }

        let readback = property == 0xE042 ? UInt16(0xE043) : property
        navigationController?.pushViewController(
            ValuePickerViewController(
                title: propertyNames[property] ?? "Focus",
                values: values,
                current: model.current(for: readback),
                labels: { [model] value in
                    model.displayValue(for: property, value: value)
                }
            ) { [weak self] value in
                self?.model.set(property, to: value) {
                    self?.status.text = $0
                }
            },
            animated: true
        )
    }

    @objc private func afDown() {
        guard model.connected else { return }
        model.control(0xD2C1, value: 2) { [weak self] in
            self?.status.text = $0
        }
    }

    @objc private func afUp() {
        guard model.connected else { return }
        model.control(0xD2C1, value: 1) { [weak self] message in
            self?.status.text = message
            self?.model.refresh { _ in }
        }
    }

    @objc private func pullFocus(_ pan: UIPanGestureRecognizer) {
        let y = pan.location(in: pan.view).y

        if pan.state == .began {
            guard model.current(for: 0xD235) == 1 else {
                lastY = nil
                status.text = "MF Near/Far is disabled by the current lens/camera state."
                return
            }
            lastY = y
            return
        }

        if pan.state == .ended || pan.state == .cancelled || pan.state == .failed {
            lastY = nil
            model.refresh { [weak self] message in self?.status.text = message }
            return
        }

        guard let prior = lastY, pan.state == .changed else { return }
        let delta = y - prior
        guard abs(delta) > 8 else { return }
        lastY = y

        let step: Int64 = delta < 0 ? 3 : -3
        model.control(0xD2D1, value: step) { [weak self] in
            self?.status.text = $0
        }
    }

    private func render() {
        afHold.isEnabled = model.connected
        afHold.alpha = afHold.isEnabled ? 1 : 0.45

        for (property, button) in propertyButtons {
            let readback = property == 0xE042 ? UInt16(0xE043) : property
            let name = propertyNames[property] ?? String(format: "0x%04X", property)

            if let value = model.current(for: readback) {
                button.setTitle("  \(name)   •   \(model.displayValue(for: readback, value: value))", for: .normal)
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
