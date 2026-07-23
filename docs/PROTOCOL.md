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
  "sessions": [ { "id":"...", "project":"...", "cwd":"...", "state":"working",
                  "model":"claude-fable-5", "lastActivity":1784217629000,
                  "tokens":928300, "contextTokens":273405,
                  "contextLeftPercent":73, "currentTool":"Bash: npm run build" } ],
  "outputTokensPerSec": 84,
  "ts": "2026-07-16T16:00:00.000Z"
}
```

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

// 服务器 → 设备：紧凑快照（3 秒定推兼心跳 + 变化即推）
{"t":"snap","p5":52,"r5":161,"p7":27,"r7":5231,"tt":163962,"bu":15163,"lv":1,
 "w":1,"n":2,"wa":0,"e":0,"q":0,"to":3,"d":"working","m":"Fable 5",
 "pl":"Max (5x)","h":"MacBook-Pro"}
```

紧凑字段与旧 BLE daemon 完全一致：`p5/r5` 5h 用量%/重置分钟，`p7/r7` 7 天（可缺省），
`tt` 今日 token，`bu` 每分钟 token，`lv` 是否官方实时数据，`w/n/wa/e/q/to` 各状态会话数，
`d` 主导状态，`m` 模型（≤24 字符），`pl` 套餐（≤24 字符），`h` 主机名。

连接 URL：`ws://<host>:4317/device?token=..&id=F232&board=ws175&fw=0.2.0`。
固件端数据超过 30 秒未到显示「数据超时」。

## 4. BLE 配网（仅配网，不再推数据）

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

## 4b. USB 串口配网（无蓝牙的板子，如 ESP8266 小电视）

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
