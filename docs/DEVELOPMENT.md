# AgentsHUD — 开发 / 维护文档

面向贡献者与维护者。使用说明见 [README](../README.md)。

## 仓库结构

| 目录 | 说明 |
|------|------|
| [`server/`](../server/) | 电脑端 Node + TypeScript 服务：采集 `~/.claude` 数据、状态机、WebSocket、终端二维码、安装 hook |
| [`android/`](../android/) | Kotlin + Jetpack Compose App：扫码、WebSocket 客户端、全屏 HUD 面板 |
| [`mac/`](../mac/) | Swift + SwiftUI 菜单栏 App：`MenuBarExtra` 悬浮窗，同机直连 `127.0.0.1:4317`（免配对），镜像 Android 面板 |

数据层是可插拔的 `Provider`（`server/src/providers/`）。第一版聚焦 Claude Code；Gemini 等可作为第二个 provider 接入。

---

## 源码直接运行（不装 Homebrew）

```bash
cd server
npm install
npm start                       # 开发模式（tsx 直跑 TS）
npm run build && npm run start:prod   # 编译到 dist/ 后用 node 运行
npm run setup-hooks             # 安装 Claude Code hooks + statusLine
npm run uninstall-hooks         # 移除
npm run typecheck               # tsc --noEmit
```

Android 自行构建（需 Android Studio 自带 JDK 或本机 JDK 17）：

```bash
cd android
./gradlew assembleRelease   # 产物：app/build/outputs/apk/release/app-release.apk
# assembleDebug 出 debug 版；注意 debug 与 release 签名不同，两者不能互相覆盖更新
```

Mac 菜单栏 App（需 macOS 13+ 与 Xcode Command Line Tools）：

```bash
cd mac
swift run                   # 开发直跑
bash build-app.sh           # 编译并打包成 Agents-HUD.app（菜单栏常驻、无 Dock 图标）
# 验证渲染：.build/release/AgentsHUD --render-test out.png（离屏把面板渲染成 PNG）
```

---

## 服务端环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `CC_SIGNAL_PORT` | `4317` | HTTP/WebSocket 端口 |
| `CC_SIGNAL_HOST` | `0.0.0.0` | 绑定地址（保持 0.0.0.0 才能被手机访问）|
| `CC_SIGNAL_TOKEN` | 空 | 设置后启用共享 token 鉴权（二维码会带上）|
| `CC_SIGNAL_TOKEN_BUDGET` | `2000000` | 本地 5H 估算的百分比分母 |
| `CC_SIGNAL_PERCENT_BASIS` | `budget` | `budget` 或 `maxBlock` |
| `CC_SIGNAL_QUIET_AFTER_MS` | `300000` | 等候→空闲 的空闲阈值 |
| `CC_SIGNAL_WORKING_TIMEOUT_MS` | `90000` | 工作无新事件→等候 的超时 |
| `CC_SIGNAL_DROP_AFTER_MS` | `21600000` | 超过此时长无活动的会话从列表移除 |
| `CC_SIGNAL_CLAUDE_DIR` | `~/.claude` | Claude 数据目录 |

---

## 数据契约（WebSocket / REST 下发）

`GET /api/snapshot` 与 WebSocket 推送同一结构（详见 `server/src/state.ts` 与
`android/.../data/Snapshot.kt`）：

```jsonc
{
  "provider": "claude",
  "plan": "Max (5x)",
  "model": "Opus 4.8 (1M)",                 // 最近活跃会话的模型
  "status": { "waiting": 1, "working": 1, "quiet": 2, "notify": 0, "error": 0,
              "dominant": "working", "total": 4 },
  "usage5h": { "percent": 8, "tokensUsed": 123456, "tokenBudget": 2000000,
               "resetInMinutes": 211, "source": "live" },
  "usage7d": { "percent": 13, "resetInMinutes": 6540 },   // 没有官方数据时为 null
  "sessions": [ { "id": "...", "project": "优化仪表板布局", "cwd": "/Users/...",
                  "state": "working", "model": "claude-opus-4-8[1m]",
                  "lastActivity": 0, "tokens": 928300,
                  "contextTokens": 273405, "contextLeftPercent": 73,
                  "currentTool": "Bash: npm run build" } ],
  "totals": { "todayTokens": 2463337, "sevenDayTokens": 10898294 },
  "ts": "..."
}
```

服务端接口：`GET /healthz`、`GET /api/snapshot`、`POST /hooks`、`POST /statusline`、`WS /`。

---

## Android / Mac 构建与发布（CI）

推送 `v*` 标签时，两条 GitHub Actions 流水线**并行**触发，各自把产物作为附件发布到对应的 GitHub
Release（也都可在 Actions 页 workflow_dispatch 手动触发，只产出构建工件）：

