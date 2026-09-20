/**
 * 探针 preload：**直接使用 AppDelegate.swift 里内嵌的那段 polyfill**，不复制副本。
 *
 * 为什么不用副本：手抄的副本与真身可能不一致，那样「探针通过」就不能证明
 * 「App 里的代码有效」。这里从 Swift 源码抽取真实字符串并执行，
 * 保证验证对象就是发布产物里的那段代码。
 *
 * 同时先抹掉三个 API，模拟旧版 iOS Safari（Safari < 17.4）。
 *
 * 注意：本文件是 CommonJS（.cjs），不能用 import；Electron 的 preload 默认按 CJS 加载。
 */
const { readFileSync } = require('node:fs')
const path = require('node:path')

const SWIFT = path.join(__dirname, '..', 'ios', 'App', 'App', 'AppDelegate.swift')
const src = readFileSync(SWIFT, 'utf8')
const re = /#"""\r?\n([\s\S]*?)\r?\n\s*"""#/g
const blocks = []
let m
while ((m = re.exec(src)) !== null) blocks.push(m[1])

if (blocks.length < 1) {
  throw new Error('未能从 AppDelegate.swift 抽到 polyfill 字符串')
}

// 复现 App 的注入时机：与页面脚本同一主世界、同一 documentStart 语义
try {
  AbortSignal.any = undefined
} catch (e) {}
try {
  Object.defineProperty(Promise, 'withResolvers', { value: undefined, configurable: true, writable: true })
} catch (e) {}
try {
  Object.defineProperty(window.crypto, 'randomUUID', { value: undefined, configurable: true, writable: true })
} catch (e) {}

// 执行真身 polyfill（Swift 原始字符串内容即原样 JS）
// eslint-disable-next-line no-eval
;(0, eval)(blocks[0])

window.__polyfillFromSwift = true
