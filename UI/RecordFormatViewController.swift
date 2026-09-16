import UIKit

final class RecordFormatViewController: UIViewController {
    private let model = CameraViewModel.shared; private let status = UILabel()
    private let ordered: [(String, UInt16)] = [("File format", 0xD241), ("Frame rate", 0xD286), ("Record setting / bitrate", 0xD242), ("Proxy recording", 0xD109), ("Proxy format", 0xD0D0), ("Proxy bitrate", 0xD0D1)]
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Record format"; view.backgroundColor = Theme.background
        status.numberOfLines = 0; status.textColor = Theme.secondary; status.text = "Stop recording before changing the recording format. Values are read from the camera; unavailable settings remain locked."
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        for (title, property) in ordered { let button = UIButton(type: .system); button.tag = Int(property); button.setTitle("  \(title)", for: .normal); button.tintColor = Theme.primary; button.contentHorizontalAlignment = .left; button.panelStyle(); button.heightAnchor.constraint(equalToConstant: 50).isActive = true; button.addTarget(self, action: #selector(edit(_:)), for: .touchUpInside); stack.addArrangedSubview(button) }
        stack.addArrangedSubview(status); view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)])
        model.onChange = { [weak self] in self?.refreshEnabled() }; refreshEnabled()
    }
    private func refreshEnabled() { for view in (view.subviews.first as? UIStackView)?.arrangedSubviews ?? [] where view is UIButton { let button = view as! UIButton; button.isEnabled = model.recordState != 1 && model.writable(UInt16(button.tag)); button.alpha = button.isEnabled ? 1 : 0.45 } }
    @objc private func edit(_ sender: UIButton) {
        guard model.recordState != 1 else { status.text = "Stop recording first."; return }
        let property = UInt16(sender.tag), values = model.values(for: property); guard !values.isEmpty else { status.text = "Camera does not provide an enum list for this property."; return }
        navigationController?.pushViewController(ValuePickerViewController(title: sender.title(for: .normal) ?? "Format", values: values, current: model.current(for: property)) { [weak self] value in
            guard let self else { return }; self.model.set(property, to: value) { message in self.status.text = message; if message == "Applied and verified" { self.model.refresh { _ in } } }
        }, animated: true)
    }
}
