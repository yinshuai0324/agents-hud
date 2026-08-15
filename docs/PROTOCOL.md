# AgentsHUD 通信协议

所有客户端（Android、ESP32 表盘、Mac 菜单栏 UI）共享同一个数据源：Mac App 内置的
server（默认 `0.0.0.0:4317`）。本文件是 wire 契约的基准 —— 改动任何字段前先改这里，
并同步 Android `data/Snapshot.kt` 与固件 `esp32/main/net_ws.c` 的解析。

## 1. HTTP / WebSocket 端点

| 端点 | 用途 |
| --- | --- |
| `GET /healthz` | 存活检查 `{"ok":true}`（免鉴权） |
| `GET /api/snapshot` | 完整 Snapshot（REST，首屏/轮询） |
| `POST /hooks` | Claude Code hook 事件（`~/.claude/agents-hud/cc-signal-hook.sh` 转发） |
| `POST /statusline` | Claude Code statusLine 载荷（携带官方 5h/7d 真实用量） |
| `WS /` | Snapshot 推送流（连上先发一次，变化即推；Android/本机 UI 用） |
| `WS /device` | ESP32 表盘专用紧凑流（见 §3） |

鉴权：`CC_SIGNAL_TOKEN` 非空时，query `?token=` 或 `Authorization: Bearer` 二选一。
空 token 表示关闭鉴权。

## 2. Snapshot（完整 wire 模型）

权威定义：`mac/Sources/AgentsHUDCore/Models/Snapshot.swift`（与退役前的
`server/src/state.ts:16-56` 字节兼容）。要点：

```jsonc
{
  "provider": "claude",
  "plan": "Max (5x)",
  "model": "Fable 5",              // 最近活跃会话的模型显示名
  "status": { "waiting":0, "working":1, "quiet":1, "notify":0, "error":0,
              "dominant":"working", "total":2 },
  "usage5h": { "percent":27, "tokensUsed":261127, "tokenBudget":2000000,
               "resetInMinutes":221, "blockStart":"2026-07-16T15:00:00.000Z",
               "blockEnd":"...", "burnRatePerMin":1188, "source":"live" },
  "usage7d": { "percent":13, "resetInMinutes":6540 },   // 无数据时为 null
  "today": { "tokens":24242, "cacheWriteTokens":34663, "costUSD":8.52 },
  "providers": [                                  // 用户勾选的数据源，稳定顺序
    { "provider":"claude", "plan":"Max (5x)", "model":"Fable 5",
      "usage5h": { "percent":27, "source":"live", "...":"..." },
      "usage7d": { "percent":13, "resetInMinutes":6540 }, "today": { "...":"..." } },
    { "provider":"codex", "plan":"Pro", "model":"gpt-5.6-sol",
      "usage5h": { "percent":0, "source":"estimate", "...":"..." },
      "usage7d": { "percent":34, "resetInMinutes":6454 }, "today": { "...":"..." } }
  ],
  "sessions": [ { "id":"...", "project":"...", "cwd":"...", "state":"working",
                  "model":"claude-fable-5", "lastActivity":1784217629000,
                  "tokens":928300, "contextTokens":273405,
                  "contextLeftPercent":73, "currentTool":"Bash: npm run build" } ],
  "outputTokensPerSec": 84,
  "ts": "2026-07-16T16:00:00.000Z"
}
```

`provider` 为当前最近活跃的数据源，现支持 `claude`、`codex` 与 `gemini`。Codex 数据由 Mac
直接读取 `~/.codex/sessions/**/*.jsonl`；Gemini 读取 `~/.gemini/tmp/*/chats/*.json`，并兼容
本机 Antigravity 的活动记录。所有来源均不由 Agents HUD 调用官方 API。为保持旧客户端兼容，
顶层用量、套餐与模型始终对应勾选来源中当前最近活跃的 provider；三个来源可任意组合（至少
保留一个）。多来源客户端使用 `providers[]` 同时展示，旧客户端继续读取顶层字段。

- `ts` 为带毫秒的 ISO8601；`usage7d`、`blockStart/blockEnd` 缺失时输出显式 `null`。
- 配对二维码载荷：`{"v":1,"url":"ws://<lan-ip>:4317","token":"...","name":"<host>"}`。

## 3. /device 协议（ESP32 表盘）

单行 JSON 文本帧，以 `"t"` 字段分型；**未知 `t` 双方静默忽略**（未来扩展位：
`"t":"anim"` 动画资源、`"t":"text"` 自定义文字、`"t":"cfg"` 远程配置）。

```jsonc
// 设备 → 服务器（连上即发一次；连接 query 里也带同样字段作兜底）
{"t":"hello","proto":1,"id":"F232","board":"ws175","fw":"0.2.0"}

// 服务器 → 设备（hello 应答）
{"t":"hi","name":"MacBook-Pro","ver":"0.2.0"}

// 服务器 → 支持文字卡片的设备：显示文字 / 立即恢复用量页
{"t":"text","title":"午休","body":"12:00–13:30 请勿打扰","hold":0}
{"t":"text","clear":true,"title":"","body":"","hold":1}

// 服务器 → 设备：只控制屏幕电源，WiFi/WebSocket 保持在线
{"t":"display","on":false}
{"t":"display","on":true}

// 服务器 → 设备：紧凑快照（3 秒定推兼心跳 + 变化即推）
{"t":"snap","p5":52,"r5":161,"p7":27,"r7":5231,"tt":163962,"bu":15163,"lv":1,
 "w":1,"n":2,"wa":0,"e":0,"q":0,"to":3,"d":"working","m":"Fable 5",
 "pl":"Max (5x)","pr":"claude","h":"MacBook-Pro"}
```

