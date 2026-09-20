/**
 * 逐项检查手机要加载的每个资源是否真的可获取。
 *
 * 背景：用户反馈诊断层显示 `blank sentinelOk=true` —— 即收集器工作正常、
 * 页面没有未捕获的 JS 异常，但 #root 为空。
 * 这种「无异常却空」的组合，最可能是**资源加载失败**（script 404）：
 * 资源错误不冒泡到 window（除非 capture），所以我的收集器看不到它们。
 *
 * 本脚本从真实响应里抽出所有 script src，逐个请求并报告状态码与长度。
 *
 * 用法：node scripts/check-assets.mjs <cookieFile> <host>
 */
import { readFileSync } from 'node:fs'

const cookiefile = process.argv[2]
const host = process.argv[3] || '10.10.0.172:3081'
if (!cookiefile) {
  console.error('用法: node scripts/check-assets.mjs <cookie.txt> [host]')
  process.exit(1)
}

// 读取 Netscape 格式 cookie（curl -c 产出）
function readCookies(file) {
  const lines = readFileSync(file, 'utf8').split(/\r?\n/)
  const out = []
  for (let l of lines) {
    if (!l) continue
    // 关键：HttpOnly cookie 在 Netscape 格式里写作 `#HttpOnly_<domain>\t...`，
    // 以 '#' 开头但不是注释。早先直接 `startsWith('#')` 跳过，会把认证 cookie
    // 整个丢掉 → 请求退回登录页（实测踩坑）。
    if (l.startsWith('#HttpOnly_')) {
      l = l.slice('#HttpOnly_'.length)
    } else if (l.startsWith('#')) {
      continue
    }
    const parts = l.split('\t')
    if (parts.length >= 7) out.push(`${parts[5]}=${parts[6]}`)
  }
  return out.join('; ')
}

const cookie = readCookies(cookiefile)
const base = `http://${host}`

const res = await fetch(`${base}/`, { headers: { cookie } })
const html = await res.text()
console.log(`主页: HTTP ${res.status}  ${html.length} 字符\n`)

const srcs = [...html.matchAll(/<script[^>]*\ssrc="([^"]+)"/g)].map((m) => m[1])
console.log(`发现 ${srcs.length} 个 script src\n`)

// 关键前置断言：没抽到任何 script 说明我们拿到的不是真正的 SPA 页面
// （多半是没认证成功的登录页）。此时若无脑输出「所有脚本均可加载」，
// 就是一条恒真的假绿结论，会把排查引向错误方向。
if (srcs.length === 0) {
  console.error('❌ 未从响应中抽到任何 script src —— 多半拿到的是登录页，cookie 未生效。')
  console.error('   请检查 cookie 文件与 ?token= 流程；本次结论不可信。')
  console.error(`   响应片段: ${html.slice(0, 120).replace(/\s+/g, ' ')}`)
  process.exit(1)
}

let bad = 0
for (const raw of srcs) {
  // HTML 实体还原（&amp; → &）
  const src = raw.replace(/&amp;/g, '&')
  const url = src.startsWith('http') ? src : `${base}${src.startsWith('/') ? '' : '/'}${src}`
  try {
    const r = await fetch(url, { headers: { cookie } })
    const len = Number(r.headers.get('content-length') || 0)
    const body = await r.arrayBuffer()
    const ok = r.status === 200 && body.byteLength > 0
    if (!ok) bad++
    console.log(
      `${ok ? '✅' : '❌'} HTTP ${r.status}  ${String(body.byteLength).padStart(7)}B  url_len=${url.length}`
    )
    if (!ok) console.log(`     ${url.slice(0, 200)}${url.length > 200 ? '…' : ''}`)
  } catch (e) {
    bad++
    console.log(`❌ 请求失败: ${e.message}`)
    console.log(`     ${url.slice(0, 200)}`)
  }
}

console.log('')
if (bad > 0) {
  console.log(`结论：${bad} 个脚本无法加载 —— 这会让前端缺模块，表现为白屏或「Failed to load plugins」`)
  console.log('注意：这类失败不会触发 window 的 error 事件（资源错误不冒泡），')
  console.log('      因此诊断层显示「无错误」是符合预期的，需要加 capture 才能捕获。')
} else {
  console.log('结论：所有脚本均可加载（说明白屏另有原因）')
}
