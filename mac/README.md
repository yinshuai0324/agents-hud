# Agents-HUD（macOS App）

AgentsHUD 的中枢：一个**常规窗口应用**（Dock 图标、⌘Tab、标准应用菜单），主窗口带侧边栏
（设备 / 设置），是设备控制中心；菜单栏图标保留为快速一瞥入口，**左键**弹出用量概览面板，
**右键**出菜单（打开主窗口 / 通知开关 / 刷新 / 退出）。

数据服务不再依赖外部进程：原 Node server 已用 Swift 重写为 `AgentsHUDCore` 模块并**内置进
App**（FlyingFox 承载 HTTP + WebSocket，监听 `0.0.0.0:4317`，供本机面板、手机与桌面表盘共用）。
brew / Node 那条路已弃用；若启动时发现旧 brew 服务占着 4317 端口，App 会弹窗提示
`brew services stop agents-hud` 后重试。

安装（DMG 下载）、手机配对、整体架构见[根 README](../README.md)；HTTP/WS/BLE/串口协议细节见
[`docs/PROTOCOL.md`](../docs/PROTOCOL.md)。本文面向想**从源码构建或修改这个 App** 的人。

## 功能一览

- **设备（主窗口侧边栏）**：已连接设备列表（选中一行展开控制面板）、BLE 配网向导、
  USB 串口配网（无蓝牙的 ESP8266 板走这条通道）、USB 固件烧录（内置 esptool，按板型自动选
  复位方式）。
- **控制面板（选中在线设备后）**：每设备「用量概览」推送开关；「显示文字」定向下发文字卡片
  （标题 + 正文 + 停留时长，超时后回到用量页）。「动画」「定时任务」目前只是占位入口，
  标着**开发中，尚未实现**。
- **设置**：内置服务状态（端口 / 鉴权 / 端口冲突提示）、Claude Code 钩子一键安装 / 卸载
  （脚本装到 `~/.claude/agents-hud/`，路径与旧 Node 安装器一致，老配置无需重装）、
  手机配对二维码、Sparkle 应用自更新。
- **系统通知**：会话「轮到你 / 等审批 / 出错」时弹横幅 + 提示音，点通知回到主窗口
  （菜单栏右键菜单可开关）。

## 从源码构建

需 Xcode Command Line Tools（`xcode-select --install`），macOS 13+：

```bash
cd mac
bash build-app.sh          # 产出 Agents-HUD.app（本机架构）
open Agents-HUD.app        # 启动；也可拖进「应用程序」

UNIVERSAL=1 bash build-app.sh   # 通用二进制（arm64 + x86_64，CI 用这个）
bash make-dmg.sh                # 把 .app 打成 DMG（要先跑 build-app.sh）
```

开发期可直接 `swift run`（此时不走 App bundle，系统通知会跳过）。

几个可选环境变量（详见 `build-app.sh`）：

- `VERSION`：写入 Info.plist 的版本号（默认取仓库根 `VERSION` 文件）。
- `CODESIGN_IDENTITY`：Developer ID 签名 + hardened runtime（CI 发版用；不设则 ad-hoc 签名，
  本地够用）。
- `SPARKLE_ED_PUBLIC_KEY` / `SPARKLE_FEED_URL`：Sparkle 自更新公钥与 feed；不设公钥则该构建
  禁用应用内更新（设置页会说明）。
