/**
 * 校验 AppDelegate.swift 里内嵌的 JS 是否语法有效、且关键能力齐全。
 *
 * 为什么要这一步：本机是 Windows，**没有 Swift 编译器**，无法 `swiftc` 校验；
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

/**
 * 从 `addEventListener('error'` 起点做括号配对，判断该监听器是否以 `, true)` 收尾
 * （即使用捕获阶段）。
 *
 * 为什么不用「正则 + 固定字符窗口」：窗口宽度是脆弱假设，实测监听器体长 660 字符，
 * 用 400 的窗口会把**正确的代码**误报为失败（本次真实踩到）。
 */
function isListenerWithCapture(code, marker) {
  const start = code.indexOf(marker)
  if (start < 0) return false
  // 从 marker 后的第一个 '{' 开始配对
  const braceStart = code.indexOf('{', start)
  if (braceStart < 0) return false
  let depth = 0
  for (let i = braceStart; i < code.length; i++) {
    const c = code[i]
    if (c === '{') depth++
    else if (c === '}') {
      depth--
      if (depth === 0) {
        // 闭括号之后的第一个非空 token 应是 `, true)`
        const tail = code.slice(i, i + 40)
        return /^\}\s*,\s*true\s*\)/.test(tail)
      }
    }
  }
  return false
}

const blocks = extractRawStrings(src)
const EXPECTED = 3
console.log(`抽到 ${blocks.length} 段 Swift 原始字符串（预期 ${EXPECTED} 段：polyfill / diag / probe）`)

if (blocks.length !== EXPECTED) {
  console.error('❌ 段数与预期不符——请检查 #""" ... """# 的写法')
  process.exit(1)
}

const names = ['polyfillScript（能力兜底）', 'diagScript（收集器+提示层）', 'probeScript（采样）']
const [polyfill, diag, probe] = blocks
let failed = 0

console.log('\n[1] JS 语法检查')
blocks.forEach((code, i) => {
  try {
    // 只做语法解析，不执行（避免真的去改 Node 的全局对象）
    new vm.Script(code, { filename: `${names[i]}.js` })
    console.log(`  ✅ ${names[i]}: 有效（${code.length} 字符）`)
  } catch (e) {
    failed++
    console.error(`  ❌ ${names[i]}: 语法错误 → ${e.message}`)
  }
})

console.log('\n[2] polyfill 必须覆盖全部三个 API（漏一个仍会白屏）')
for (const [name, re] of [
  ['Promise.withResolvers', /withResolvers/],
  ['AbortSignal.any', /AbortSignal\.any/],
  ['crypto.randomUUID', /randomUUID/]
]) {
  const ok = re.test(polyfill)
  if (!ok) failed++
  console.log(`  ${ok ? '✅' : '❌'} ${name}`)
}

console.log('\n[3] 收集器必须用捕获阶段（资源加载失败不冒泡）')
{
  // 注意：不要用「固定字符窗口 + 正则」判断配对，窗口宽度是脆弱假设
  // （实测监听器体长 660 字符，400 的窗口会误报失败）。改为从起点做括号配对。
  const ok = isListenerWithCapture(diag, "addEventListener('error'")
  if (!ok) failed++
  console.log(`  ${ok ? '✅' : '❌'} error 监听带 capture=true`)
  const sentinel = /sentinelOk/.test(diag)
  if (!sentinel) failed++
  console.log(`  ${sentinel ? '✅' : '❌'} 含自证哨兵 sentinelOk`)
}

console.log('\n[4] 提示层不得覆盖整页（v0.1.1 误报遮罩的教训）')
{
  // 遮罩版会写 inset:0 + background，这会把正常页面盖住
  const covers = /inset:\s*0/.test(diag)
  if (covers) failed++
  console.log(`  ${covers ? '❌ 仍使用 inset:0 覆盖整页' : '✅ 未覆盖整页（仅底部提示）'}`)
  const closable = /__dshExoHideBlank/.test(diag)
  if (!closable) failed++
  console.log(`  ${closable ? '✅' : '❌'} 提供关闭/自愈接口 __dshExoHideBlank`)
}

console.log('\n[5] 采样脚本契约（返回 "状态|地址|详情"）')
for (const [name, re] of [
  ["包含 ok 分支", /return 'ok\|'/],
  ["包含 noroot 分支", /return 'noroot\|'/],
  ["包含 blank 分支", /return 'blank\|'/],
  ['读取 #root', /getElementById\('root'\)/]
]) {
  const ok = re.test(probe)
  if (!ok) failed++
  console.log(`  ${ok ? '✅' : '❌'} ${name}`)
}

console.log('\n[6] 连续采样判定（避免单次采样误报）')
{
  const ok = /blankStreak\s*>=\s*4/.test(src)
  if (!ok) failed++
  console.log(`  ${ok ? '✅' : '❌'} 需连续 4 次同地址为空才提示`)
  const reset = /case "ok":[\s\S]{0,200}blankStreak = 0/.test(src)
  if (!reset) failed++
  console.log(`  ${reset ? '✅' : '❌'} 页面恢复正常时重置计数`)
}

console.log('')
if (failed > 0) {
  console.error(`结论：${failed} 项未通过`)
  process.exit(1)
}
console.log('结论：全部通过（JS 语法有效、三 API 齐全、收集器与提示层行为正确）')
