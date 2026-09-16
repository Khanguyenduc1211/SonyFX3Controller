import UIKit

final class ValuePickerViewController: UIViewController, UIPickerViewDataSource, UIPickerViewDelegate {
    private let values: [Int64]; private let labels: (Int64) -> String; private let selected: (Int64) -> Void
    private let picker = UIPickerView()
    init(title: String, values: [Int64], current: Int64?, labels: @escaping (Int64) -> String = { "\($0)" }, selected: @escaping (Int64) -> Void) {
        self.values = values; self.labels = labels; self.selected = selected; super.init(nibName: nil, bundle: nil); self.title = title
        if let current, let index = values.firstIndex(of: current) { picker.selectRow(index, inComponent: 0, animated: false) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = Theme.background; picker.dataSource = self; picker.delegate = self; picker.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(picker); NSLayoutConstraint.activate([picker.leadingAnchor.constraint(equalTo: view.leadingAnchor), picker.trailingAnchor.constraint(equalTo: view.trailingAnchor), picker.centerYAnchor.constraint(equalTo: view.centerYAnchor)]) }
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 1 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { values.count }
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? { labels(values[row]) }
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) { selected(values[row]) }
}
