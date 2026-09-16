import UIKit

final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = Theme.background; tabBar.barStyle = .black; tabBar.tintColor = Theme.blue
        let control = UINavigationController(rootViewController: ControlViewController())
        let focus = UINavigationController(rootViewController: FocusViewController())
        let format = UINavigationController(rootViewController: RecordFormatViewController())
        control.tabBarItem = UITabBarItem(title: "CONTROL", image: UIImage(systemName: "dot.radiowaves.left.and.right"), tag: 0)
        focus.tabBarItem = UITabBarItem(title: "FOCUS", image: UIImage(systemName: "viewfinder"), tag: 1)
        format.tabBarItem = UITabBarItem(title: "FORMAT", image: UIImage(systemName: "film"), tag: 2)
        viewControllers = [control, focus, format]
    }
}
