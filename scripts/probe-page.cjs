/**
 * 实机探针：用 Electron（Chromium 内核）真实加载手机要访问的地址，判定「白屏」成因。
 *
 * 背景（已用 curl 实测确认的链路）：
 *   dsh-pocket 只在**未压缩**的 HTML 上注入补丁（proxy.mjs: `!isCompressed(...)`），
 *   而上游 dsh-web-app 的 cordis.patch.yml 默认 `compression: gzip`（阈值 1024B）。
 *   真实浏览器一定发 Accept-Encoding，所以**默认走不到注入分支** —— 手机拿到的
 *   HTML 里没有 pocket 的随机数/传输补丁。
 *
 * 变体：
 *   默认         —— 正常浏览器行为（带 Accept-Encoding），补丁缺失
 *   --strip-ae   —— 剥掉 Accept-Encoding，补丁注入成功（对照）
 *   --kill-apis  —— 在页面脚本前删掉 AbortSignal.any / crypto.randomUUID，
 *                  模拟旧版 iOS Safari（AbortSignal.any 需 Safari 17.4+）。
 *                  与上面两个组合，即可判定「补丁缺失是否会导致崩」。
 *
 * 用法：DSH_PIN=<pin> electron scripts/probe-page.cjs [--strip-ae] [--kill-apis]
 */
const { app, BrowserWindow, session } = require('electron')

const PIN = process.env.DSH_PIN || ''
const HOST = process.env.DSH_HOST || '10.10.0.172:3081'
const STRIP = process.argv.includes('--strip-ae')
const KILL_APIS = process.argv.includes('--kill-apis')
/** --polyfill：装上手写副本的 polyfill；--swift-polyfill：用 AppDelegate.swift 里的真身 */
const POLYFILL = process.argv.includes('--polyfill')
const SWIFT_POLYFILL = process.argv.includes('--swift-polyfill')
const USE_PRELOAD = POLYFILL || SWIFT_POLYFILL || KILL_APIS
const URL = `http://${HOST}/?token=${PIN}`

app.commandLine.appendSwitch('disable-gpu')

const logs = []

app.whenReady().then(async () => {
  const ses = session.defaultSession

  // 变体：剥掉 Accept-Encoding → 上游不压缩 → pocket 注入分支生效
  if (STRIP) {
    ses.webRequest.onBeforeSendHeaders((details, cb) => {
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
    webPreferences: {
      // KILL_APIS 需要 preload 作用到页面主世界 → 必须关掉 contextIsolation。
      // 仅用于本地诊断探针，不进入任何发布产物。
      contextIsolation: !USE_PRELOAD,
      nodeIntegration: false,
      // 沙箱 preload 拿不到 node:内置模块（probe-preload-swift-polyfill 要读 Swift 源码），
      // 故诊断期关掉沙箱。仅本地探针使用，不进任何发布产物。
      sandbox: !USE_PRELOAD,
      ...(SWIFT_POLYFILL
        ? { preload: require('node:path').join(__dirname, 'probe-preload-swift-polyfill.cjs') }
        : POLYFILL
          ? { preload: require('node:path').join(__dirname, 'probe-preload-polyfill.cjs') }
          : KILL_APIS
            ? { preload: require('node:path').join(__dirname, 'probe-preload-kill-apis.cjs') }
            : {})
    }
  })

  win.webContents.on('console-message', (_e, level, message) => {
    logs.push({ level, msg: String(message).slice(0, 500) })
  })
  win.webContents.on('did-fail-load', (_e, code, desc, url) =>
    logs.push({ level: 3, msg: `did-fail-load ${code} ${desc} ${url}` })
  )

  // 变体：在页面脚本执行前抹掉目标 API。
  // 用 preload（见 webPreferences）实现——debugger 的 Page.addScriptToEvaluateOnNewDocument
  // 在本环境会挂起，已弃用。
  if (USE_PRELOAD) {
    logs.push({
      level: 2,
      msg: SWIFT_POLYFILL ? 'using Swift-embedded polyfill' : POLYFILL ? 'polyfill copy' : 'kill-apis (no polyfill)'
    })
  }

  win.webContents.on('render-process-gone', (_e, details) => {
    logs.push({ level: 3, msg: `RENDER PROCESS GONE: ${JSON.stringify(details)}` })
  })
  win.webContents.on('unresponsive', () => {
    logs.push({ level: 3, msg: 'renderer unresponsive' })
  })

  // 保险丝：页面若把渲染进程拖死（白屏的一种形态），executeJavaScript 会永久挂起。
  // 这里强制兜底退出，避免探针本身卡住导致看不到任何结论。
  const fuse = setTimeout(() => {
    console.log(
      JSON.stringify(
        {
          variant: [STRIP ? 'strip-ae' : 'normal', KILL_APIS ? 'kill-apis' : ''].filter(Boolean).join('+'),
          rendered: false,
          verdict: '⚠️ 探针超时：渲染进程疑似被拖死（这类挂起本身即「白屏」的一种表现）',
          errorLogs: logs.filter((l) => l.level >= 3).slice(0, 20)
        },
        null,
        2
      )
    )
    app.exit(0)
  }, 30000)
  fuse.unref?.()

  try {
    await win.loadURL(URL)
  } catch (e) {
    logs.push({ level: 3, msg: `loadURL threw: ${e.message}` })
  }

  // 给 SPA 启动留时间（含握手过渡页 → 再跳）
  await new Promise((r) => setTimeout(r, 9000))
  clearTimeout(fuse)

  let state
  try {
    state = await win.webContents.executeJavaScript(`(() => {
      const root = document.getElementById('root')
      const txt = document.body ? (document.body.innerText || '').trim() : ''
      return {
        href: location.href,
        title: document.title,
        rootExists: !!root,
        rootChildren: root ? root.children.length : -1,
        rootHTMLLen: root ? root.innerHTML.length : -1,
        bodyTextLen: txt.length,
        bodyTextHead: txt.slice(0, 140),
        hasPolyfillScript: !!document.querySelector('script[data-dsh-pocket-polyfill]'),
        hasShimScript: !!document.querySelector('script[data-dsh-pocket-transport-shim]'),
        hasRandomUUID: !!(window.crypto && typeof window.crypto.randomUUID === 'function'),
        hasAbortSignalAny: typeof AbortSignal !== 'undefined' && typeof AbortSignal.any === 'function',
        hasModuleLoader: typeof window.__ModuleLoader__ !== 'undefined',
        hasBoot: typeof window.__DSH_BOOT__ !== 'undefined',
        polyfillFromSwift: window.__polyfillFromSwift === true
      }
    })()`)
  } catch (e) {
    state = { error: e.message }
  }

  // 渲染成功 = root 里真的有内容（白屏则 rootHTMLLen 为 0）
  const rendered = !!(state && state.rootHTMLLen > 1000)

  console.log(
    JSON.stringify(
      {
        variant: [STRIP ? 'strip-ae' : 'normal', KILL_APIS ? 'kill-apis' : ''].filter(Boolean).join('+'),
        rendered,
        verdict: rendered ? '页面正常渲染（非白屏）' : '页面白屏（root 为空）',
        state,
        errorLogs: logs.filter((l) => l.level >= 3).slice(0, 20),
        warnLogs: logs.filter((l) => l.level === 2).slice(0, 6)
      },
      null,
      2
    )
  )

  app.quit()
})
