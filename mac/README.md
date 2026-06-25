# Agents-HUD（macOS 菜单栏）

把 Agents-HUD 看板搬进 **Mac 菜单栏**：菜单栏一个状态色圆点，点击弹出悬浮窗，显示与
Android App 相同的信息（套餐、5 小时 / 7 天用量、当前模型、今日消耗、速度、状态计数、会话列表）。

server 与本 App 跑在**同一台 Mac**，所以**无需扫码配对**——App 直接连本机
`ws://127.0.0.1:4317/`，复用 server 已有的 `Snapshot` 数据契约。

```
菜单栏:  ●  ← 主导状态色（黄=工作 / 蓝=等候 / 橙=审批·闪烁 / 红=出错 / 绿=空闲 / 灰=未连接）
点击 ▼  悬浮窗（上图同款面板）
```

## 安装（推荐：下载 DMG）

从 [GitHub Releases](https://github.com/yinshuai0324/agents-hud/releases/latest) 下载最新的
`agents-hud-*-mac.dmg`（通用二进制，Apple Silicon / Intel 通吃），打开后把 **Agents-HUD** 拖进
「应用程序」即可。DMG 经 Apple 公证（Developer ID + notarization），正常双击打开、无 Gatekeeper 提示。

> 若你装的是**自行 ad-hoc 构建**（非 Release 的公证版）的 App，首次打开可能提示「无法验证开发者」，
> 右键点 App → 打开 → 再点「打开」一次即可，或 `xattr -dr com.apple.quarantine /Applications/Agents-HUD.app`。

前置：macOS 13+；本机已在跑 Agents-HUD server（`brew services start agents-hud` 或
`cd ../server && npm start`）。

## 从源码构建

需 Xcode Command Line Tools（`xcode-select --install`）：

```bash
cd mac
bash build-app.sh          # 产出 Agents-HUD.app（菜单栏常驻、无 Dock 图标）
open Agents-HUD.app        # 启动；也可拖进「应用程序」

UNIVERSAL=1 bash build-app.sh   # 通用二进制（arm64 + x86_64，CI 用这个）
bash make-dmg.sh                # 把 .app 打成 DMG
```

开发期可直接跑：`swift run`。

> 想开机自启：把 `Agents-HUD.app` 拖进「系统设置 → 通用 → 登录项」。

## 交互

- **左键**点圆点 → 展开/收起面板。
- **右键**（或 Control+点击）圆点 → 菜单：刷新 / 退出。

## 配置

默认连本机 `127.0.0.1:4317`、无 token（与 server 默认一致），开箱即连。改了端口或给 server 设了
`CC_SIGNAL_TOKEN` 时，用 `defaults` 写入后重启 App：

```bash
defaults write com.ooimi.agents.hud.mac port  -int 4318
defaults write com.ooimi.agents.hud.mac token -string "your-token"
defaults write com.ooimi.agents.hud.mac host  -string "127.0.0.1"
```

## 结构

| 文件 | 说明 |
|------|------|
| `Sources/AgentsHUD/Models.swift` | 镜像 server 的 `Snapshot`（宽容解码） |
| `Sources/AgentsHUD/SignalClient.swift` | WebSocket + REST 首屏 + 自动重连 + 1Hz 计时 |
| `Sources/AgentsHUD/Theme.swift` | 配色与状态色（移植自 Android `Theme.kt`） |
| `Sources/AgentsHUD/Components.swift` | 用量条 + 格式化工具 |
| `Sources/AgentsHUD/PanelView.swift` | 悬浮面板 + 毛玻璃背景（镜像 `DashboardScreen.kt`） |
| `Sources/AgentsHUD/AgentsHUDApp.swift` | `@main` + `NSStatusItem`（左键面板 / 右键菜单）+ 状态色圆点 |
| `build-app.sh` / `make-dmg.sh` | 编译打包成 `.app` / 打成 DMG |

> 验证用：`swift build -c release && .build/release/AgentsHUD --render-test out.png`
> 会拉取本机快照、把面板离屏渲染成 PNG（菜单栏弹窗无法从命令行截图）。
