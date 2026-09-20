#!/bin/bash
# CI 阶段：为 DSH Mobile 的 Xcode 工程生成共享 scheme + 写入 ATS 明文放行。
#
# 必须在 macOS 上运行（用到 PlistBuddy；xcodeproj gem 为可选加速项）。
set -euo pipefail

PROJ_DIR="${1:-ios/App}"
XCODEPROJ="$PROJ_DIR/App.xcodeproj"
PBXPROJ="$XCODEPROJ/project.pbxproj"
SCHEME_DIR="$XCODEPROJ/xcshareddata/xcschemes"
TARGET_NAME="App"

if [ ! -f "$PBXPROJ" ]; then
  echo "ERROR: 找不到 $PBXPROJ" >&2
  exit 1
fi

mkdir -p "$SCHEME_DIR"

# ---------------------------------------------------------------------------
# 1) 解析 target UUID
#
# 只用 xcodeproj gem 做这一件事（`project.targets` / `target.uuid` 是稳定 API），
# scheme XML 由本脚本自己写——不依赖 gem 里那些易变的 XCScheme 方法名
# （曾踩坑：Xcodeproj::XCScheme 并没有 set_archive_target，调用直接 NoMethodError）。
# gem 不可用时回退为 grep 解析 pbxproj。
# ---------------------------------------------------------------------------
TARGET_ID=""
if ruby -e "require 'xcodeproj'" 2>/dev/null; then
  echo "用 xcodeproj gem 解析 target UUID…"
  TARGET_ID=$(ruby <<RUBY_EOF
require 'xcodeproj'
begin
  project = Xcodeproj::Project.open('$XCODEPROJ')
  target = project.targets.find { |t| t.name == '$TARGET_NAME' } || project.targets.first
  puts target ? target.uuid : ''
rescue => e
  warn "xcodeproj 解析失败: #{e.message}"
  puts ''
end
RUBY_EOF
)
fi

if [ -z "${TARGET_ID:-}" ]; then
  echo "回退为文本解析 pbxproj…"
  # 目标块形如：
  #   504EC3031FED79650016851F /* App */ = {
  #       isa = PBXNativeTarget;
  # 取 "isa = PBXNativeTarget" 前一行的 24 位十六进制 id。
  TARGET_ID=$(grep -B1 'isa = PBXNativeTarget' "$PBXPROJ" \
    | grep -oE '^[[:space:]]*[A-F0-9]{24}' \
    | head -n1 \
    | tr -d '[:space:]')
fi

if [ -z "${TARGET_ID:-}" ]; then
  echo "ERROR: 无法解析 PBXNativeTarget id" >&2
  exit 1
fi
echo "target UUID: $TARGET_ID"

# ---------------------------------------------------------------------------
# 2) 写共享 scheme
#
# 为什么需要：`npx cap add ios` 生成的 scheme **不共享**（只存在于
# xcuserdata/<user>.xcuserdatad/xcschemes/，而 CI 上没有 xcuserdata 目录）。
# `xcodebuild -scheme App` 需要 xcshareddata 下的共享 scheme，否则报：
#   The project named "App" does not contain a scheme named "App".
# ---------------------------------------------------------------------------
cat > "$SCHEME_DIR/$TARGET_NAME.xcscheme" <<SCHEME_EOF
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "$TARGET_ID"
               BuildableName = "$TARGET_NAME.app"
               BlueprintName = "$TARGET_NAME"
               ReferencedContainer = "container:$TARGET_NAME.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "$TARGET_ID"
            BuildableName = "$TARGET_NAME.app"
            BlueprintName = "$TARGET_NAME"
            ReferencedContainer = "container:$TARGET_NAME.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "$TARGET_ID"
            BuildableName = "$TARGET_NAME.app"
            BlueprintName = "$TARGET_NAME"
            ReferencedContainer = "container:$TARGET_NAME.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
SCHEME_EOF

echo "--- scheme 目录 ---"
ls -la "$SCHEME_DIR"

# 自证：确认 scheme 真的可被 xcodebuild 识别（失败即早退，不留到 archive 步骤才发现）
echo "--- xcodebuild -list 自检 ---"
xcodebuild -list -project "$XCODEPROJ" 2>&1 | tee /tmp/xcodebuild-list.txt
if ! grep -q "$TARGET_NAME" /tmp/xcodebuild-list.txt; then
  echo "ERROR: xcodebuild 未列出 $TARGET_NAME，scheme 生成失败" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3) 配置 ATS：只放行 WKWebView 的明文加载，不全局关闭 ATS。
#
# 依据（Apple 文档 + 源码勘察）：
#  - WKWebView 受 ATS 约束（iOS 10 起）；
#  - 局域网模式是 http://<私有IP>:3081，而 iOS 17+ 默认不再允许 IP 字面量连接；
#  - NSAllowsArbitraryLoadsInWebContent 只放开 WebView，URLSession 仍受保护；
#  - **绝不**用 NSAllowsArbitraryLoads（全局关闭 ATS；且 iOS 10+ 上会被更窄的键
#    静默覆盖为 NO，等于没写）；
#  - **不要**同时写 NSExceptionDomains：全局豁免对其中已列出的域名不生效，
#    反而会让该域名更严格；
#  - WKWebView 的局域网流量不触发「本地网络隐私」权限，故无需
#    NSLocalNetworkUsageDescription / NSBonjourServices。
# ---------------------------------------------------------------------------
PLIST="$PROJ_DIR/App/Info.plist"
if [ ! -f "$PLIST" ]; then
  echo "ERROR: 找不到 $PLIST" >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$PLIST" >/dev/null 2>&1; then
  echo "ATS 键已存在，跳过写入"
else
  /usr/libexec/PlistBuddy \
    -c "Add :NSAppTransportSecurity dict" \
    -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoadsInWebContent bool true" \
    "$PLIST"
  echo "已写入 ATS：NSAllowsArbitraryLoadsInWebContent = true"
fi

# 自证：确认没有误留全局关闭 ATS 的键
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" "$PLIST" >/dev/null 2>&1; then
  echo "ERROR: Info.plist 含 NSAllowsArbitraryLoads（全局关闭 ATS），必须移除" >&2
  exit 1
fi

echo "--- Info.plist ATS 段 ---"
/usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$PLIST"
echo "--- CFBundleDisplayName ---"
/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$PLIST" || true
