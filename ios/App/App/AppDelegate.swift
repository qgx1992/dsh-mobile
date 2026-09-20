import UIKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    /// 只配置一次 WebView（避免每次回前台重复设置）
    private var didConfigureWebView = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 这里而不是 didFinishLaunching：CAPBridgeViewController 的 webView 在
        // viewDidLoad/capacitorDidLoad 中才创建，didBecomeActive 时已就绪。
        configureWebViewIfNeeded()
    }

    /// 开启 WKWebView 的边缘侧滑返回手势。
    ///
    /// 为什么需要：本 App 的流程是「本地连接页 → 导航到电脑上的 DSH 页面」。
    /// iOS 没有硬件返回键，若不开启该手势，用户一旦连上某个地址就**无法回到连接页**
    /// 去换地址（只能强杀 App）。开启后侧滑即可退回连接页（因为导航历史里仍有它）。
    ///
    /// 位置选择：webView 是 `public fileprivate(set)`，可在 AppDelegate 中读取；
    /// 这样无需新建 Swift 文件、也无需改动 project.pbxproj（降低构建风险）。
    private func configureWebViewIfNeeded() {
        guard !didConfigureWebView else { return }
        guard let rootVC = window?.rootViewController else { return }
        guard let bridgeVC = findBridgeViewController(from: rootVC) else { return }
        guard let webView = bridgeVC.webView else { return }

        webView.allowsBackForwardNavigationGestures = true
        didConfigureWebView = true
    }

    /// 递归查找 CAPBridgeViewController（可能被 UINavigationController/TabBar 包裹）
    private func findBridgeViewController(from controller: UIViewController) -> CAPBridgeViewController? {
        if let bridge = controller as? CAPBridgeViewController {
            return bridge
        }
        if let presented = controller.presentedViewController,
           let found = findBridgeViewController(from: presented) {
            return found
        }
        if let nav = controller as? UINavigationController,
           let found = findBridgeViewController(from: nav.visibleViewController ?? nav) {
            return found
        }
        if let tab = controller as? UITabBarController,
           let selected = tab.selectedViewController,
           let found = findBridgeViewController(from: selected) {
            return found
        }
        for child in controller.children {
            if let found = findBridgeViewController(from: child) {
                return found
            }
        }
        return nil
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}
