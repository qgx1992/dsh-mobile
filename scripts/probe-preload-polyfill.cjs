/**
 * 探针 preload：模拟「旧版 iOS Safari 能力缺失」+「我的 App 侧 polyfill 修复」。
 *
 * 顺序刻意如此：
 *   1) 先删掉原生 AbortSignal.any / crypto.randomUUID  → 等价于旧 iOS + 非安全上下文
 *   2) 再装上我们自己的 polyfill 实现                   → 等价于 App 注入 WKUserScript
 * 若页面随后能正常渲染，即证明「App 侧兜底 polyfill」可以独立修复白屏
 * （不依赖 dsh-pocket 的注入能否存活）。
 *
 * 注意：本文件的 polyfill 实现与 ios/App/App/AppDelegate.swift 中注入的
 * WKUserScript **逻辑一致**，改动需同步。
 */
try {
  AbortSignal.any = undefined
} catch (e) {}

try {
  Object.defineProperty(Promise, 'withResolvers', { value: undefined, configurable: true, writable: true })
} catch (e) {}

try {
  Object.defineProperty(window.crypto, 'randomUUID', { value: undefined, configurable: true, writable: true })
} catch (e) {}

/* ---------- 以下即待验证的 polyfill 实现（与 AppDelegate.swift 中注入的一致） ---------- */

/**
 * Promise.withResolvers（Safari 17.4+）。
 * 这是最关键的一个：内联 boot 脚本用它建 __DSH_BOOT_READY__，
 * 缺失会让整个 SPA 起不来（白屏），而不只是某个功能失效。
 */
try {
  if (typeof Promise.withResolvers !== 'function') {
    Object.defineProperty(Promise, 'withResolvers', {
      value: function () {
        var resolve, reject
        var promise = new Promise(function (res, rej) {
          resolve = res
          reject = rej
        })
        return { promise: promise, resolve: resolve, reject: reject }
      },
      configurable: true,
      writable: true
    })
  }
} catch (e) {}

try {
  if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.any !== 'function') {
    AbortSignal.any = function (signals) {
      var controller = new AbortController()
      var list = Array.prototype.slice.call(signals || [])
      var done = false
      var handlers = []
      function cleanup() {
        for (var i = 0; i < list.length; i++) {
          try {
            list[i].removeEventListener('abort', handlers[i])
          } catch (e) {}
        }
      }
      function abort(signal) {
        if (done) return
        done = true
        cleanup()
        try {
          controller.abort(signal && signal.reason)
        } catch (e) {
          controller.abort()
        }
      }
      for (var i = 0; i < list.length; i++) {
        var sig = list[i]
        if (sig && sig.aborted) {
          abort(sig)
          return controller.signal
        }
        var h = (function (s) {
          return function () {
            abort(s)
          }
        })(sig)
        handlers.push(h)
        try {
          sig.addEventListener('abort', h, { once: true })
        } catch (e) {}
      }
      return controller.signal
    }
  }
} catch (e) {}

try {
  if (self.crypto && typeof self.crypto.randomUUID !== 'function' && self.crypto.getRandomValues) {
    self.crypto.randomUUID = function () {
      var b = new Uint8Array(16)
      self.crypto.getRandomValues(b)
      b[6] = (b[6] & 15) | 64
      b[8] = (b[8] & 63) | 128
      var h = ''
      for (var i = 0; i < 16; i++) {
        var x = b[i].toString(16)
        h += x.length < 2 ? '0' + x : x
        if (i === 3 || i === 5 || i === 7 || i === 9) h += '-'
      }
      return h
    }
  }
} catch (e) {}
