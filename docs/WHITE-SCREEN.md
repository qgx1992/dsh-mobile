# 白屏排查记录（v0.1.1 → v0.1.2）

本文件记录 iOS 端「连上后白屏」问题的完整排查过程与两个独立根因。
后续遇到类似现象先读这里。

---

## 现象与两次结论

| 版本 | 现象 | 根因 | 结论 |
| :--- | :--- | :--- | :--- |
| v0.1.0 | 连接后白屏 | 缺 3 个 Web API（`Promise.withResolvers` 等） | 真白屏，已修 |
| v0.1.1 | 提示「页面没有渲染出来」，详情为 `blank sentinelOk=true` | **App 自己的诊断器误报** | 假白屏，已修 |

**关键区别**：真白屏会伴随 JS 异常；而 `sentinelOk=true` + **没有任何错误行**，
说明收集器工作正常、页面并未抛错 —— 这个组合本身就把矛头指向了诊断器。

---

## 根因一：缺三个 Web API（v0.1.1 修复）

DSH 内核自 0.1.2 起无特性检测地调用三个「Safari 17.4 / iOS 17.4 才普及」的 API，
而手机访问的是 `http://<局域网IP>:3081`（明文 HTTP + 非安全上下文）：

| API | 缺失后果 |
| :--- | :--- |
| `Promise.withResolvers` | **最致命**：内联 boot 脚本 `(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()` 抛错 → 启动握手永不完成 → 整个 SPA 起不来 |
| `AbortSignal.any` | 连接层 `postJson` 抛 `TypeError` → connection lost 循环 |
| `crypto.randomUUID` | 仅安全上下文可用，`http://<IP>` 必然没有 |

`dsh-pocket` 本会注入这些 polyfill，但它只在**未压缩**的 HTML 上注入
（`proxy.mjs` 的 `!isCompressed()`），而内核 `dsh-web-app` 默认 `compression: gzip`
（`cordis.patch.yml` 的 `compression: gzip` + 阈值 1024B）。真实浏览器**一定**发
`Accept-Encoding` → 注入被静默跳过。

**修法**：App 在 `documentStart` 用 `WKUserScript` 自行兜底，不依赖 pocket。

**实测对照**（Electron 加载同一地址，模拟旧 iOS 缺 API）：

```
无 polyfill → 仅降级页 36853B，抛 Promise.withResolvers is not a function
有 polyfill → 完整 DSH 界面 53599B，零错误
```

---

## 根因二：诊断器误报（v0.1.2 修复）

v0.1.1 加的白屏诊断有两个设计缺陷，**它自己制造了白屏观感**：

1. **计时起点错**：`asyncAfter(12s)` 从 `applicationDidBecomeActive` 起算，
   而用户此时还在连接页输 PIN。到点时若恰好抓到 SPA「已加载但 React 尚未渲染」
   的瞬间，就误判为空白。
2. **提示层覆盖整页**：判定为空白后插入 `position:fixed;inset:0` + 不透明底色的遮罩，
   把**本来正常的页面**整个盖住 —— 用户看到的就是白屏。

**修法**：

- 改为每 3 秒采样一次，**同一地址上连续 4 次为空**才认定（避开渲染时序抖动）；
- 提示层改为**只占底部 ≤46vh、可手动关闭**，页面一旦恢复正常自动移除；
- 提示内容增加 `readyState`、`#root` 长度、收集器自检状态，便于判断可信度。

**另一个真实缺陷**：首版错误收集器用 `addEventListener('error', fn)`（默认冒泡阶段），
而**资源加载失败不冒泡**（script 404 等），导致这类失败在诊断里完全不可见。
已改为 `capture: true` 并在回调里识别 `e.target` 是 SCRIPT/LINK/IMG 的资源错误。

---

## 排查方法（可复用）

探针脚本都在 `scripts/`，需要 `DSH_PIN`（`~/.dsh/dsh-pocket/token-lan`）：

```bash
# 1) 时序观察：逐秒记录 #root 填充过程，判断「真白屏」还是「采样时机误报」
DSH_PIN=<pin> electron scripts/probe-timeline.cjs

# 2) 对照实验：模拟旧 iOS 缺 API，验证 polyfill 是否有效
DSH_PIN=<pin> electron scripts/probe-page.cjs --kill-apis        # 无 polyfill → 复现
DSH_PIN=<pin> electron scripts/probe-page.cjs --swift-polyfill   # 用 App 真身 polyfill → 修复

# 3) 资源可用性：逐个请求页面引用的 script，找出 404
node scripts/check-assets.mjs <cookie.txt> <host>

# 4) 内嵌 JS 校验（本机无 Swift 编译器，用它兜底）
node scripts/verify-swift-embedded-js.mjs
```

### 踩过的坑

- **`check-assets.mjs` 一度输出假绿**：没抽到任何 script 时仍打印「所有脚本均可加载」。
  已加前置断言：抽到 0 个 script 直接报错退出（拿到登录页时就是这种情况）。
- **Cookie 解析丢认证**：Netscape 格式里 HttpOnly cookie 写作 `#HttpOnly_<domain>\t...`，
  以 `#` 开头但**不是注释**。用 `startsWith('#')` 跳过会把认证 cookie 全丢掉 →
  请求退回登录页。已特判该前缀。
- **校验正则窗口过紧**：用 `addEventListener('error'[\s\S]{0,400}?\}, true\)` 判断是否带
  capture，而实际监听器体长 660 字符 → **把正确代码误报为失败**。
  已改为括号配对（`isListenerWithCapture`），不依赖窗口宽度。
- **Electron 沙箱 preload 读不到 `node:fs`**：探针要读 Swift 源码抽 polyfill，
  必须 `sandbox: false`（仅探针，不进产物）。

---

## 教训（写进肌肉记忆）

1. **「无错误」不等于「没问题」**：必须先让收集器自证能捕到货（`sentinelOk` 哨兵），
   否则「没错误」可能只是收集器没工作。
2. **诊断工具自身会制造故障**：本次诊断层用全屏遮罩把正常页面盖住，
   把「误报」变成了「真白屏」。任何覆盖式 UI 都要可关闭、且不遮全屏。
3. **固定窗口/固定时机都是脆弱假设**：判定要基于「连续多次一致」而非单次采样；
   正则配对要基于结构（括号配对）而非字符距离。
4. **断言失败先确认是代码错还是断言错**：本次 `capture=true` 报失败，
   实测证明是校验正则太紧、代码是对的 —— 不查清就会去改对的代码。

---

## 上游参考

- [deepseek-harness Discussion #3912](https://github.com/deepseek-ai/deepseek-harness/discussions/3912)
  —— 同样结论：`AbortSignal.any` / `Promise.withResolvers` 在旧版移动浏览器上缺失，
  建议用 boot polyfill 兜底。
- [MDN: AbortSignal.any()](https://developer.mozilla.org/en-US/docs/Web/API/AbortSignal/any_static)
- [MDN: Promise.withResolvers()](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise/withResolvers)
