/**
 * 校验 AppDelegate.swift 里内嵌的三段 JS 是否语法有效。
 *
 * 为什么要这一步：本机是 Windows，没有 Swift 编译器，无法 `swiftc` 校验；
 * 而内嵌 JS 若语法错，Swift 侧编译会通过、运行期才在真机上静默失败
 * （表现为 polyfill 不生效 → 白屏依旧）。这里把 JS 抽出来交给 Node 做语法检查，
 * 把「运行期才发现」提前到「提交前发现」。
 *
 * 用法：node scripts/verify-swift-embedded-js.mjs
 */
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import vm from 'node:vm'

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')
const SWIFT = path.join(ROOT, 'ios', 'App', 'App', 'AppDelegate.swift')
const src = readFileSync(SWIFT, 'utf8')

/**
 * 抽取 Swift 原始字符串字面量 `#""" ... """#` 的内容。
 * 原始字符串里反斜杠无需转义，因此内容即原样 JS。
 */
function extractRawStrings(text) {
  const out = []
  const re = /#"""\r?\n([\s\S]*?)\r?\n\s*"""#/g
  let m
  while ((m = re.exec(text)) !== null) out.push(m[1])
  return out
}

const blocks = extractRawStrings(src)
console.log(`在 AppDelegate.swift 中抽到 ${blocks.length} 段 Swift 原始字符串（应为 3 段）`)

if (blocks.length !== 3) {
  console.error('❌ 抽取段数与预期不符——请检查 #""" ... """# 的写法')
  process.exit(1)
}

const names = ['polyfill（能力兜底）', 'errorCollector（错误收集器）', 'blankProbe（白屏探测）']
let failed = 0

blocks.forEach((code, i) => {
  const label = names[i] || `block#${i + 1}`
  try {
    // 只做语法解析，不执行（避免真的去改 Node 的全局对象）
    new vm.Script(code, { filename: `${label}.js` })
    console.log(`  ✅ ${label}: JS 语法有效（${code.length} 字符）`)
  } catch (e) {
    failed++
    console.error(`  ❌ ${label}: JS 语法错误 → ${e.message}`)
  }
})

// 关键断言：polyfill 必须覆盖全部三个 API，漏一个就仍会白屏
const polyfill = blocks[0]
const required = [
  ['Promise.withResolvers', /withResolvers/],
  ['AbortSignal.any', /AbortSignal\.any/],
  ['crypto.randomUUID', /randomUUID/]
]
console.log('\n关键 API 覆盖检查：')
for (const [name, re] of required) {
  const ok = re.test(polyfill)
  if (!ok) failed++
  console.log(`  ${ok ? '✅' : '❌'} ${name}`)
}

// 白屏探测必须真的读 #root 并设阈值
const probe = blocks[2]
console.log('\n探测逻辑检查：')
const probeChecks = [
  ["读取 #root", /getElementById\('root'\)/],
  ['返回 ok 分支', /return 'ok'/],
  ['返回 blank 分支', /'blank/]
]
for (const [name, re] of probeChecks) {
  const ok = re.test(probe)
  if (!ok) failed++
  console.log(`  ${ok ? '✅' : '❌'} ${name}`)
}

console.log('')
if (failed > 0) {
  console.error(`结论：${failed} 项未通过`)
  process.exit(1)
}
console.log('结论：全部通过（内嵌 JS 语法有效，且三个 API 均已覆盖）')
