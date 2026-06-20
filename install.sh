#!/usr/bin/env bash
#
# AgentsHUD server — one-shot installer for macOS.
#
# Detects Homebrew (offers to install it if missing), then taps this repo,
# installs the `agents-hud` server, and starts it as a background service.
#
# Run it with (note the `bash -c "$(...)"` form so prompts can read the terminal):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/yinshuai0324/agents-hud/main/install.sh)"
#
set -euo pipefail

TAP="yinshuai0324/agents-hud"
TAP_URL="https://github.com/yinshuai0324/agents-hud"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
info() { printf "\033[1;34m==>\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m!\033[0m  %s\n" "$1"; }
err()  { printf "\033[1;31mx\033[0m  %s\n" "$1" >&2; }

bold "AgentsHUD installer"

# ── 1. Homebrew ───────────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  warn "未检测到 Homebrew。"
  printf "现在安装 Homebrew 吗？[Y/n] "
  read -r ans || ans=""
  case "${ans:-Y}" in
    [nN]*)
      err "已取消。请先安装 Homebrew（https://brew.sh）后重新运行本脚本。"
      exit 1
      ;;
  esac
  info "安装 Homebrew（可能需要输入密码）..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # 把 brew 加入当前 shell（Apple Silicon 在 /opt/homebrew，Intel 在 /usr/local）
  if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

if ! command -v brew >/dev/null 2>&1; then
  err "Homebrew 装好后当前终端仍找不到 brew。请重开一个终端再运行本脚本。"
  exit 1
fi
info "Homebrew: $(brew --version | head -1)"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1

# ── 2. node（formula 运行依赖，用 Homebrew 的 node）─────────────────────────────
if brew list --versions node >/dev/null 2>&1; then
  info "node 已安装：$(brew list --versions node)"
else
  info "安装 node（首次下载约 80MB）..."
  brew install node
fi

# ── 3. tap + trust ─────────────────────────────────────────────────────────────
info "添加 tap $TAP ..."
brew tap "$TAP" "$TAP_URL" 2>/dev/null || true
# Homebrew 6+ 需信任第三方 tap；老版本没有该命令，忽略其报错。
brew trust "$TAP" >/dev/null 2>&1 || true

# ── 4. 安装 / 升级 agents-hud ───────────────────────────────────────────────────
if brew list --versions agents-hud >/dev/null 2>&1; then
  info "agents-hud 已安装，尝试升级..."
  brew upgrade agents-hud 2>/dev/null || info "已是最新。"
else
  info "安装 agents-hud..."
  brew install agents-hud
fi

# ── 5. 作为后台服务启动（launchd，开机自启 + 崩溃重启）──────────────────────────
info "启动后台服务..."
brew services start agents-hud >/dev/null 2>&1 || brew services restart agents-hud >/dev/null 2>&1 || true

# ── 6. 健康检查 ─────────────────────────────────────────────────────────────────
PORT="${CC_SIGNAL_PORT:-4317}"
ok=""
for _ in $(seq 1 15); do
  if curl -fsS -m1 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done

echo
if [ -n "$ok" ]; then
  bold "✅ 安装完成，服务已在 127.0.0.1:${PORT} 运行。"
else
  warn "服务已安装，但端口 ${PORT} 暂未响应（可能正在启动，或被占用）。"
  echo "   查看日志：tail -f \"\$(brew --prefix)/var/log/agents-hud.log\""
fi
echo "  • 看配对二维码（前台运行一次）：agents-hud"
echo "  • 服务管理：brew services [start|stop|restart] agents-hud"
echo "  • 手机用 AgentsHUD App 扫码连接（需同一局域网）。"
