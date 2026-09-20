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

    // MARK: - WebView 配置

    /// 开启边缘侧滑返回手势 + 注入能力兜底 + 白屏自诊断。
    ///
    /// 位置选择：webView 是 `public fileprivate(set)`，可在 AppDelegate 中读取；
    /// 这样无需新建 Swift 文件、也无需改动 project.pbxproj（降低构建风险）。
    private func configureWebViewIfNeeded() {
        guard !didConfigureWebView else { return }
        guard let rootVC = window?.rootViewController else { return }
        guard let bridgeVC = findBridgeViewController(from: rootVC) else { return }
        guard let webView = bridgeVC.webView else { return }

        // 1) 侧滑返回。为什么需要：本 App 的流程是「本地连接页 → 导航到电脑上的 DSH
        //    页面」，而 iOS 没有硬件返回键；不开这个手势，用户一旦连上某个地址就
        //    无法回到连接页换地址（只能强杀 App）。
        webView.allowsBackForwardNavigationGestures = true

        // 2) 能力兜底（关键，见 makePolyfillUserScript 注释）
        let controller = webView.configuration.userContentController
        controller.addUserScript(makePolyfillUserScript())

        // 3) 白屏自诊断
        installBlankScreenWatch(webView)

        didConfigureWebView = true
    }

    /// 在页面脚本执行前注入缺失的 Web API（WKUserScript, .atDocumentStart）。
    ///
    /// 为什么 App 侧必须兜这一层（**实测根因**，非推测）：
    ///
    /// 手机访问的是 dsh-pocket 代理，地址形如 `http://<局域网IP>:3081` —— 明文 HTTP，
    /// 且 DSH 内核自 0.1.2 起开始无特性检测地调用三个「Safari 17.4 (iOS 17.4) 才普及」
    /// 的 API（上游 Discussion #3912 有同样结论）：
    ///
    ///   1. `Promise.withResolvers` —— **最关键的一个**。DSH 的内联 boot 脚本写着
    ///      `(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()`。
    ///      该 API 缺失即抛错 → 启动握手永不完成 → 整个 SPA 起不来（表现为白屏），
    ///      而不只是某个功能失效。
    ///   2. `AbortSignal.any` —— 客户端连接层 postJson 直接调用；缺失时首个携带
    ///      caller signal 的 RPC 抛 `TypeError: AbortSignal.any is not a function`。
    ///   3. `crypto.randomUUID` —— 仅安全上下文可用；`http://<IP>` 必然没有。
    ///
    /// dsh-pocket 本会注入这些 polyfill，但它的注入分支要求上游响应**未压缩**
    /// （proxy.mjs 的 `!isCompressed()`），而内核 dsh-web-app 默认 `compression: gzip`；
    /// 真实浏览器一定发 Accept-Encoding → 注入被静默跳过 → 手机拿不到 polyfill。
    /// 所以这里不能依赖它，由 App 自己兜底。
    ///
    /// 实测对照（Electron 加载同一地址 + 模拟旧 iOS 能力）：
    ///   无 polyfill → 只渲染出降级页（36853B，"选择工作区"）+ 抛
    ///                 `Promise.withResolvers is not a function`
    ///   有 polyfill → 完整渲染 DSH 界面（53599B，350 字正文），零错误
    ///
    /// 注意：实现需与 scripts/probe-preload-polyfill.cjs 保持一致（探针用它做的验证）。
    /// 使用 Swift 原始字符串 `#"""..."""#`，使 JS 里的反斜杠与引号无需转义。
    private func makePolyfillUserScript() -> WKUserScript {
        let source = #"""
        (function () {
          // 1) Promise.withResolvers：DSH 内联 boot 脚本依赖，缺失即整体白屏
          try {
            if (typeof Promise.withResolvers !== 'function') {
              Object.defineProperty(Promise, 'withResolvers', {
                value: function () {
                  var resolve, reject;
                  var promise = new Promise(function (res, rej) { resolve = res; reject = rej; });
                  return { promise: promise, resolve: resolve, reject: reject };
                },
                configurable: true,
                writable: true
              });
            }
          } catch (e) {}

          // 2) AbortSignal.any：客户端连接层 postJson 直接调用
          try {
            if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.any !== 'function') {
              AbortSignal.any = function (signals) {
                var controller = new AbortController();
                var list = Array.prototype.slice.call(signals || []);
                var done = false;
                var handlers = [];
                function cleanup() {
                  for (var i = 0; i < list.length; i++) {
                    try { list[i].removeEventListener('abort', handlers[i]); } catch (e) {}
                  }
                }
                function abort(signal) {
                  if (done) return;
                  done = true;
                  cleanup();
                  try { controller.abort(signal && signal.reason); } catch (e) { controller.abort(); }
                }
                for (var i = 0; i < list.length; i++) {
                  var sig = list[i];
                  if (sig && sig.aborted) { abort(sig); return controller.signal; }
                  var h = (function (s) { return function () { abort(s); }; })(sig);
                  handlers.push(h);
                  try { sig.addEventListener('abort', h, { once: true }); } catch (e) {}
                }
                return controller.signal;
              };
            }
          } catch (e) {}

          // 3) crypto.randomUUID：仅安全上下文可用
          try {
            if (self.crypto && typeof self.crypto.randomUUID !== 'function' && self.crypto.getRandomValues) {
              self.crypto.randomUUID = function () {
                var b = new Uint8Array(16);
                self.crypto.getRandomValues(b);
                b[6] = (b[6] & 15) | 64;
                b[8] = (b[8] & 63) | 128;
                var h = '';
                for (var i = 0; i < 16; i++) {
                  var x = b[i].toString(16);
                  h += x.length < 2 ? '0' + x : x;
                  if (i === 3 || i === 5 || i === 7 || i === 9) h += '-';
                }
                return h;
              };
            }
          } catch (e) {}
        })();
        """#
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - 白屏自诊断

    /// 页面若在若干秒后仍未渲染出内容，就把页面里捕获到的 JS 错误显示成可读提示。
    ///
    /// 为什么需要：真机白屏无法在开发机上复现（Chromium 与 iOS WKWebView 的 API
    /// 可用性不同），所以让 App 自己把「为什么白」说出来，而不是留一片空白。
    private func installBlankScreenWatch(_ webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.addUserScript(
            WKUserScript(
                source: Self.errorCollectorScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        // 12 秒后检查 #root 是否为空；空 = 白屏 → 展示诊断信息
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak webView] in
            guard let webView = webView else { return }
            webView.evaluateJavaScript(Self.blankProbeScript) { result, error in
                guard error == nil, let report = result as? String else {
                    NSLog("[DSH] blank probe failed: \(String(describing: error))")
                    return
                }
                NSLog("[DSH] blank probe: \(report)")
                guard report.hasPrefix("blank") else { return }

                // 转成单行、去掉可能破坏 JS 字符串的字符
                let safe = report
                    .replacingOccurrences(of: "\\", with: "/")
                    .replacingOccurrences(of: "'", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")

                let call = "window.__dshExoShowBlank && window.__dshExoShowBlank('\(safe)');"
                webView.evaluateJavaScript(call) { _, _ in }
            }
        }
    }

    /// 错误收集器 + 白屏提示层实现（在 documentStart 注入）。
    ///
    /// 含「自证哨兵」：先主动抛一个受控错误并确认收集器收到了它，避免
    /// 「收集器没工作」被误读成「页面没有错误」（假绿）。
    private static let errorCollectorScript = #"""
    (function () {
      if (window.__dshExoDiag) return;
      window.__dshExoDiag = { errors: [], sentinelOk: false };

      window.addEventListener('error', function (e) {
        try {
          window.__dshExoDiag.errors.push({
            kind: 'error',
            msg: String((e && (e.message || (e.error && e.error.message))) || 'unknown')
          });
        } catch (x) {}
      });

      window.addEventListener('unhandledrejection', function (e) {
        try {
          var r = e && e.reason;
          window.__dshExoDiag.errors.push({
            kind: 'rejection',
            msg: String((r && (r.message || r)) || 'unknown')
          });
        } catch (x) {}
      });

      // 自证：收集器必须能收到这个受控错误，否则 sentinelOk 保持 false
      try {
        setTimeout(function () {
          try {
            window.dispatchEvent(new ErrorEvent('error', { message: '__dshExoDiagSentinel__' }));
          } catch (x) {}
          window.__dshExoDiag.sentinelOk = window.__dshExoDiag.errors.some(function (it) {
            return it.msg === '__dshExoDiagSentinel__';
          });
          window.__dshExoDiag.errors = window.__dshExoDiag.errors.filter(function (it) {
            return it.msg !== '__dshExoDiagSentinel__';
          });
        }, 0);
      } catch (x) {}

      // 白屏提示层（由原生侧在探测到 #root 为空时调用）
      window.__dshExoShowBlank = function (detail) {
        try {
          if (document.getElementById('__dshExoBlankHint')) return;
          var box = document.createElement('div');
          box.id = '__dshExoBlankHint';
          box.style.cssText = 'position:fixed;inset:0;z-index:2147483647;overflow:auto;'
            + 'background:#0f141c;color:#e3e6ea;padding:22px;'
            + 'font:14px/1.7 -apple-system,BlinkMacSystemFont,sans-serif';

          var title = document.createElement('div');
          title.textContent = '页面没有渲染出来';
          title.style.cssText = 'font-size:17px;font-weight:600;margin-bottom:10px';

          var lead = document.createElement('div');
          lead.textContent = 'DSH 页面已加载，但前端启动失败。下面的信息可帮助定位：';
          lead.style.cssText = 'color:#a8b0bd;margin-bottom:14px';

          var pre = document.createElement('pre');
          pre.textContent = String(detail || '');
          pre.style.cssText = 'white-space:pre-wrap;word-break:break-all;background:#171d27;'
            + 'border:1px solid #2b3442;border-radius:8px;padding:12px;margin:0;'
            + 'font:12px/1.6 ui-monospace,Menlo,monospace;color:#e3e6ea';

          var tip = document.createElement('div');
          tip.textContent = '可截图反馈。也可先用 Chrome 打开同一地址对照，或把桌面端切回 compatibility 模式后重启。';
          tip.style.cssText = 'color:#7b8595;margin-top:14px;font-size:13px';

          box.appendChild(title);
          box.appendChild(lead);
          box.appendChild(pre);
          box.appendChild(tip);
          document.documentElement.appendChild(box);
        } catch (e) {}
      };
    })();
    """#

    /// 探测脚本：返回 'ok' / 'no-root' / 'blank...' / 'probe-failed...'
    private static let blankProbeScript = #"""
    (function () {
      try {
        var root = document.getElementById('root');
        if (!root) { return 'no-root'; }
        if (root.innerHTML.length > 400) { return 'ok'; }
        var d = window.__dshExoDiag || { errors: [] };
        var list = (d.errors || []).slice(0, 5).map(function (it) {
          return (it.kind || 'error') + ': ' + (it.msg || '');
        });
        return 'blank\nsentinelOk=' + String(d.sentinelOk === true) + '\n' + list.join('\n');
      } catch (e) {
        return 'probe-failed: ' + String(e && e.message);
      }
    })();
    """#

    // MARK: - 视图查找

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