- **Android**（[`.github/workflows/android.yml`](../.github/workflows/android.yml)）→ 签名的 release APK
  `agents-hud-<版本>.apk`。
- **macOS**（[`.github/workflows/mac.yml`](../.github/workflows/mac.yml)）→ 通用二进制（arm64 + x86_64）
  打成的 `agents-hud-<版本>-mac.dmg`（在 `macos-14` runner 上 `UNIVERSAL=1 bash mac/build-app.sh` +
  `mac/make-dmg.sh`）。

Android 发布签名用仓库内固定的 keystore（`android/app/agentshud-release.jks`，密码见
`app/build.gradle.kts`）。**Android 流水线无需任何 GitHub Secrets**——固定密钥是为了让 App 能覆盖
更新（Android 要求新版 APK 与已安装版签名一致）；若要改用私有密钥，设置
`AGENTSHUD_KEYSTORE_FILE`/`_PASSWORD`/`AGENTSHUD_KEY_ALIAS`/`_PASSWORD` 覆盖。

### Mac 签名与公证（Developer ID + notarytool）

`mac.yml` 会在**配置了下列 Secrets 时**对 `.app` 做 Developer ID 签名（hardened runtime）、对 DMG
做公证 + stapler 装订，下载后首次打开**不再有 Gatekeeper 提示**。**未配置时自动回退到 ad-hoc 签名、
不公证**（仍能构建，方便 fork）——逻辑全在 `build-app.sh` / `make-dmg.sh` 里按 `CODESIGN_IDENTITY`
是否存在分支。

需要配置的仓库 Secrets（Settings → Secrets and variables → Actions）：

| Secret | 内容 | 怎么拿 |
|--------|------|--------|
| `MAC_CERT_P12_BASE64` | Developer ID Application 证书（含私钥）的 `.p12`，base64 | 钥匙串导出证书+私钥为 `.p12`，`base64 -i cert.p12 \| pbcopy` |
| `MAC_CERT_PASSWORD` | 上面 `.p12` 的导出密码 | 导出时自己设的 |
| `MAC_NOTARY_KEY_BASE64` | App Store Connect API Key 的 `.p8`，base64 | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `MAC_NOTARY_KEY_ID` | 该 API Key 的 Key ID | 生成密钥时显示 |
| `MAC_NOTARY_ISSUER_ID` | Issuer ID（UUID） | App Store Connect → Integrations 页顶部 |
| `MAC_SIGN_IDENTITY` | *可选*：`Developer ID Application: 名字 (TEAMID)` | 留空则从钥匙串自动识别 |

获取材料：

- **证书**：[developer.apple.com](https://developer.apple.com/account/resources/certificates) → Certificates → `+`
  → **Developer ID Application**（需 Account Holder/Admin）。装到钥匙串后，右键证书「导出」为 `.p12`。
- **API Key**：App Store Connect → Users and Access → Integrations → **App Store Connect API** →
  生成密钥（角色 Developer 即可）。`.p8` **只能下载一次**，记下 Key ID 与 Issuer ID。

> 想用 Apple ID + app-specific password 而非 API Key？把 `mac.yml` 里 `notarytool submit` 的
> `--key/--key-id/--issuer` 换成 `--apple-id/--password/--team-id` 即可。

---

## 发版（维护者）

```bash
scripts/release.sh                 # 默认 patch：bump + tag + 算 sha + 改 formula + 推送
scripts/release.sh minor           # 或 major / 指定 X.Y.Z
scripts/release.sh patch --dry-run # 预览，不改动
```

脚本会：bump `server/package.json`（并同步 package-lock 版本）→ 提交并打 `vX.Y.Z` 标签 → 推送
→ 下载该 tag 的 GitHub tarball 算 `sha256` → 改写 `Formula/agents-hud.rb` 的 `url`/`sha256`/`version`
→ 提交推送。该 `v*` 标签**同时**触发 Android 与 macOS 两条 CI，分别发布签名 APK 与通用 DMG。之后：

- 服务端：本机 `agents-hud update`（或 `brew upgrade agents-hud`）。
- App：每小时自检，发现新版自动弹窗更新。

---

## 路线图

- [x] Mac 端用 Homebrew 部署 server（`brew services` 常驻）
- [x] Android 自动构建（CI 在 `v*` 标签上构建签名 APK 并发布到 Release）
- [x] Android 应用内自动更新（每小时检测 Release 新版本 → 弹窗 → 下载安装）
- [x] Mac 菜单栏 App（SwiftUI 状态项 + 毛玻璃面板，同机直连）+ CI 在 `v*` 标签产出通用 DMG
- [x] Mac App 的 Developer ID 签名 + Apple 公证（CI 已接，配好 Secrets 即生效）
- [ ] Gemini 等第二个 provider 接入
