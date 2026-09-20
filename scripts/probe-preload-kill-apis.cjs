/**
 * 探针 preload：在页面自身脚本执行**之前**，抹掉三个「旧版 iOS Safari 缺失」的 API，
 * 用来精确模拟旧 iPhone 的环境。
 *
 * 三个 API 的兼容门槛都是 Safari 17.4（iOS 17.4），见上游 Discussion #3912：
 *   - AbortSignal.any      —— DSH 客户端连接层 postJson 直接调用，无特性检测
 *   - Promise.withResolvers —— 内联 boot 脚本
 *                              `(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()`
 *                              缺失即抛错 → 启动握手永不完成 → 整个 SPA 起不来（白屏）
 *   - crypto.randomUUID    —— 仅安全上下文可用；http://<IP> 必然没有
 *
 * 必须在 contextIsolation:false 下加载，才能作用到页面主世界（window）。
 */
try {
  AbortSignal.any = undefined
} catch (e) {}

try {
  Object.defineProperty(Promise, 'withResolvers', {
    value: undefined,
    configurable: true,
    writable: true
  })
} catch (e) {}

try {
  Object.defineProperty(window.crypto, 'randomUUID', {
    value: undefined,
    configurable: true,
    writable: true
  })
} catch (e) {}
