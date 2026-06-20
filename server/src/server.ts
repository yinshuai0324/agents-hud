import http from "node:http";
import { WebSocketServer, type WebSocket } from "ws";
import type { Config } from "./config.js";
import type { Snapshot, StateEngine } from "./state.js";

/** Collapse whitespace and cap length for inline display. */
function oneLine(s: unknown, max: number): string {
  const t = String(s ?? "").replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max - 1) + "…" : t;
}

function baseName(p: unknown): string {
  const parts = String(p ?? "").split("/").filter(Boolean);
  return parts[parts.length - 1] || String(p ?? "");
}

/** A short human label for a tool call, e.g. "Bash: npm run build", "Edit UsageBar.kt". */
function toolSummary(name: string, input: any): string {
  const i = input ?? {};
  switch (name) {
    case "Bash":
      return i.command ? `Bash: ${oneLine(i.command, 40)}` : "Bash";
    case "Read":
    case "Edit":
    case "Write":
    case "NotebookEdit":
      return i.file_path ? `${name} ${baseName(i.file_path)}` : name;
    case "Grep":
      return i.pattern ? `Grep ${oneLine(i.pattern, 24)}` : "Grep";
    case "Glob":
      return i.pattern ? `Glob ${oneLine(i.pattern, 24)}` : "Glob";
    default:
      return name;
  }
}

/**
 * HTTP + WebSocket server.
 *  - POST /hooks        : Claude Code hook callbacks (localhost only in practice)
 *  - GET  /api/snapshot : current snapshot (REST, for first paint / polling)
 *  - GET  /healthz      : liveness
 *  - WS   /             : live snapshot stream (push on change + heartbeat)
 */
export function createServer(cfg: Config, engine: StateEngine) {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://localhost");

    if (req.method === "GET" && url.pathname === "/healthz") {
      return json(res, 200, { ok: true });
    }

    if (req.method === "GET" && url.pathname === "/api/snapshot") {
      if (!authOk(cfg, url.searchParams.get("token"), req)) {
        return json(res, 401, { error: "unauthorized" });
      }
      return json(res, 200, engine.buildSnapshot());
    }

    if (req.method === "POST" && url.pathname === "/hooks") {
      return readBody(req, (body) => {
        let data: any = {};
        try {
          data = body ? JSON.parse(body) : {};
        } catch {
          return json(res, 400, { error: "bad json" });
        }
        const event = String(data.hook_event_name ?? data.event ?? "");
        const sessionId = String(data.session_id ?? data.sessionId ?? "");
        const cwd = typeof data.cwd === "string" ? data.cwd : undefined;
        const toolLabel =
          typeof data.tool_name === "string"
            ? toolSummary(data.tool_name, data.tool_input)
            : undefined;
        engine.handleHook(event, sessionId, cwd, toolLabel);
        return json(res, 200, { ok: true });
      });
    }

    if (req.method === "POST" && url.pathname === "/statusline") {
      return readBody(req, (body) => {
        let data: any = {};
        try {
          data = body ? JSON.parse(body) : {};
        } catch {
          return json(res, 400, { error: "bad json" });
        }
        engine.handleStatusline(data);
        return json(res, 200, { ok: true });
      });
    }

    return json(res, 404, { error: "not found" });
  });

  const wss = new WebSocketServer({ server });
  wss.on("connection", (ws: WebSocket, req) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (!authOk(cfg, url.searchParams.get("token"), req)) {
      ws.close(4401, "unauthorized");
      return;
    }
    // Initial snapshot on connect.
    safeSend(ws, engine.buildSnapshot());
    const off = engine.onSnapshot((snap: Snapshot) => safeSend(ws, snap));

    // Heartbeat to detect dead peers and keep NAT/idle connections alive.
    let alive = true;
    ws.on("pong", () => (alive = true));
    const ping = setInterval(() => {
      if (!alive) {
        ws.terminate();
        return;
      }
      alive = false;
      try {
        ws.ping();
      } catch {
        /* ignore */
      }
    }, 15_000);

    ws.on("close", () => {
      off();
      clearInterval(ping);
    });
    ws.on("error", () => {
      off();
      clearInterval(ping);
    });
  });

  return server;
}

function authOk(cfg: Config, queryToken: string | null, req: http.IncomingMessage): boolean {
  if (!cfg.authToken) return true;
  const header = req.headers["authorization"];
  const bearer = typeof header === "string" && header.startsWith("Bearer ")
    ? header.slice(7)
    : null;
  return queryToken === cfg.authToken || bearer === cfg.authToken;
}

function json(res: http.ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "access-control-allow-origin": "*",
  });
  res.end(payload);
}

function readBody(req: http.IncomingMessage, cb: (body: string) => void): void {
  let body = "";
  let size = 0;
  req.on("data", (chunk) => {
    size += chunk.length;
    if (size > 1_000_000) {
      req.destroy();
      return;
    }
    body += chunk;
  });
  req.on("end", () => cb(body));
  req.on("error", () => cb(""));
}

function safeSend(ws: WebSocket, obj: unknown): void {
  if (ws.readyState !== ws.OPEN) return;
  try {
    ws.send(JSON.stringify(obj));
  } catch {
    /* ignore */
  }
}
