class AgentsHud < Formula
  desc "Claude Code status dashboard server — serves live state to the AgentsHUD app over LAN"
  homepage "https://github.com/yinshuai0324/agents-hud"
  url "https://github.com/yinshuai0324/agents-hud/archive/refs/tags/v0.1.18.tar.gz"
  sha256 "2b809aef2af7f9c6206c79182e4269f05d23f2aca69d19be570c1fd07ead2b51"
  version "0.1.18"

  # Intentionally no `depends_on "node"`: that would pull/upgrade to the current
  # core node bottle (~78MB). We build + run with whatever `node` is already
  # installed via Homebrew. Requires the `node` formula to be present.

  def install
    odie "Homebrew's `node` is required: run `brew install node`" unless Formula["node"].any_version_installed?
    ENV.prepend_path "PATH", Formula["node"].opt_bin
    ENV["npm_config_cache"] = buildpath/".npm" # keep npm's cache inside the sandbox

    cd "server" do
      system "npm", "install"
      system "npm", "run", "build"
      # Drop dev deps (tsx/typescript) — the compiled dist/ only needs runtime deps.
      system "npm", "prune", "--omit=dev"
      libexec.install "dist", "node_modules", "package.json", "hooks"
    end

    # BLE pusher for the ESP32 AMOLED dial (runtime-optional, toggled with
    # `agents-hud ble on`). Python venv + bleak live inside libexec.
    (libexec/"ble").install "esp32/daemon/agents_hud_ble.py"
    system "python3", "-m", "venv", libexec/"ble/venv"
    system libexec/"ble/venv/bin/pip", "install", "--quiet", "--upgrade", "pip"
    system libexec/"ble/venv/bin/pip", "install", "--quiet", "bleak"

    # Launcher that runs the compiled server with the installed Homebrew node.
    (bin/"agents-hud").write <<~SH
      #!/bin/bash
      export AGENTS_HUD_BLE_PY="#{libexec}/ble/venv/bin/python"
      export AGENTS_HUD_BLE_SCRIPT="#{libexec}/ble/agents_hud_ble.py"
      exec "#{Formula["node"].opt_bin}/node" "#{libexec}/dist/index.js" "$@"
    SH
  end

  service do
    run [opt_bin/"agents-hud"]
    keep_alive true
    log_path var/"log/agents-hud.log"
    error_log_path var/"log/agents-hud.log"
  end

  def caveats
    <<~EOS
      ⚠️  brew 版 AgentsHUD 已停止维护：数据服务现已内置在 Mac App 中。
      请下载 Agents-HUD.app（拖进「应用程序」即可，无需 node/brew）：
        https://github.com/yinshuai0324/agents-hud/releases/latest
      迁移前先停掉本服务，避免与 App 抢 4317 端口：
        brew services stop agents-hud
      hooks 无需重装（脚本路径不变，App 会原地接管）。
    EOS
  end

  test do
    port = free_port
    pid = spawn({ "CC_SIGNAL_PORT" => port.to_s }, bin/"agents-hud")
    begin
      sleep 3
      assert_match "ok", shell_output("curl -s http://127.0.0.1:#{port}/healthz")
    ensure
      Process.kill("TERM", pid)
    end
  end
end
