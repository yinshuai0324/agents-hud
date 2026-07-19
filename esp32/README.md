# AgentsHUD ESP32 圆屏固件

跑在 Waveshare **ESP32-S3-Touch-AMOLED-1.75**（466×466 圆形 AMOLED，CO5300 QSPI +
CST9217 触摸）上的用量表盘。**WiFi 与 Mac 通讯**：首次用 BLE 从 Mac App 接收 WiFi
配置（「设备…」窗口扫描下发），之后固件作为 WebSocket client 直连 Mac App 内置
server 的 `/device` 端点，每 3 秒收到一条紧凑 JSON。Mac 换 IP 时通过 mDNS
（`_agentshud._tcp`）自动找回服务。协议详见 [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md)。

## 界面与交互

- 三个页面，**点按屏幕循环**：用量（5h/7d 卡片 + 状态栏）→ Clawd 像素宠物（按烧
  token 速率换动画：睡觉 / 思考写码 / 蹦迪）→ 详情（主机 / 今日 / 速率 / 模型 /
  套餐 / **编号**）
- **编号**即设备身份（如 `F232`，WiFi MAC 后两字节），等待配对时状态栏也会显示
- 侧面 **BOOT 键短按**：屏幕旋转 90°（存 NVS，断电记忆）；**长按 ≥3 秒**：清除配网
  信息并重启进配对模式
- 串口调试命令：`b` 重启进下载模式（免按键烧录）、`r` 普通重启、`p` 清除配网重启、
  `z` 强制息屏

## 多板型

每块板一个 HAL 组件：`boards/<id>/board/`（对外只暴露 `board.h`，应用代码不直接
include 具体 BSP）。现有 `ws175`；换板编译：`idf.py -DAHUD_BOARD=<id> build`。
新板型 = 新增 `boards/<id>/board/` + Mac 端 `BoardRegistry.swift` 加一行 +
`.github/workflows/esp32.yml` 矩阵加一项。

## 编译与烧录

固件版本号取自仓库根的 `VERSION` 文件（`esp_app_get_description()->version` 上报）。

需要 ESP-IDF v5.4+（含 esp32s3 工具链）：

```bash
source ~/esp/esp-idf/export.sh
idf.py build
idf.py -p /dev/cu.usbmodem101 flash    # 首次烧录
```

日常更新固件不用碰按键：向串口发一个字符 `b` 进下载模式，再 `flash`。

**普通用户不需要装 IDF**：发版时 CI（`.github/workflows/esp32.yml`）会把
`agents-hud-<ver>-esp32-ws175.zip`（bin + manifest）挂到 GitHub Release，
Mac App「设备」窗口用内置 esptool 一键 USB 烧录（自动分块 + 逐块校验）。

### 这块板子的硬件坑（重要）

- **USB 串口不稳定**：持续传输几秒后常断流。整包烧录失败时，把 app 镜像按 364KB
  切块、逐块 `esptool write_flash` 并确认每块 `Hash of data verified`（或单独
  `verify_flash` 补验）。镜像校验不过 bootloader 会拒绝启动（黑屏重启循环）。
- **打开串口可能误触发复位进下载模式**（rst:0x15, boot:0x23 DOWNLOAD）。"板子失联"
  九成是这个：先用 `esptool --before no_reset flash_id` 探测，能连上说明它在下载
  模式里等着。可靠的退出方式是在同一个串口会话里脉冲 RTS。
- **黑白条纹**：LVGL 绘制缓冲不能放 PSRAM（无线电收发会抢总线导致 QSPI 刷屏丢带），
  必须放内部 DMA RAM，见 `boards/ws175/board/board.c`（30 行条带 ×2，因 sw_rotate 需双缓冲）。
  WiFi 常开后此约束更关键，升级固件后请盯一眼满载时是否有条纹。
- **触摸驱动**：官方 CST9217 驱动在无触摸时返回错误会被 esp_lvgl_port abort，
  `components/esp_lcd_touch_cst9217/` 是打过补丁的本地版。
- **中文字体**：`main/font_cn_20.c` 由 lv_font_conv 按需生成（只含 UI 用到的字），
  新增中文文案需重新生成（命令见 git log 或 daemon README）。

## 通信协议

BLE 配网 GATT、`/device` WebSocket 消息、mDNS 重发现见
[`../docs/PROTOCOL.md`](../docs/PROTOCOL.md)。

> 旧的「BLE 推数据」链路（[`daemon/`](daemon/) Python 推送进程 + `agents-hud ble`
> 命令）已废弃：新固件 BLE 只用于配网，数据全走 WiFi。daemon 目录随 Node server
> 一起在后续版本移除。
