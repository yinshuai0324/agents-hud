# CC 信号塔 — Android

Kotlin + Jetpack Compose 客户端。扫描电脑端二维码后，通过局域网 WebSocket 实时显示
Claude Code 的红绿灯状态、5 小时用量和会话列表。

## 构建

用 **Android Studio**（推荐，自带 JDK，会自动下载 SDK 与 Gradle）打开本目录，同步后
点 Run。或命令行（需本机 JDK 17+）：

```bash
./gradlew assembleDebug
# 产物：app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## 技术栈

- Kotlin 2.0.21，Compose BOM 2024.12.01，Material3
- CameraX 1.4.1 + ML Kit barcode-scanning（扫码）
- OkHttp 4.12（WebSocket）+ 自动重连（指数退避）
- kotlinx.serialization（快照解析）
- DataStore（保存配对，自动重连）
- Accompanist Permissions（相机权限）

## 结构

```
app/src/main/java/com/ooimi/agents/status/
├── MainActivity.kt          # 入口，按 screen 切换 扫码/面板
├── MainViewModel.kt         # 配对持久化 + 客户端编排
├── data/
│   ├── Snapshot.kt          # 与服务端一致的数据模型
│   └── Pairing.kt           # 二维码 payload 解析 + DataStore
├── net/SignalClient.kt      # OkHttp WebSocket + 重连
└── ui/
    ├── ScanScreen.kt        # CameraX + ML Kit 扫码
    ├── DashboardScreen.kt   # 主面板
    ├── theme/Theme.kt       # 深色主题 + 配色
    └── components/
        ├── TrafficLight.kt  # 玻璃质感红绿灯（Canvas 绘制）
        ├── Counters.kt      # 等候/工作/沉寂 计数
        ├── UsageBar.kt      # 5H 用量进度条
        └── SessionList.kt   # 会话列表行
```

## 配对二维码格式

服务端二维码内容为 JSON（也兼容裸 `ws://` URL）：

```json
{ "v": 1, "url": "ws://192.168.8.175:4317", "token": "", "name": "my-macbook" }
```

> ⚠️ 局域网用明文 `ws://`，Manifest 中已开启 `usesCleartextTraffic`。请仅在可信局域网使用。
