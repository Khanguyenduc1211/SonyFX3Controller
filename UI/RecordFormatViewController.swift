import UIKit

final class RecordFormatViewController: UIViewController {
    private let model = CameraViewModel.shared
    private let status = UILabel()
    private var stateObserver: NSObjectProtocol?
    private var buttons: [UInt16: UIButton] = [:]

    private let ordered: [(String, UInt16)] = [
        ("File format", 0xD241),
        ("Frame rate", 0xD286),
        ("Record setting / bitrate", 0xD242),
        ("Proxy recording", 0xD109),
        ("S&Q capture frame rate", 0xD0D0),
        ("S&Q record setting", 0xD0D1)
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Record format"
        view.backgroundColor = Theme.background

        status.numberOfLines = 0
        status.textColor = Theme.secondary
        status.text = "Stop recording before changing recording format. Values come from Sony 0x9209 capability data."

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (title, property) in ordered {
            let button = UIButton(type: .system)
            button.tag = Int(property)
            button.tintColor = Theme.primary
            button.contentHorizontalAlignment = .left
            button.panelStyle()
            button.heightAnchor.constraint(equalToConstant: 50).isActive = true
            button.addTarget(self, action: #selector(edit(_:)), for: .touchUpInside)
            buttons[property] = button
            stack.addArrangedSubview(button)
        }

        stack.addArrangedSubview(status)
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
            self?.refreshEnabled()
        }
        refreshEnabled()
    }

    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    private func title(for property: UInt16) -> String {
        ordered.first(where: { $0.1 == property })?.0 ?? String(format: "0x%04X", property)
    }

    private func refreshEnabled() {
        for (property, button) in buttons {
            let name = title(for: property)
            if let current = model.current(for: property) {
                button.setTitle("  \(name)   •   \(current)", for: .normal)
            } else {
                button.setTitle("  \(name)   •   —", for: .normal)
            }

            button.isEnabled =
                model.connected &&
                model.recordState == 0 &&
                model.writable(property) &&
                !model.values(for: property).isEmpty
            button.alpha = button.isEnabled ? 1 : 0.45
        }
    }

    @objc private func edit(_ sender: UIButton) {
        guard model.recordState == 0 else {
            status.text = "Stop recording first."
            return
        }

        let property = UInt16(sender.tag)
        let values = model.values(for: property)
        guard model.writable(property), !values.isEmpty else {
            status.text = "Camera does not provide a selectable value list/range for this property."
            return
        }

        navigationController?.pushViewController(
            ValuePickerViewController(
                title: title(for: property),
                values: values,
                current: model.current(for: property)
            ) { [weak self] value in
                guard let self else { return }
                self.model.set(property, to: value) { message in
                    self.status.text = message
                }
            },
            animated: true
        )
    }
}
