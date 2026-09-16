import UIKit

final class FocusViewController: UIViewController {
    private let model = CameraViewModel.shared; private let status = UILabel(); private var lastY: CGFloat?
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Focus"; view.backgroundColor = Theme.background
        let focusMode = button("Focus mode", 0x500A), focusArea = button("Focus area", 0xD22C)
        let afHold = UIButton(type: .system); afHold.setTitle("Hold for AF", for: .normal); afHold.backgroundColor = Theme.blue; afHold.tintColor = .white; afHold.layer.cornerRadius = 12; afHold.heightAnchor.constraint(equalToConstant: 52).isActive = true; afHold.addTarget(self, action: #selector(afDown), for: .touchDown); afHold.addTarget(self, action: #selector(afUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let pull = UIView(); pull.panelStyle(); pull.translatesAutoresizingMaskIntoConstraints = false; let label = UILabel(); label.text = "Manual focus pull\nSwipe up = FAR • Swipe down = NEAR"; label.textAlignment = .center; label.numberOfLines = 2; label.textColor = Theme.primary; label.translatesAutoresizingMaskIntoConstraints = false; pull.addSubview(label); NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: pull.centerXAnchor), label.centerYAnchor.constraint(equalTo: pull.centerYAnchor), pull.heightAnchor.constraint(equalToConstant: 190)])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pullFocus(_:))); pull.addGestureRecognizer(pan)
        status.numberOfLines = 0; status.textColor = Theme.secondary
        let stack = UIStackView(arrangedSubviews: [focusMode, focusArea, afHold, pull, status]); stack.axis = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)])
    }
    private func button(_ title: String, _ property: UInt16) -> UIButton { let b = UIButton(type: .system); b.tag = Int(property); b.setTitle("  \(title)", for: .normal); b.contentHorizontalAlignment = .left; b.tintColor = Theme.primary; b.panelStyle(); b.heightAnchor.constraint(equalToConstant: 50).isActive = true; b.addTarget(self, action: #selector(edit(_:)), for: .touchUpInside); return b }
    @objc private func edit(_ sender: UIButton) { let property = UInt16(sender.tag), values = model.values(for: property); guard model.writable(property), !values.isEmpty else { status.text = "Camera has not exposed this control in the current mode."; return }; navigationController?.pushViewController(ValuePickerViewController(title: sender.title(for: .normal) ?? "Focus", values: values, current: model.current(for: property)) { [weak self] value in self?.model.set(property, to: value) { self?.status.text = $0 } }, animated: true) }
    @objc private func afDown() { model.control(0xD2C1, value: 2) { [weak self] in self?.status.text = $0 } }
    @objc private func afUp() { model.control(0xD2C1, value: 1) { [weak self] in self?.status.text = $0 } }
    @objc private func pullFocus(_ pan: UIPanGestureRecognizer) {
        let y = pan.location(in: pan.view).y
        if pan.state == .began { lastY = y; model.set(0xD235, to: 1) { [weak self] in self?.status.text = $0 }; return }
        guard let prior = lastY else { return }; let delta = y - prior; lastY = y
        guard abs(delta) > 8, pan.state == .changed else { if pan.state == .ended || pan.state == .cancelled { lastY = nil }; return }
        // Relative signed Int16 increment, not a synthetic percentage.  Upward is FAR.
        let step: Int64 = delta < 0 ? 3 : -3
        model.control(0xD2D1, value: step) { [weak self] in self?.status.text = $0 }
    }
}
