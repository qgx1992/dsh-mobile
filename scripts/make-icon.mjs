/**
 * 生成 iOS App 图标（1024×1024，不透明、直角）。
 *
 * iOS 规范要点：
 *  - 尺寸 1024×1024，用于 App Store 与设备图标源；
 *  - **不要预置圆角**：系统会自动套用圆角遮罩，自带圆角会显得被切两刀；
 *  - **必须不透明**：带 alpha 的图标在 iOS 上会被填黑底，故这里 flatten 掉。
 *
 * 图案：复用桌面端「黑金鲸鱼」品牌资产的鲸鱼路径，居中置于黑金渐变底上。
 * 用法：node scripts/make-icon.mjs [输出路径]
 */
import { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.join(__dirname, '..')
const require = createRequire(import.meta.url)

// sharp 不在本项目依赖里（避免为一次性图标生成引入重依赖），
// 直接复用本机已安装的 sharp（DSH 内核 store 内的副本）。
const SHARP_PATH =
  process.env.DSH_SHARP_PATH ||
  'C:/Users/qq817/AppData/Roaming/DSH-Exoskeleton/kernels/0.1.6-alpha.2/node_modules/.pnpm/sharp@0.35.4_@types+node@26.6.1/node_modules/sharp'

const sharp = require(SHARP_PATH)

const SIZE = 1024
/** 鲸鱼占画布比例（留白，避免顶满） */
const WHALE_RATIO = 0.62

/** 从 whale-gold.svg 中取出 path 的 d 属性（避免把整份 SVG 硬编码进来） */
function extractWhalePath() {
  const candidates = [
    path.join(ROOT, 'assets', 'whale-gold.svg'),
    'D:/A-my project/研究agent桌面端/DSH-Exoskeleton/resources/official/whale-gold.svg'
  ]
  for (const file of candidates) {
    try {
      const svg = readFileSync(file, 'utf-8')
      const m = svg.match(/<path[^>]*\sd="([^"]+)"/)
      if (m) return { d: m[1], source: file }
    } catch {
      /* 尝试下一个候选 */
    }
  }
  throw new Error('找不到 whale-gold.svg（可放到 assets/whale-gold.svg）')
}

const { d, source } = extractWhalePath()
console.log('鲸鱼路径来源:', source)

// whale-gold.svg 的 viewBox 是 0 0 50 50
const WHALE_VIEWBOX = 50
const scale = (SIZE * WHALE_RATIO) / WHALE_VIEWBOX
const offset = (SIZE - WHALE_VIEWBOX * scale) / 2

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#17181C"/>
      <stop offset="100%" stop-color="#050506"/>
    </linearGradient>
    <linearGradient id="gold" x1="0" y1="0" x2="0.2" y2="1">
      <stop offset="0%" stop-color="#F7E08B"/>
      <stop offset="52%" stop-color="#D4AF37"/>
      <stop offset="100%" stop-color="#8C6114"/>
    </linearGradient>
  </defs>
  <rect width="${SIZE}" height="${SIZE}" fill="url(#bg)"/>
  <g transform="translate(${offset.toFixed(2)} ${offset.toFixed(2)}) scale(${scale.toFixed(4)})">
    <path d="${d}" fill="url(#gold)"/>
  </g>
</svg>`

const out =
  process.argv[2] ||
  path.join(ROOT, 'ios', 'App', 'App', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon-512@2x.png')

await sharp(Buffer.from(svg))
  .flatten({ background: '#0d0e11' }) // 去 alpha：iOS 图标必须不透明
  .png({ compressionLevel: 9 })
  .toFile(out)

// 自证：读回确认尺寸与不透明
const meta = await sharp(out).metadata()
console.log(`已生成 ${out}`)
console.log(`  尺寸: ${meta.width}x${meta.height}  通道: ${meta.channels}  alpha: ${meta.hasAlpha}`)
if (meta.width !== SIZE || meta.height !== SIZE || meta.hasAlpha) {
  throw new Error('图标校验失败：尺寸或透明度不符')
}

// 同步一份到 www/ 便于网页端复用（可选）
writeFileSync(path.join(ROOT, 'assets', '.icon-generated'), new Date().toISOString())