紧凑字段与旧 BLE daemon 完全一致：`p5/r5` 5h 用量%/重置分钟，`p7/r7` 7 天（可缺省），
`tt` 今日 token，`bu` 每分钟 token，`lv` 是否官方实时数据，`w/n/wa/e/q/to` 各状态会话数，
`d` 主导状态，`m` 模型（≤24 字符），`pl` 套餐（≤24 字符），`pr` 当前来源
（`claude|codex|gemini`，固件据此显示平台图标），`h` 主机名。

连接 URL：`ws://<host>:4317/device?token=..&id=F232&board=ws175&fw=0.2.0`。
固件端数据超过 30 秒未到显示「数据超时」。

文字定时任务由 Mac 按本地时间执行。时间段开始时发送 `hold:0`，结束时发送
`clear:true`；结束早于开始表示跨午夜。Mac 从睡眠恢复后会重新计算当前有效时段，避免仅依赖
设备端倒计时产生漂移。当前 `sdd154` 固件支持文字卡片；其他板型以能力表为准。

### 动图可行性

`ws175` 具备 16MB Flash、8MB PSRAM 和 7MB SPIFFS，并且固件已有逐帧动画渲染器，适合支持
远程动画。可靠方案是由 Mac 将 GIF 解码、缩放并转成板型专用 RGB565 帧包，再分块传输到设备
存储；不应把 GIF 二进制塞进 JSON。`sdd154` 也能从 LittleFS 流式播放缩小后的帧包，但需限制
分辨率、帧率和文件大小。当前两块板的 `remoteAnimation` 能力仍保持关闭，直到分块上传、校验、
存储淘汰和播放中断恢复完整实现，避免 UI 宣称支持但固件无法可靠播放。

### 屏幕电源策略

`display` 命令由 `ws175` 与 `sdd154` 支持。关屏只关闭 AMOLED 亮度或 TFT 背光，设备仍维持
WiFi 和 WebSocket，因而能立即接收亮屏命令。Mac 会合并“定时关屏时段”和“电脑锁屏联动”两类
原因：任一原因存在时保持关屏，全部解除后才亮屏；设备重连时会重新同步当前策略。

## 4. 配网（BLE 或 USB；配网完成后统一通过 WiFi 通信）

设备无配置（或长按 BOOT ≥3 秒 / 串口发 `p`）时进入配对模式，广播名
`AgentsHUD-XXXX`（WiFi MAC 后两字节）。

| UUID（后缀） | 属性 | 内容 |
| --- | --- | --- |
| `41485544-6469-616c-2d64-617461000001` | service | — |
| `...0003` | WRITE | `{"v":1,"ssid":"..","pw":"..","url":"ws://ip:4317","token":"..","name":"MacBook-Pro"}`（单写 ≤512B，需 MTU 512） |
| `...0004` | READ / NOTIFY | `{"st":"idle\|connecting\|got_ip\|ws_ok\|bad_pass\|ap_not_found\|server_fail","ip":"192.168.1.42"}` |
| `...0005` | READ | `{"board":"ws175","fw":"0.2.0","id":"F232"}` |

流程：Mac 扫描（按 service UUID）→ 连接 → 读 `0005` → 写 `0003` → 跟随 `0004`
通知直到 `ws_ok` / 失败码。`ws_ok` 后设备保留 BLE 约 10 秒随后关闭并释放内存。

## 4b. USB 串口配网

115200 波特率，双向单行 JSON（设备启动日志等非 JSON 行忽略）。状态码与 BLE
`0004` 完全一致，Mac 端两条通道共享判断逻辑。

```jsonc
// Mac → 设备
{"t":"info?"}                                                   // 探测（确认是 AgentsHUD 固件）
{"t":"prov","v":1,"ssid":"..","pw":"..","url":"ws://ip:4317","token":"..","name":".."}
{"t":"reset"}                                                   // 清配网并重启

// 设备 → Mac
{"t":"info","board":"sdd154","fw":"0.2.0","id":"315D"}
{"t":"st","st":"connecting|got_ip|ws_ok|bad_pass|ap_not_found|server_fail","ip":"192.168.1.42"}
```

另保留单字符控制台命令：`r` 重启、`p` 清配网重启（ESP32 板还有 `b` 进下载模式；
NodeMCU 型自动复位电路的板子不需要 `b`，esptool 直接 `default_reset`）。

## 5. mDNS 重发现

Mac App 通过 Bonjour 发布 `_agentshud._tcp`（SRV 指向 4317，TXT：`name`、`ver`）。
设备 WS 连不上超过 ~30 秒时查询该服务，TXT `name` 与配网时的主机名一致者优先，
命中后把新 URL 写回 NVS 并重连 —— Mac 换 IP 无需重新配网。

## 6. 固件分发（USB 烧录，无 OTA）

Release 资产 `agents-hud-<ver>-esp32-<board>.zip`（`.github/workflows/esp32.yml`）：
`bootloader.bin` + `partition-table.bin` + `agents_hud_amoled.bin` + `manifest.json`
（offset 取自 `flasher_args.json`，含每个文件的 sha256）。Mac App「设备」窗口：
检查最新 → 下载校验 → 串口发 `b` 进下载模式 → esptool 分块（364KB）写入逐块验
hash → hard reset。
