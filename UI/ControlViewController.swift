import UIKit

final class ControlViewController: UIViewController {
    private let model = CameraViewModel.shared
    private let record = UIButton(type: .system), timer = UILabel(), details = UILabel()
    private var timerTicker: Timer?
    override func viewDidLoad() {
        super.viewDidLoad(); title = "SONY FX3 / FX30"; view.backgroundColor = Theme.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(showConnection))
        record.setTitle("REC", for: .normal); record.titleLabel?.font = .systemFont(ofSize: 25, weight: .bold); record.tintColor = .white; record.backgroundColor = Theme.red; record.layer.cornerRadius = 16; record.heightAnchor.constraint(equalToConstant: 72).isActive = true; record.addTarget(self, action: #selector(toggleRecord), for: .touchUpInside)
        timer.textColor = Theme.primary; timer.textAlignment = .center; timer.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        details.numberOfLines = 0; details.textColor = Theme.secondary
        let stack = UIStackView(arrangedSubviews: [record, timer, makeRow("ISO", property: 0xD21E), makeRow("Base ISO", property: 0xD020), makeRow("Cine EI", property: 0xD022), makeRow("Shutter", property: 0xD20F), makeRow("Iris", property: 0xD210), makeRow("White balance", property: 0x5005), makeRow("Exposure mode", property: 0x500E), details]); stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)])
        model.onChange = { [weak self] in self?.render() }; timerTicker = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(render), userInfo: nil, repeats: true); render()
    }
    deinit { timerTicker?.invalidate() }
    private func makeRow(_ title: String, property: UInt16) -> UIButton { let button = UIButton(type: .system); button.tag = Int(property); button.contentHorizontalAlignment = .left; button.backgroundColor = Theme.panel; button.tintColor = Theme.primary; button.layer.cornerRadius = 12; button.heightAnchor.constraint(equalToConstant: 48).isActive = true; button.setTitle("  \(title)", for: .normal); button.addTarget(self, action: #selector(editProperty(_:)), for: .touchUpInside); return button }
    @objc private func showConnection() { present(UINavigationController(rootViewController: CameraConnectionViewController()), animated: true) }
    @objc private func toggleRecord() { model.record(model.recordState != 1) { [weak self] message in self?.details.text = message } }
    @objc private func editProperty(_ sender: UIButton) { let property = UInt16(sender.tag); let values = model.values(for: property); guard model.writable(property), !values.isEmpty else { details.text = "This setting is unavailable in the current camera mode."; return }; navigationController?.pushViewController(ValuePickerViewController(title: sender.title(for: .normal) ?? "Setting", values: values, current: model.current(for: property)) { [weak self] value in self?.model.set(property, to: value) { message in self?.details.text = message } }, animated: true) }
    @objc private func render() { let recording = model.recordState == 1; record.backgroundColor = recording ? Theme.red : Theme.green; record.setTitle(recording ? "STOP" : "REC", for: .normal); if recording, let started = model.recordingStartedAt { let seconds = Int(Date().timeIntervalSince(started)); timer.text = String(format: "REC %02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) } else if recording { timer.text = "REC --:--:--" } else { timer.text = model.connected ? "READY" : "NOT CONNECTED" } }
}
