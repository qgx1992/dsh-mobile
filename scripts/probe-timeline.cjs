/**
 * 时序探针：观察 #root 从导航开始到 20 秒的填充过程。
 *
 * 为什么需要：用户反馈「提示页面没有渲染出来 + blank sentinelOk=true」——
 * 即收集器正常、无 JS 异常，但我的诊断器判定 #root 为空。
 * 我的诊断器在 `applicationDidBecomeActive` 后 12 秒采样；而真实流程是
 * 「本地连接页 → 导航到远端 → pocket 握手过渡页 → meta refresh 跳回 / → SPA 启动」，
 * 中间会经历**多次导航**。若采样时机落在过渡页上，#root 必然为空 → 误报。
 *
 * 本探针按真实节奏记录每秒的 URL 与 #root 长度，用来判断：
 *   a) 页面其实渲染成功、只是我的采样太早/落在过渡页 → 诊断器误报
 *   b) 页面确实始终为空 → 真白屏，需继续查
 *
 * 用法：DSH_PIN=<pin> electron scripts/probe-timeline.cjs
 */
const { app, BrowserWindow, session } = require('electron')

const PIN = process.env.DSH_PIN || ''
const HOST = process.env.DSH_HOST || '10.10.0.172:3081'
const URL = `http://${HOST}/?token=${PIN}`
/** 是否剥掉 Accept-Encoding（对照：pocket 补丁能否注入） */
const STRIP = process.argv.includes('--strip-ae')

app.commandLine.appendSwitch('disable-gpu')

app.whenReady().then(async () => {
  if (STRIP) {
    session.defaultSession.webRequest.onBeforeSendHeaders((details, cb) => {
      const h = { ...details.requestHeaders }
      for (const k of Object.keys(h)) {
        if (k.toLowerCase() === 'accept-encoding') delete h[k]
      }
      cb({ requestHeaders: h })
    })
  }

  const win = new BrowserWindow({
    show: false,
    width: 390,
    height: 844,
    webPreferences: { contextIsolation: true, nodeIntegration: false }
  })

  const navLog = []
  win.webContents.on('did-navigate', (_e, url) => navLog.push({ t: Date.now(), url }))
  win.webContents.on('did-finish-load', () => navLog.push({ t: Date.now(), url: '(finish)' }))

  const t0 = Date.now()
  const rows = []

  // 起一个循环采样：每秒读一次当前 URL 与 #root 长度
  const sampler = setInterval(async () => {
    const elapsed = ((Date.now() - t0) / 1000).toFixed(1)
    try {
      const r = await win.webContents.executeJavaScript(`(() => {
        var root = document.getElementById('root');
        return location.pathname + '|' + (root ? root.innerHTML.length : -1)
      })()`)
      const [path, len] = String(r).split('|')
      rows.push({ t: elapsed, path, rootLen: Number(len) })
      console.log(`  ${String(elapsed).padStart(5)}s  path=${path.padEnd(28)} #root=${len}`)
    } catch (e) {
      rows.push({ t: elapsed, err: e.message })
      console.log(`  ${String(elapsed).padStart(5)}s  (读取失败: ${e.message.slice(0, 60)})`)
    }
  }, 1000)

  await win.loadURL(URL)
  await new Promise((r) => setTimeout(r, 20000))
  clearInterval(sampler)

  const final = rows[rows.length - 1] || {}
  const everRendered = rows.some((r) => r.rootLen > 400)
  const maxLen = Math.max(...rows.map((r) => r.rootLen || -1))

  console.log('\n=== 导航事件 ===')
  for (const n of navLog) {
    console.log(`  +${((n.t - t0) / 1000).toFixed(1)}s  ${n.url}`)
  }

  console.log('\n=== 判定 ===')
  console.log(`  最大 #root 长度: ${maxLen}`)
  console.log(`  是否曾经渲染成功: ${everRendered ? '是' : '否'}`)
  if (everRendered) {
    console.log('  → 页面**可以**渲染成功。若 App 里报白屏，则是诊断器的采样时机问题（误报）')
  } else {
    console.log('  → 页面始终为空（真白屏），需继续排查资源/启动链')
  }
  console.log(`  结束时 URL: ${final.path ?? final.err}`)

  app.exit(0)
})
