import UIKit

enum Theme {
    static let background = UIColor(red: 7/255, green: 9/255, blue: 12/255, alpha: 1)
    static let panel = UIColor(red: 21/255, green: 24/255, blue: 29/255, alpha: 1)
    static let field = UIColor(red: 32/255, green: 36/255, blue: 42/255, alpha: 1)
    static let primary = UIColor(red: 245/255, green: 247/255, blue: 250/255, alpha: 1)
    static let secondary = UIColor(red: 146/255, green: 153/255, blue: 163/255, alpha: 1)
    static let blue = UIColor(red: 35/255, green: 120/255, blue: 1, alpha: 1)
    static let green = UIColor(red: 48/255, green: 209/255, blue: 88/255, alpha: 1)
    static let orange = UIColor(red: 1, green: 159/255, blue: 10/255, alpha: 1)
    static let red = UIColor(red: 1, green: 69/255, blue: 58/255, alpha: 1)
}

extension UIView {
    func panelStyle() { backgroundColor = Theme.panel; layer.cornerRadius = 14 }
}