- 固件烧录依赖打包进 App 的 esptool：先跑 `../scripts/fetch-esptool.sh` 下载到 `Vendor/esptool`，
  `build-app.sh` 会自动带上；没有它 App 也能跑，只是烧录功能不可用。

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--headless` | 只跑内置数据服务，不起任何 UI（端口可用 `CC_SIGNAL_PORT` 覆盖），wirecheck 对拍与调试用，Ctrl-C 退出 |
| `--render-test [out.png]` | 拉本机快照、把概览面板离屏渲染成 PNG 后退出（菜单栏弹窗无法从命令行截图） |
| `--render-icon [out.png]` | 渲染 1024² 图标母版（配合 `make-icon.sh` 重做 AppIcon.icns） |

## 配置

服务端配置沿用 `CC_SIGNAL_*` 环境变量（`CC_SIGNAL_PORT` / `CC_SIGNAL_HOST` /
`CC_SIGNAL_TOKEN` / `CC_SIGNAL_CLAUDE_DIR` 等，完整清单见
`Sources/AgentsHUDCore/Config.swift`）。环境变量优先，其次是 UserDefaults，最后是默认值。

用 `defaults` 写 UserDefaults 后重启 App 生效（domain 即 bundle id）：

```bash
# 内置服务
defaults write com.ooimi.agents.hud.mac serverPort -int 4318
defaults write com.ooimi.agents.hud.mac authToken  -string "your-token"

# 概览面板的本机 WS 客户端（一般不用改，跟服务保持一致即可）
defaults write com.ooimi.agents.hud.mac port  -int 4318
defaults write com.ooimi.agents.hud.mac token -string "your-token"
defaults write com.ooimi.agents.hud.mac host  -string "127.0.0.1"
```

## 结构

```
Sources/
├─ AgentsHUDCore/            # 纯逻辑，无 AppKit（可单测、可 headless 跑）
│  ├─ Engine/                # StateEngine 状态机 + 5h/今日用量 + 定价 + 套餐识别
│  ├─ Providers/             # ClaudeProvider：读 ~/.claude 的 JSONL 会话记录
│  ├─ Server/                # HUDServer（FlyingFox HTTP+WS）+ DeviceGateway（设备通道
│  │                         #   注册 / 定向下发 / 每设备用量开关）+ CompactSnapshot
│  ├─ Config.swift           # 配置装载（env → UserDefaults → 默认值）
│  ├─ HooksInstaller.swift   # Claude Code 钩子安装 / 卸载
│  ├─ Pairing.swift          # 手机配对载荷（二维码内容）
│  └─ Bonjour.swift          # _agentshud._tcp 服务发布
└─ AgentsHUD/                # App 本体（AppKit + SwiftUI）
   ├─ AppDelegate.swift      # 应用生命周期、菜单栏图标、主菜单、通知回调
   ├─ MainWindowController / MainView   # 主窗口 + 侧边栏（设备 / 设置）
   ├─ MenuBarPanel / PanelView          # 菜单栏左键弹出的概览面板
   ├─ ServerController.swift # 拥有内置服务：起停、端口冲突检测、设备列表
   ├─ SignalClient.swift     # 概览面板的本机 WS 客户端（自动重连 + 0.5s 计时）
   ├─ Devices/               # BLE 配网、USB 串口配网、esptool 烧录、固件检查、
   │                         #   ControlPanel（用量开关 + 文字下发）
   ├─ Settings/              # 设置页 + 配对二维码
   ├─ Updates/               # Sparkle 自更新封装
   └─ Notifier / Theme / Components / Models / RenderTest / AppIcon
Tests/AgentsHUDCoreTests/    # 单元测试（见下）
```

## 测试

```bash
cd mac
swift test
```

- `Usage5hTests`：5 小时用量计算的边界用例。
- `GoldenWireTests`：与旧 Node 实现的**黄金对拍**——固定 fixture 的期望值由原 Node 代码生成
  （`../scripts/gen-golden.mjs`），任何 token 数学上的分歧都是移植 bug。

线上级的 wire 兼容验证另有 `../scripts/wirecheck.sh`（两个 server 读同一 `~/.claude`，
diff `/api/snapshot`），用法见脚本头部注释。

## 已知限制

- 无边框主窗口的侧边栏尚未延伸到标题栏后（访达那种效果），窗口样式待后续重构。
- 控制面板里的「动画」「定时任务」为占位入口，功能未实现。
