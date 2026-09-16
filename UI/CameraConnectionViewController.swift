import UIKit

final class CameraConnectionViewController: UIViewController {
    private let host = UITextField(), user = UITextField(), password = UITextField()
    private let connect = UIButton(type: .system)
    private let status = UILabel()
    private let model = CameraViewModel.shared

    override func viewDidLoad() {
        super.viewDidLoad(); title = "Camera connection"; view.backgroundColor = Theme.background
        [host, user, password].forEach { field in field.panelStyle(); field.textColor = Theme.primary; field.tintColor = Theme.blue; field.autocapitalizationType = .none; field.autocorrectionType = .no; field.heightAnchor.constraint(equalToConstant: 50).isActive = true }
        host.placeholder = "Camera IPv4"; user.placeholder = "SSH username"; password.placeholder = "Camera password"; password.isSecureTextEntry = true
        host.text = model.profile.host; user.text = model.profile.username; password.text = CameraProfileStore.password(for: model.profile)
        connect.setTitle("Connect securely", for: .normal); connect.tintColor = .white; connect.backgroundColor = Theme.blue; connect.layer.cornerRadius = 12; connect.addTarget(self, action: #selector(connectCamera), for: .touchUpInside); connect.heightAnchor.constraint(equalToConstant: 50).isActive = true
        status.numberOfLines = 0; status.textColor = Theme.secondary; status.font = .preferredFont(forTextStyle: .footnote); status.text = "The app verifies the Sony SSH SHA-256 fingerprint before it sends the password."
        let stack = UIStackView(arrangedSubviews: [host, user, password, connect, status]); stack.axis = .vertical; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30)])
    }
    @objc private func connectCamera() {
        guard let hostText = host.text, !hostText.isEmpty, let userText = user.text, !userText.isEmpty, let passwordText = password.text, !passwordText.isEmpty else { status.text = "Enter IPv4, SSH username, and camera password."; return }
        connect.isEnabled = false; status.text = "Opening SSH and verifying camera identity…"
        model.connect(host: hostText, username: userText, password: passwordText) { [weak self] message, fingerprint in
            guard let self else { return }; self.connect.isEnabled = true
            if let fingerprint {
                let alert = UIAlertController(title: "Trust camera fingerprint?", message: "SHA-256\n\(fingerprint)\n\nOnly trust this if it is the fingerprint shown by your own camera/network setup.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Trust and connect", style: .default) { _ in self.model.trustAndConnect(host: hostText, username: userText, password: passwordText, fingerprint: fingerprint) { result in self.status.text = result; if self.model.connected { self.dismiss(animated: true) } } })
                self.present(alert, animated: true)
            } else { self.status.text = message; if self.model.connected { self.dismiss(animated: true) } }
        }
    }
}
