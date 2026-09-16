import UIKit

final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        tabBar.barStyle = .black
        tabBar.tintColor = Theme.blue

        let live = UINavigationController(rootViewController: LiveViewViewController())
        let control = UINavigationController(rootViewController: ControlViewController())
        let focus = UINavigationController(rootViewController: FocusViewController())
        let format = UINavigationController(rootViewController: RecordFormatViewController())

        live.tabBarItem = UITabBarItem(
            title: "LIVE",
            image: UIImage(systemName: "video"),
            tag: 0
        )
        control.tabBarItem = UITabBarItem(
            title: "CONTROL",
            image: UIImage(systemName: "dot.radiowaves.left.and.right"),
            tag: 1
        )
        focus.tabBarItem = UITabBarItem(
            title: "FOCUS",
            image: UIImage(systemName: "viewfinder"),
            tag: 2
        )
        format.tabBarItem = UITabBarItem(
            title: "FORMAT",
            image: UIImage(systemName: "film"),
            tag: 3
        )

        viewControllers = [live, control, focus, format]
    }
}
