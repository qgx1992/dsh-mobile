# DSH Mobile

连接**电脑上运行的 DeepSeek Harness** 的 iOS 原生外壳。

> 配套设计文档见 DSH-Exoskeleton 仓库的 [`docs/MOBILE-APP-DESIGN.md`](https://github.com/qgx1992/DSH-Exoskeleton/blob/main/docs/MOBILE-APP-DESIGN.md)（B 路径方案）。

## 这是什么（先读，避免误解）

**它不把 DSH 装进手机。** DSH 内核（`dsh web` + Node + 原生模块）始终在你电脑上跑，本 App 只是一个**指向电脑上 dsh-pocket 代理**的 WebView 外壳。

- ✅ 手机扫码/填地址 → 看到并操控电脑上的同一个 DSH 界面（实时同步）
- ✅ 局域网（同一 WiFi）或公网隧道（人在外面）
- ❌ 电脑关机 / 断网 / 关掉「手机访问」时**用不了**——这是设计前提，不是 bug

手机端要连的地址由电脑上的 **dsh-pocket** 提供（局域网默认 `http://<电脑IP>:3081`，公网为 `https://…`）。

## 拿 IPA

在 GitHub 上手动触发构建：

1. 打开本仓库 **Actions** → 左侧 **Build iOS IPA** → 右上 **Run workflow**
2. 等约 5~10 分钟
3. 在本次运行的 **Artifacts** 里下载 `DSH-Mobile-unsigned-ipa`

产物是 **未签名 IPA**。这有两个必须知道的后果：

> **未签名 IPA 不能直接双击安装到 iPhone 上。** iOS 要求每个 App 都有 Apple 的签名。CI 上没有（也不该有）你的签名证书，所以只能产出未签名的包，由你**用自己的 Apple ID 重签后安装**。

## 安装（手机上要用，必须走这一步）

用电脑上的 **Sideloadly**（Windows/macOS 均可，推荐）或 **AltStore**：

1. 下载 [Sideloadly](https://sideloadly.io/)
2. iPhone 用数据线连电脑，信任此电脑
3. 把 `DSH-Mobile-unsigned.ipa` 拖进 Sideloadly
4. 填自己的 Apple ID（免费账号即可）
5. 点 Start，输入 Apple ID 密码（用于生成签名证书）

**免费 Apple ID 的限制**（Apple 的策略，无法绕过）：

| 限制 | 说明 |
| :--- | :--- |
| 有效期 **7 天** | 到期 App 打不开，需重新用 Sideloadly 签一次（AltStore 可自动续签） |
| 最多 **3 个**自签 App | 同时存在的数量上限 |
| 每次重签 | 需要电脑 + 数据线（AltStore 走 WiFi 可自动） |

要摆脱这些限制需要 **Apple 开发者账号**（$99/年，签名有效期 1 年）。本仓库也支持用你自己的证书在 CI 上签名（见下）。

## 用

1. 电脑上打开 DSH → 设置 →「手机访问」，确认局域网访问已开
2. 手机 App 里填地址，例如 `192.168.1.5:3081`（可省略 `http://`，会自动补端口）
3. 点「连接」→ 若跳转到密码页，输入 DSH 设置页显示的 8 位 PIN
4. 连上后**从屏幕左边缘向右滑**可退回连接页换地址

## 用开发者账号在 CI 上正式签名（可选）

在仓库 Settings → Secrets 配置以下内容后，可改为产出**已签名**的 IPA（有效期 1 年、无需每次重签）：

| Secret | 说明 |
| :--- | :--- |
| `BUILD_CERTIFICATE_BASE64` | `.p12` 证书的 base64 |
| `P12_PASSWORD` | 导出 `.p12` 时设的密码 |
| `PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `KEYCHAIN_PASSWORD` | 临时 keychain 密码（自定） |
| `APPLE_TEAM_ID` | 团队 ID |

（需要改 `.github/workflows/build-ios.yml`，把 `CODE_SIGNING_ALLOWED=NO` 换成导入证书与描述文件的步骤。）

## 常见问题

| 现象 | 原因与解法 |
| :--- | :--- |
| 连不上，提示检查网络 | 电脑 DSH 没运行 /「手机访问」没开 / 不同 WiFi / 局域网 IP 变了 |
| 打开是密码页 | 正常。PIN 在电脑 DSH 的「手机访问」设置里；dsh web 每次重启都需要重输一次 |
| 装完打不开、提示「无法验证 App」 | 自签证书过期（7 天），重新用 Sideloadly 签一次 |
| 想让地址固定不变 | 在 dsh-pocket 里启用**命名隧道**（Cloudflare 固定域名）；快速隧道地址每次重启都会变 |
| 进去后是白屏 | 见下节；v0.1.1 起 App 已内置能力兜底与白屏自诊断 |
| 进去后提示「页面没有渲染出来」 | 这是 App 的白屏自诊断层，按它给出的错误信息排查 |

### 关于白屏（v0.1.1 已修复）

如果旧版出现「连上后一片空白」，根因是 **DSH 内核调用了旧版 iOS 缺失的三个 Web API**：

| API | 为什么缺 | 后果 |
| :--- | :--- | :--- |
| `Promise.withResolvers` | 需 Safari **17.4+**（iOS 17.4） | **最致命**：DSH 内联 boot 脚本依赖它，缺失即整个前端起不来 = 白屏 |
| `AbortSignal.any` | 需 Safari **17.4+** | 连接层 `postJson` 抛错 |
| `crypto.randomUUID` | 仅**安全上下文**可用，而局域网是 `http://<IP>` | 调用处抛错 |

`dsh-pocket` 本会注入这些 polyfill，但它只在**未压缩**的 HTML 上注入，而 DSH 内核默认开启 gzip，真实浏览器一定发 `Accept-Encoding` → 注入被静默跳过。

**v0.1.1 起 App 自己在 `documentStart` 注入这三个 API**，不再依赖 pocket 能否注入成功。同时加了白屏自诊断：12 秒内 `#root` 仍为空时，会把页面捕获到的 JS 错误显示出来（而不是留一片空白）。

> 若仍白屏：请把诊断层显示的错误信息截图反馈。也可先用 **Chrome 打开同一地址**对照——若 Chrome 正常而 App 白屏，说明是 WebView 侧问题。
>
> **完整排查记录见 [docs/WHITE-SCREEN.md](docs/WHITE-SCREEN.md)**（含两个根因、可复用探针脚本、以及踩坑教训）。

#### v0.1.2 修掉的「假白屏」

v0.1.1 的诊断层本身有缺陷，**它会把正常页面盖住**，制造出白屏观感：

- 计时从 App 激活起算，而你那时还在连接页输 PIN —— 到点若抓到 SPA 刚加载、尚未渲染的瞬间就误判；
- 误判后插入的是**全屏不透明遮罩**，把本来正常的页面整个盖住。

现在改为：每 3 秒采样、**同一地址连续 4 次为空**才提示；提示层**只占底部、可关闭**，页面恢复后自动消失。

> 诊断信息里 `sentinelOk=true` 且「捕获到的错误: 无」是个重要信号：
> 说明收集器工作正常、页面**没有抛 JS 异常** —— 这种情况多半是误报，可直接关闭提示。



## 开发

```bash
npm install
npx cap sync ios      # 把 www/ 同步进 ios 工程
```

`www/index.html` 是连接页（纯静态，无框架）。改完 `www/` 后跑 `npx cap sync ios`，或直接推送到 `main` 让 CI 构建。

本地生成图标：

```bash
node scripts/make-icon.mjs
```

## 安全说明

本 App 连接的是**能在你电脑上执行代码的 DSH**：

- 局域网地址与 PIN **不要分享给他人**
- 公网访问请用强 PIN，用完即关（dsh-pocket 提供开关）
- 明文 HTTP 仅按需放行：App 只对 **WKWebView** 放开 ATS（`NSAllowsArbitraryLoadsInWebContent`），**没有**全局关闭 ATS，`URLSession` 等其他通道仍受保护
- dsh-pocket 的认证、限速、隧道安全策略均由它自身负责，本 App 不弱化任何一项
