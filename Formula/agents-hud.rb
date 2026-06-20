class AgentsHud < Formula
  desc "Claude Code status dashboard server — serves live state to the AgentsHUD app over LAN"
  homepage "https://github.com/yinshuai0324/agents-hud"
  url "https://github.com/yinshuai0324/agents-hud/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "4d07a22559489b738b6a85835efd44836c60083d532f16cb10ceca2e6f5be009"
  version "0.1.2"

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
      libexec.install "dist", "node_modules", "package.json"
    end

    # Launcher that runs the compiled server with the installed Homebrew node.
    (bin/"agents-hud").write <<~SH
      #!/bin/bash
      exec "#{Formula["node"].opt_bin}/node" "#{libexec}/dist/index.js" "$@"
    SH
  end

  service do
    run [opt_bin/"agents-hud"]
    keep_alive true
    log_path var/"log/agents-hud.log"
    error_log_path var/"log/agents-hud.log"
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
