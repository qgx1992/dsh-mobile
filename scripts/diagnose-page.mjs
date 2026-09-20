/**
 * 对比 dsh-pocket 在不同 Accept-Encoding 下返回的 HTML，定位「手机白屏」的真实原因。
 *
 * 检查三类可能导致白屏的启动前置：
 *   1) 启动注入是否齐全（__DSH_BOOT__ / __ModuleLoader__ / __DSH_BOOT_READY__）
 *   2) 是否残留指向 127.0.0.1:<上游端口> 的绝对地址（手机浏览器无法访问自己的回环）
 *   3) pocket 自身补丁（polyfill / transport shim / desktop 补丁）是否被注入
 *
 * 用法：node scripts/diagnose-page.mjs <file1> [file2 ...]
 */
import { readFileSync } from 'node:fs'
import { gunzipSync, brotliDecompressSync } from 'node:zlib'

function decode(buf) {
  if (buf[0] === 0x1f && buf[1] === 0x8b) return { enc: 'gzip', text: gunzipSync(buf).toString('utf8') }
  try {
    const t = brotliDecompressSync(buf).toString('utf8')
    if (t.includes('<')) return { enc: 'br', text: t }
  } catch {
    /* 非 brotli */
  }
  return { enc: 'identity', text: buf.toString('utf8') }
}

/** 启动必需项：任一缺失都可能让 SPA 起不来 */
const BOOT_KEYS = ['__DSH_BOOT__', '__DSH_BOOT_READY__', '__ModuleLoader__', 'dshDesktopBoot', '<div id="root">']
/** pocket 注入项 */
const POCKET_KEYS = ['data-dsh-pocket-polyfill', 'data-dsh-pocket-transport-shim', 'data-dsh-pocket-desktop-patch']

for (const f of process.argv.slice(2)) {
  const raw = readFileSync(f)
  const { enc, text } = decode(raw)
  console.log(`\n${'='.repeat(66)}\n${f}\n  传输编码=${enc}  原始=${raw.length}B  解码后=${text.length}字符\n${'='.repeat(66)}`)

  console.log('\n[1] SPA 启动前置')
  for (const k of BOOT_KEYS) console.log(`    ${(text.includes(k) ? '存在 ✓' : '缺失 ✗').padEnd(8)} ${k}`)

  console.log('\n[2] pocket 注入')
  for (const k of POCKET_KEYS) console.log(`    ${(text.includes(k) ? '存在 ✓' : '缺失 ✗').padEnd(8)} ${k}`)

  console.log('\n[3] 绝对地址残留（手机无法访问 127.0.0.1）')
  const localhostHits = [...text.matchAll(/https?:\/\/(?:127\.0\.0\.1|localhost)(?::\d+)?[^\s"'<>\\]*/g)].map((m) => m[0])
  const uniq = [...new Set(localhostHits)]
  if (uniq.length === 0) {
    console.log('    未发现 127.0.0.1 / localhost 绝对地址 ✓')
  } else {
    console.log(`    发现 ${uniq.length} 种：`)
    for (const u of uniq.slice(0, 12)) console.log(`      ${u}`)
  }

  console.log('\n[4] 引用的外部资源（前 12 个）')
  const refs = [...text.matchAll(/(?:src|href)="([^"]+)"/g)].map((m) => m[1])
  for (const r of refs.slice(0, 12)) {
    const abs = /^https?:\/\//.test(r)
    const bad = /^https?:\/\/(?:127\.0\.0\.1|localhost)/.test(r)
    console.log(`    ${bad ? '⚠️ 回环绝对地址' : abs ? '绝对地址' : '相对地址'}  ${r.slice(0, 96)}`)
  }
}
