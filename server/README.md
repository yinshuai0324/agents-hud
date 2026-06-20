# CC 信号塔 — Server

电脑端 Node + TypeScript 服务。读取本机 `~/.claude` 数据，结合 Claude Code hooks 推断
会话状态，通过 WebSocket / REST 把快照推送给 Android App，并在终端打印配对二维码。

## 运行

```bash
npm install
npm start            # 启动服务 + 打印二维码
npm run dev          # 开发模式（tsx watch 热重载）
npm run typecheck    # 类型检查
npm run setup-hooks  # 安装 Claude Code hooks（自动备份 settings.json）
npm run uninstall-hooks
```

## 结构

```
src/
├── index.ts            # 入口：装配 provider/engine/server，打印二维码
├── config.ts           # 环境变量配置
├── usage5h.ts          # ccusage 风格 5 小时滚动窗口计算
├── state.ts            # 状态机（hooks + 文件监听 + 空闲计时）+ 快照构建
├── server.ts           # HTTP + WebSocket（/hooks, /api/snapshot, /healthz, WS）
├── qr.ts               # LAN IP 探测 + 终端二维码 + 配对 payload
├── setup-hooks.ts      # 幂等安装/卸载 hooks（含备份）
└── providers/
    ├── types.ts        # Provider 接口 + 数据结构（为 Gemini 预留）
    └── claude.ts       # ClaudeProvider：解析 jsonl、聚合 token、文件监听
hooks/
└── cc-signal-hook.sh   # Claude 调用的 hook 桥接脚本（curl 到本机 /hooks）
```

## 自测

```bash
CC_SIGNAL_PORT=4399 npm start &
curl localhost:4399/healthz
curl -s localhost:4399/api/snapshot | python3 -m json.tool
# 模拟 hook 触发状态切换：
curl -XPOST localhost:4399/hooks -H 'content-type: application/json' \
  -d '{"hook_event_name":"Stop","session_id":"demo","cwd":"/Users/me/proj"}'
```

接入新 provider（如 Gemini）：实现 `providers/types.ts` 的 `Provider` 接口，在
`index.ts` 的 providers 数组中加入即可，其余无需改动。
