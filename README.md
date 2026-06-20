# AgentsHUD

一个跑在 **Android 手机**上的 Claude Code 状态面板：竖排红绿灯一眼看清整体状态，实时展示
每个会话的运行状态、当前调用的工具、上下文剩余、token 消耗、5 小时 / 7 天套餐用量与当前模型。
手机扫描电脑终端里的二维码，在**局域网**内连接，实时刷新。

> 第一版聚焦 Claude Code；数据层是可插拔的 `Provider`，Gemini 等可作为第二个 provider 接入。

```
┌──────────────┐   局域网 WebSocket    ┌──────────────────────────┐
│  Android App │  ◀────────────────────│  server (本机 Node)        │
│  (Compose)   │   扫码配对             │  读 ~/.claude 会话数据      │
└──────────────┘                       │  + Hooks + statusLine 上报 │
                                       └──────────────────────────┘
```

## 两个部分

| 目录 | 说明 |
|------|------|
| [`server/`](server/) | 电脑端 Node + TypeScript 服务：采集 `~/.claude` 数据、状态机、WebSocket、终端二维码、安装 hook |
| [`android/`](android/) | Kotlin + Jetpack Compose App：扫码、WebSocket 客户端、全屏 HUD 面板 |

---

## 快速开始

### 1. 启动电脑端服务

**方式 A：Homebrew（推荐，常驻 + 开机自启）**

```bash
brew install node                              # 运行依赖（已装可跳过）
brew tap yinshuai0324/agents-hud https://github.com/yinshuai0324/homebrew-agents-hud
brew install agents-hud
brew services start agents-hud                 # launchd 托管，崩溃自动重启
# 日志：$(brew --prefix)/var/log/agents-hud.log
# 仅前台跑一次：agents-hud
```

> 尚未发布独立 tap 仓库时，可用本机临时 tap：
> `brew tap-new yinshuai0324/agents-hud --no-git` 后把 `packaging/homebrew/agents-hud.rb`
> 拷到 `$(brew --repository)/Library/Taps/yinshuai0324/homebrew-agents-hud/Formula/` 再
> `brew install yinshuai0324/agents-hud/agents-hud`。

**方式 B：源码直接跑（开发）**

```bash
cd server
npm install
npm start        # 开发；npm run build && npm run start:prod 为编译后运行
```

终端会打印一个二维码和连接信息：

```
   WebSocket : ws://192.168.8.175:4317
   Host      : my-macbook
   Auth      : off
```

### 2.（推荐）安装 Claude Code hooks + statusLine

不装也能用（靠文件监听推断状态），但装上后状态最准确、最实时，且能拿到**官方用量、上下文剩余、
会话标题、当前模型、实时工具调用**：

```bash
cd server
npm run setup-hooks        # 写入 ~/.claude/settings.json（自动备份）
# 之后重启正在运行的 Claude Code 会话即可生效
npm run uninstall-hooks    # 需要时干净移除
```

它会在这些事件上注册一个 fire-and-forget 的回调（不阻塞 Claude）：
`UserPromptSubmit / PreToolUse / PostToolUse / Stop / StopFailure / Notification / SessionStart / SessionEnd`，
并接管 statusLine 以获取 Claude 自己的 `rate_limits` / `context_window` / `model` 等。

### 3. 构建并安装 Android App

需要 **Android Studio**（自带 JDK，会自动下载 SDK/Gradle）：

```bash
# 用 Android Studio 打开 android/ 目录，等待 Gradle 同步后点 Run
# 或命令行（需本机有 JDK 17）：
cd android
./gradlew assembleDebug
# APK 输出：android/app/build/outputs/apk/debug/app-debug.apk
```

App 为全屏常驻（kiosk）设计：隐藏状态栏/导航栏、屏蔽返回退出、适配挖孔屏，适合做一块常亮看板。

### 4. 配对

App 首次启动进入扫码页 → 对准电脑终端里的二维码 → 自动连接并显示面板。配对信息会被保存，
下次启动自动重连。面板右上角“重扫”可重新配对。

> 手机与电脑必须在**同一局域网**。

---

## 五种状态

红绿灯每盏对应一个会话状态（Hooks 实时上报 + 文件监听兜底 + 空闲计时）：

| 颜色 | 状态 | 触发 |
|------|------|------|
| 🔴 红 | **出错** error | `StopFailure`（运行因错误中止）|
| 🟠 橙 | **审批** notify | `Notification`（等你批准权限 / 通知）|
| 🔵 蓝 | **等候** waiting | `Stop`（答完一轮，轮到你）|
| 🟡 黄 | **工作** working | `UserPromptSubmit` / `PreToolUse` / `PostToolUse` / `SessionStart`（或文件正在写入）|
| 🟢 绿 | **空闲** quiet | 等候后超过 `quietAfterMs` 仍无新活动 |

- 顶部大红绿灯亮哪盏由优先级决定：**出错 > 审批 > 等候 > 工作 > 空闲**；切换时先呼吸几下再常亮，
  切到“审批/等候”时还有一次全屏呼吸提醒。
- **出错 / 审批不会自动褪色**——它们是未处理的事项，会一直亮到该会话有新活动为止；工作超时
  (`workingTimeoutMs`) 降为等候，等候超时 (`quietAfterMs`) 降为空闲。
- 未安装 hook 时仅靠 `~/.claude/projects/**/*.jsonl` 的写入与 mtime 推断（只能区分 工作/等候/空闲），
  可能有几秒延迟。
- 手机**未连接**时：红绿灯熄灭、状态计数归零、其余数据变灰并显示“更新于 X 前”，避免把过期数据
  误当实时。

---

## 会话列表显示什么

每条会话展示：

- **标题**：会话名 `session_name`（来自 statusLine），没有时回退为 3 级路径，如 `project/agents-status/server`
- **token 消耗** + **上下文剩余**：`928.3k tokens · 上下文 273.4k · 剩 73%`
- **实时工具调用**（工作时，独占一行）：`Bash: npm run build`、`Edit UsageBar.kt` 等

左侧信息列还有：套餐 + 实时/估算标记、5 小时 / 7 天用量进度条、今日消耗、当前模型。

---

## 用量与上下文百分比

- **5 小时 / 7 天用量**：优先用 Claude statusLine 上报的官方 `rate_limits`（标记“实时”），
  没有时用 ccusage 风格的本地 5 小时滚动窗口估算（标记“估算”，7 天则不显示）。官方值会
  **持久化到 `~/.claude/.agentshud-usage.json`** 并在其重置时间前一直有效，因此服务端重启或
  手机长时间息屏后重连，用量不会清空。
- **上下文剩余**：优先用 statusLine 的 `context_window.remaining_percentage`（官方精确值），
  没有时用启发式估算（占用超过 200k 判定为 1M 窗口，否则按 200k）。
- 本地估算的分母（token 预算）无法从磁盘精确得到，可通过环境变量配置（见下）。

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
  "totals": { "todayTokens": 2700000 },
  "ts": "..."
}
```

服务端接口：`GET /healthz`、`GET /api/snapshot`、`POST /hooks`、`POST /statusline`、`WS /`。

---

## 路线图

- [x] Mac 端用 Homebrew 部署 server（`brew services` 常驻）—— 见上方“方式 A”
- [ ] Android 自动构建 + 应用内自动更新
- [ ] Gemini 等第二个 provider 接入
