import UIKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    /// 只配置一次 WebView（避免每次回前台重复设置）
    private var didConfigureWebView = false

    // MARK: - 白屏监视状态

    private var blankWatchTimer: Timer?
    /// 上一次采样时的页面地址（换页要重置计数，否则会把「过渡页 → SPA」误判成持续空白）
    private var lastWatchHref = ""
    /// 连续采到「同一个地址上 #root 持续为空」的次数
    private var blankStreak = 0
    /// 是否已展示提示层（避免重复插入）
    private var hintShown = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // 进入非活跃状态时的处理（本项目无需额外动作）
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 进入后台时的处理（本项目无需额外动作）
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // 回到前台前的处理（本项目无需额外动作）
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // 这里而不是 didFinishLaunching：CAPBridgeViewController 的 webView 在
        // viewDidLoad/capacitorDidLoad 中才创建，didBecomeActive 时已就绪。
        configureWebViewIfNeeded()
    }

    // MARK: - WebView 配置

    /// 侧滑返回 + 能力兜底 + 白屏监视。
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
        controller.addUserScript(
            WKUserScript(
                source: Self.diagScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        // 3) 白屏监视
        startBlankWatch(webView)

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
    ///   2. `AbortSignal.any` —— 客户端连接层 postJson 直接调用。
    ///   3. `crypto.randomUUID` —— 仅安全上下文可用；`http://<IP>` 必然没有。
    ///
    /// dsh-pocket 本会注入这些 polyfill，但它的注入分支要求上游响应**未压缩**
    /// （proxy.mjs 的 `!isCompressed()`），而内核 dsh-web-app 默认 `compression: gzip`；
    /// 真实浏览器一定发 Accept-Encoding → 注入被静默跳过 → 手机拿不到 polyfill。
    ///
    /// 实测对照（Electron 加载同一地址 + 模拟旧 iOS 能力）：
    ///   无 polyfill → 仅降级页 36853B，抛 `Promise.withResolvers is not a function`
    ///   有 polyfill → 完整 DSH 界面 53599B，零错误
    ///
    /// 注意：实现需与 scripts/probe-preload-polyfill.cjs 保持一致（探针用它做的验证）。
    /// 使用 Swift 原始字符串 `#"""..."""#`，使 JS 里的反斜杠与引号无需转义。
    private func makePolyfillUserScript() -> WKUserScript {
        WKUserScript(
            source: Self.polyfillScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    // MARK: - 白屏监视

    /// 周期性检查当前页面是否「已加载但 #root 仍为空」，并给出**非遮挡**的可关闭提示。
    ///
    /// 设计教训（v0.1.1 → v0.1.2）：首版用固定 12 秒一次性采样 + 全屏遮罩，造成两个问题：
    ///   1. 计时从 App 激活起算，而用户此时可能还在连接页输 PIN；到点时若恰好抓到
    ///      SPA「已加载但 React 尚未渲染」的瞬间，就会误判；
    ///   2. 误判后插入的全屏遮罩会把**本来正常的页面**盖住，反而制造出白屏观感。
    /// 因此改为：连续多次采样 + 同一地址上持续为空才提示 + 提示层只占底部且可关闭 +
    /// 页面一旦恢复正常就自动移除提示。
    private func startBlankWatch(_ webView: WKWebView) {
        blankWatchTimer?.invalidate()
        // [weak self]：Timer 由 self 持有，若闭包再强引用 self 会形成循环引用，
        // 导致 AppDelegate 永不释放（且 Timer 停不下来）。
        blankWatchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self, weak webView] _ in
            guard let self = self, let webView = webView else { return }
            self.sampleOnce(webView)
        }
    }

    /// 采样一次：返回 "ok|href"、"noroot|href" 或 "blank|href|详情"。
    private func sampleOnce(_ webView: WKWebView) {
        webView.evaluateJavaScript(Self.probeScript) { result, error in
            guard error == nil, let raw = result as? String else { return }
            let parts = raw.components(separatedBy: "|")
            guard parts.count >= 2 else { return }
            let state = parts[0]
            let href = parts[1]
            let detail = parts.count >= 3 ? parts[2] : ""

            switch state {
            case "ok":
                // 页面正常：若之前误报过，把提示层撤掉（自愈）
                self.blankStreak = 0
                if self.hintShown {
                    webView.evaluateJavaScript("window.__dshExoHideBlank && window.__dshExoHideBlank();") { _, _ in }
                    self.hintShown = false
                }

            case "blank":
                if href == self.lastWatchHref {
                    self.blankStreak += 1
                } else {
                    self.blankStreak = 1
                    self.lastWatchHref = href
                }
                // 同一地址上连续 4 次（≈12 秒）为空才认定，避开渲染时序抖动
                if self.blankStreak >= 4 && !self.hintShown {
                    NSLog("[DSH] blank page confirmed: \(href)")
                    let safe = detail
                        .replacingOccurrences(of: "\\", with: "/")
                        .replacingOccurrences(of: "'", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                    let call = "window.__dshExoShowBlank && window.__dshExoShowBlank('\(safe)');"
                    webView.evaluateJavaScript(call) { _, _ in }
                    self.hintShown = true
                }

            default:
                // noroot / 其它：当前不是 DSH 页面（连接页、登录页、过渡页），重置计数
                self.blankStreak = 0
                self.lastWatchHref = href
            }
        }
    }

    // MARK: - 注入脚本（Swift 原始字符串，内容即原样 JS）

    /// 能力兜底：补齐三个旧版 iOS / 非安全上下文缺失的 API。
    private static let polyfillScript = #"""
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

    /// 错误收集器 + 提示层。
    ///
    /// 收集器要点：
    ///  - `capture: true`：资源加载失败（script 404 等）**不冒泡**，只有捕获阶段能收到，
    ///    首版漏了这个参数，导致这类失败在诊断里完全不可见（实测踩坑）。
    ///  - 自证哨兵：主动抛一个受控错误并确认收到，避免「收集器没工作」被误读成
    ///    「页面没有错误」（假绿）。
    private static let diagScript = #"""
    (function () {
      if (window.__dshExoDiag) return;
      window.__dshExoDiag = { errors: [], sentinelOk: false };

      window.addEventListener('error', function (e) {
        try {
          var t = e && e.target;
          if (t && t !== window && (t.tagName === 'SCRIPT' || t.tagName === 'LINK' || t.tagName === 'IMG')) {
            // 资源加载失败：e.message 为空，真实地址在 target 上
            window.__dshExoDiag.errors.push({
              kind: 'resource',
              msg: String(t.tagName) + ' failed: ' + String(t.src || t.href || '')
            });
            return;
          }
          window.__dshExoDiag.errors.push({
            kind: 'error',
            msg: String((e && (e.message || (e.error && e.error.message))) || 'unknown')
          });
        } catch (x) {}
      }, true);

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

      // 提示层：**只占底部、可关闭**，绝不覆盖整页
      window.__dshExoShowBlank = function (detail) {
        try {
          if (document.getElementById('__dshExoBlankHint')) return;
          var box = document.createElement('div');
          box.id = '__dshExoBlankHint';
          box.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:2147483647;'
            + 'max-height:46vh;overflow:auto;background:#171d27;color:#e3e6ea;'
            + 'border-top:1px solid #2b3442;padding:14px 16px;'
            + 'font:13px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;'
            + 'box-shadow:0 -6px 20px rgba(0,0,0,.45)';

          var head = document.createElement('div');
          head.style.cssText = 'display:flex;align-items:center;justify-content:space-between;margin-bottom:8px';
          var title = document.createElement('div');
          title.textContent = '页面似乎没有渲染出来';
          title.style.cssText = 'font-weight:600';
          var close = document.createElement('button');
          close.textContent = '关闭';
          close.style.cssText = 'background:transparent;border:1px solid #2b3442;color:#a8b0bd;'
            + 'border-radius:6px;padding:3px 10px;font-size:12px';
          close.onclick = function () { box.remove(); };
          head.appendChild(title);
          head.appendChild(close);

          var pre = document.createElement('pre');
          pre.textContent = String(detail || '（无错误信息）');
          pre.style.cssText = 'white-space:pre-wrap;word-break:break-all;margin:0;'
            + 'font:11.5px/1.6 ui-monospace,Menlo,monospace;color:#e3e6ea';

          var tip = document.createElement('div');
          tip.textContent = '若页面其实正常，可直接关闭本提示。也可先用 Chrome 打开同一地址对照。';
          tip.style.cssText = 'color:#7b8595;margin-top:8px;font-size:12px';

          box.appendChild(head);
          box.appendChild(pre);
          box.appendChild(tip);
          document.documentElement.appendChild(box);
        } catch (e) {}
      };

      window.__dshExoHideBlank = function () {
        try {
          var el = document.getElementById('__dshExoBlankHint');
          if (el) el.remove();
        } catch (e) {}
      };
    })();
    """#

    /// 采样脚本：返回 "状态|地址|详情"
    ///  - "ok"     #root 已有实质内容（>400 字符）
    ///  - "noroot" 当前页面没有 #root（连接页 / 登录页 / 过渡页）
    ///  - "blank"  有 #root 但为空或极少内容
    private static let probeScript = #"""
    (function () {
      try {
        var href = String(location.href || '');
        var root = document.getElementById('root');
        if (!root) { return 'noroot|' + href; }
        if (root.innerHTML.length > 400) { return 'ok|' + href; }
        var d = window.__dshExoDiag || { errors: [] };
        var list = (d.errors || []).slice(0, 6).map(function (it) {
          return (it.kind || 'error') + ': ' + (it.msg || '');
        });
        var lines = [
          '地址: ' + href,
          'readyState: ' + String(document.readyState),
          '#root 长度: ' + String(root.innerHTML.length),
          '收集器自检: ' + String(d.sentinelOk === true)
        ];
        if (list.length) {
          lines.push('捕获到的错误:');
          for (var i = 0; i < list.length; i++) lines.push('  ' + list[i]);
        } else {
          lines.push('捕获到的错误: 无');
        }
        if (d.sentinelOk !== true) {
          lines.push('（注意：收集器自检未通过，此处的「无错误」不可信）');
        }
        return 'blank|' + href + '|' + lines.join('\n');
      } catch (e) {
        return 'noroot|' + String(e && e.message);
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
        blankWatchTimer?.invalidate()
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}
