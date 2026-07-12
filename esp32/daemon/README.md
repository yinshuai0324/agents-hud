# AgentsHUD BLE 守护进程

把本机 AgentsHUD server（`http://127.0.0.1:4317/api/snapshot`）的用量数据，
每 3 秒通过蓝牙 BLE 推送给 ESP32 AMOLED 圆屏（广播名 `AgentsHUD`）。
守护进程自动扫描、自动重连，屏幕或 server 掉线都会自行恢复。

## 一键安装（推荐）

```bash
bash install.sh   # venv + bleak + launchd 自启，一步到位
```

## 依赖

```bash
python3 -m venv .venv
.venv/bin/pip install bleak
```

## 手动运行（调试）

```bash
.venv/bin/python agents_hud_ble.py
```

首次运行 macOS 会请求蓝牙权限（系统设置 → 隐私与安全性 → 蓝牙），需要允许。

## 开机自启（launchd）

```bash
cp com.agentshud.ble.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.agentshud.ble.plist
```

日志在 `/tmp/agents-hud-ble.log`。停止/卸载：

```bash
launchctl unload ~/Library/LaunchAgents/com.agentshud.ble.plist
```

> plist 里的路径是绝对路径，仓库位置变了要同步修改。

## 协议

GATT service `41485544-6469-616c-2d64-617461000001`，
RX characteristic `...000002`（write）。每次写入一条压缩 JSON（~200B）：

| 字段 | 含义 |
| --- | --- |
| p5 / r5 | 5 小时用量 % / 重置剩余分钟 |
| p7 / r7 | 7 天用量 % / 重置剩余分钟（无则缺省） |
| tt | 今日 token 总量 |
| bu | 每分钟 token 速率 |
| lv | 1=官方实时数据, 0=本地估算 |
| w/n/wa/e/q/to | working/notify/waiting/error/quiet/总会话数 |
| m / pl | 模型名 / 套餐名 |
