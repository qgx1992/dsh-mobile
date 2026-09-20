/**
 * 验证 dsh-pocket 在浏览器携带 Accept-Encoding: gzip 时是否**丢失了 polyfill 注入**。
 *
 * 背景：pocket 的注入分支有一个前置条件 `!isCompressed(proxyRes.headers)`——
 * 若上游 dsh web 自己就把 HTML 压了，则跳过注入，HTML 里就没有 crypto.randomUUID
 * polyfill；而 http://<IP> 是非安全上下文，`crypto.randomUUID` 原生不存在，
 * DSH 前端一调用就崩 → 手机白屏。
 *
 * 本脚本读两个响应体做对照：identity（未压缩）与 gzip（压缩）。
 * 用法：node scripts/verify-injection.mjs <identity.bin> <gzip.bin>
 */
import { readFileSync } from 'node:fs'
import { gunzipSync, brotliDecompressSync } from 'node:zlib'

const KEYS = [
  'data-dsh-pocket-polyfill',
  'data-dsh-pocket-transport-shim',
  'data-dsh-pocket-desktop-patch',
  'crypto.randomUUID',
  'AbortSignal.any',
  'createApiClient',
  '<div id="root">',
  'assets/index-'
]

/** 自动识别并解压 gzip / brotli，返回 utf8 文本 */
function decode(buf) {
  if (buf[0] === 0x1f && buf[1] === 0x8b) {
    return { enc: 'gzip', text: gunzipSync(buf).toString('utf8') }
  }
  // brotli 没有魔数，尝试解压，失败即当明文
  try {
    const t = brotliDecompressSync(buf).toString('utf8')
    if (t.includes('<')) return { enc: 'br', text: t }
  } catch {
    /* 不是 brotli */
  }
  return { enc: 'identity', text: buf.toString('utf8') }
}

const files = process.argv.slice(2)
if (files.length === 0) {
  console.error('用法: node scripts/verify-injection.mjs <file1.bin> [file2.bin ...]')
  process.exit(1)
}

let allGood = true
for (const f of files) {
  const raw = readFileSync(f)
  const { enc, text } = decode(raw)
  const hasPolyfill = text.includes('data-dsh-pocket-polyfill')
  const hasRoot = text.includes('<div id="root">')
  console.log(`\n=== ${f} ===`)
  console.log(`  传输编码: ${enc}   原始 ${raw.length} 字节 → 解码后 ${text.length} 字符`)
  console.log(`  是 HTML 文档: ${hasRoot ? '是' : '否'}`)
  for (const k of KEYS) {
    console.log(`    ${(text.includes(k) ? '命中 ✓' : '缺失 ✗').padEnd(8)} ${k}`)
  }
  if (hasRoot && !hasPolyfill) {
    console.log('  ⚠️ 这是 HTML 文档但没有 polyfill 注入 —— 手机端会因缺少 crypto.randomUUID 而崩')
    allGood = false
  }
  if (hasRoot && hasPolyfill) {
    console.log('  ✅ HTML 文档且 polyfill 已注入')
  }
}
console.log('')
console.log(allGood ? '结论：所测响应均正常（无「HTML 缺 polyfill」情况）' : '结论：存在「HTML 缺 polyfill」的响应 —— 与手机白屏吻合')
