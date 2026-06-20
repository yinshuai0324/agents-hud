# CC 信号塔 / CC Signal Tower

一个跑在 **Android 手机**上的 Claude Code 状态健康面板：红绿灯显示运行状态，实时展示
token 消耗、5 小时滚动用量、以及每个会话/项目的状态。手机扫描电脑终端里的二维码，在
**局域网**内连接，实时刷新。

> 第一版聚焦 Claude Code；数据层是可插拔的 `Provider`，Gemini 可作为第二个 provider 接入。

```
┌─────────────┐   局域网 WebSocket    ┌──────────────────────┐
│  Android App │  ◀───────────────────│  server (本机 Node)   │
│  (Kotlin)    │   扫码配对            │  读 ~/.claude 数据     │
└─────────────┘                       │  + Claude Code Hooks  │
                                      └──────────────────────┘
```

## 两个部分

| 目录 | 说明 |
|------|------|
| [`server/`](server/) | 电脑端 Node + TypeScript 服务：采集 `~/.claude` 数据、状态机、WebSocket、终端二维码、安装 hook |
| [`android/`](android/) | Kotlin + Jetpack Compose App：扫码、WebSocket 客户端、红绿灯面板 UI |

---

## 快速开始

### 1. 启动电脑端服务

```bash
cd server
npm install
npm start
```

终端会打印一个二维码和连接信息：

```
   WebSocket : ws://192.168.8.175:4317
   Host      : my-macbook
   Auth      : off
```

### 2. （推荐）安装 Claude Code hooks

不装也能用（靠文件监听推断状态），但装上后“工作 / 等候 / 沉寂”状态最准确、最实时：

```bash
cd server
npm run setup-hooks        # 写入 ~/.claude/settings.json（自动备份）
# 之后重启正在运行的 Claude Code 会话即可生效
npm run uninstall-hooks    # 需要时干净移除
```

它会在这些事件上注册一个 fire-and-forget 的回调（`async`，不阻塞 Claude）：
`UserPromptSubmit / PreToolUse / PostToolUse / Stop / StopFailure / Notification / SessionStart / SessionEnd`。

### 3. 构建并安装 Android App

需要 **Android Studio**（自带 JDK，会自动下载 SDK/Gradle）：

```bash
# 用 Android Studio 打开 android/ 目录，等待 Gradle 同步后点 Run
# 或命令行（需本机有 JDK 17）：
cd android
./gradlew assembleDebug
# APK 输出：android/app/build/outputs/apk/debug/app-debug.apk
```

### 4. 配对

App 首次启动进入扫码页 → 对准电脑终端里的二维码 → 自动连接并显示面板。配对信息会被
保存，下次启动自动重连。面板右上角“重扫”可重新配对。

> 手机与电脑必须在**同一局域网**。

---

## 状态是怎么判定的

红绿灯三色对应会话状态（参考主流开源做法 = Hooks 实时上报 + 文件监听兜底 + 空闲计时）：

| 颜色 | 状态 | 触发 |
|------|------|------|
| 🔴 红 | **等候** waiting | `Stop` / `Notification`（答完一轮 / 等权限 / 空闲提醒）|
| 🟡 黄 | **工作** working | `UserPromptSubmit` / `PreToolUse` / `PostToolUse`（或文件正在写入）|
| 🟢 绿 | **沉寂** quiet | 进入等候后超过 `quietAfterMs` 仍无新活动 |

大红绿灯亮哪盏由优先级决定：**等候(红) > 工作(黄) > 沉寂(绿)**。

未安装 hook 时，仅靠 `~/.claude/projects/**/*.jsonl` 的写入与 mtime 推断，可能有几秒延迟。

---

## 5H 用量百分比说明

“5H 用量 · X%” 采用 ccusage 风格的 5 小时滚动窗口（按首条活动整点对齐，窗口 5 小时，
`剩 X 小时 X 分` = 距窗口结束时间）。

百分比的**分母（token 预算）无法从磁盘精确得到**（取决于你的订阅档位），因此可配置：

```bash
# 单位：token；默认 2,000,000
CC_SIGNAL_TOKEN_BUDGET=4000000 npm start
# 或按“历史最大 5h 块”为基准
CC_SIGNAL_PERCENT_BASIS=maxBlock npm start
```

---

## 服务端环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `CC_SIGNAL_PORT` | `4317` | HTTP/WebSocket 端口 |
| `CC_SIGNAL_HOST` | `0.0.0.0` | 绑定地址（保持 0.0.0.0 才能被手机访问）|
| `CC_SIGNAL_TOKEN` | 空 | 设置后启用共享 token 鉴权（二维码会带上）|
| `CC_SIGNAL_TOKEN_BUDGET` | `2000000` | 5H 百分比分母 |
| `CC_SIGNAL_PERCENT_BASIS` | `budget` | `budget` 或 `maxBlock` |
| `CC_SIGNAL_QUIET_AFTER_MS` | `300000` | 等候→沉寂 的空闲阈值 |
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
  "status": { "waiting": 2, "working": 1, "quiet": 2, "dominant": "waiting", "total": 5 },
  "usage5h": { "percent": 6, "tokensUsed": 123456, "tokenBudget": 2000000,
               "resetInMinutes": 211, "blockStart": "...", "blockEnd": "...", "burnRatePerMin": 5750 },
  "sessions": [ { "id": "...", "project": "kaifa/fuwuqi", "cwd": "/Users/...",
                  "state": "working", "model": "claude-opus-4-8", "lastActivity": 0, "tokens": 12345 } ],
  "totals": { "todayTokens": 0 },
  "ts": "..."
}
```

服务端接口：`GET /healthz`、`GET /api/snapshot`、`POST /hooks`、`WS /`。
