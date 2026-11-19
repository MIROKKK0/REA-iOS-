import { createMcpClient } from "./mcp-client.mjs";
import http from "node:http";
import { spawn } from "node:child_process";
import { createWriteStream, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { randomUUID, timingSafeEqual } from "node:crypto";

const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || "0.0.0.0";
const MCP_PORT = Number(process.env.MCP_PORT || 8788);
const TOKEN = process.env.REA_API_TOKEN || "";
const MAX_UPLOAD = Number(process.env.MAX_UPLOAD_BYTES || 300 * 1024 * 1024);
const UPLOAD_DIR = process.env.REA_UPLOAD_DIR || path.join(tmpdir(), "rea-mobile-uploads");
const STARTUP_TIMEOUT_MS = Number(process.env.REA_STARTUP_TIMEOUT_MS || 90000);
const uploads = new Map();
let mcpProcess;
let mcpReady = false;
let stopping = false;
const mcp = createMcpClient(MCP_PORT);

mkdirSync(UPLOAD_DIR, { recursive: true, mode: 0o700 });

function authorized(req) {
  if (!TOKEN) return false;
  const supplied = req.headers.authorization || "";
  const expected = `Bearer ${TOKEN}`;
  const a = Buffer.from(supplied);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

function send(res, status, body) {
  const data = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": data.length,
    "cache-control": "no-store",
    "x-content-type-options": "nosniff"
  });
  res.end(data);
}

function startMcp() {
  return new Promise((resolve, reject) => {
    const child = spawn("npx", [
      "--yes", "rea-agents@6.9.0", "mcp",
      "--http", "--host", "127.0.0.1", "--port", String(MCP_PORT)
    ], { stdio: ["ignore", "ignore", "pipe"], env: process.env });
    mcpProcess = child;
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      reject(new Error("REA MCP startup timed out"));
      child.kill("SIGTERM");
    }, STARTUP_TIMEOUT_MS);
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", chunk => {
      for (const line of chunk.split("\n")) {
        try {
          const record = JSON.parse(line);
          if (record.msg === "MCP transport listening" && !settled) {
            settled = true;
            clearTimeout(timer);
            mcpReady = true;
            resolve();
          }
        } catch { /* Other REA diagnostics are intentionally not exposed. */ }
      }
    });
    child.once("error", error => {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(error);
      }
    });
    child.once("exit", code => {
      mcpReady = false;
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        reject(new Error(`REA MCP exited during startup (code ${code})`));
      }
    });
  });
}

async function saveUpload(req, res, url) {
  if (req.method !== "POST") return send(res, 405, { error: "method_not_allowed" });
  const declaredLength = Number(req.headers["content-length"] || 0);
  if (declaredLength > MAX_UPLOAD) { req.resume(); return send(res, 413, { error: "upload_too_large", maxBytes: MAX_UPLOAD }); }
  const name = path.basename(url.searchParams.get("filename") || "artifact.bin").replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 120) || "artifact.bin";
  const id = randomUUID();
  const destination = path.join(UPLOAD_DIR, id + "-" + name);
  const output = createWriteStream(destination, { flags: "wx", mode: 0o600 });
  let size = 0; let exceeded = false;
  try {
    for await (const chunk of req) {
      size += chunk.length;
      if (size > MAX_UPLOAD) { exceeded = true; output.destroy(); continue; }
      if (!exceeded && !output.write(chunk)) await new Promise((resolve, reject) => { output.once("drain", resolve); output.once("error", reject); });
    }
    if (exceeded || size === 0) {
      output.destroy();
      const { unlink } = await import("node:fs/promises");
      await unlink(destination).catch(() => {});
      return send(res, exceeded ? 413 : 400, exceeded ? { error: "upload_too_large", maxBytes: MAX_UPLOAD } : { error: "empty_upload" });
    }
    await new Promise((resolve, reject) => { output.once("error", reject); output.end(resolve); });
    const record = { id, name, size, path: destination, createdAt: new Date().toISOString() };
    uploads.set(id, record);
    return send(res, 201, { upload: record, next: "Pass the returned absolute path to a compatible REA tool." });
  } catch (error) {
    output.destroy();
    const { unlink } = await import("node:fs/promises");
    await unlink(destination).catch(() => {});
    if (!res.headersSent) return send(res, 400, { error: "upload_failed", message: error.message });
    res.destroy();
  }
}
function proxyMcp(req, res) {
  if (!mcpReady) return send(res, 503, { error: "rea_mcp_not_ready" });
  const headers = { ...req.headers, host: `127.0.0.1:${MCP_PORT}` };
  delete headers.authorization;
  delete headers.connection;
  const upstream = http.request({
    host: "127.0.0.1", port: MCP_PORT, path: "/mcp",
    method: req.method, headers
  }, upstreamRes => {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    upstreamRes.pipe(res);
  });
  upstream.on("error", () => {
    if (!res.headersSent) send(res, 502, { error: "mcp_proxy_failed" });
    else res.destroy();
  });
  req.pipe(upstream);
  req.on("aborted", () => upstream.destroy());
  res.on("close", () => upstream.destroy());
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  if (url.pathname === "/health" && req.method === "GET") {
    return send(res, 200, {
      service: "rea-mobile-backend",
      status: mcpReady ? "ready" : "starting",
      rea: "rea-agents@6.9.0",
      transport: "streamable-http",
      authenticatedRoutes: true
    });
  }
  if (!authorized(req)) return send(res, 401, { error: "unauthorized" });
  if (url.pathname === "/api/upload") return saveUpload(req, res, url);
  if (url.pathname === "/api/tools" && req.method === "GET") {
    try { return send(res, 200, await mcp.listTools()); }
    catch (error) { return send(res, 502, { error: "mcp_tools_unavailable", message: error.message }); }
  }
  if (url.pathname === "/api/tools/call" && req.method === "POST") {
    try {
      let raw = "";
      for await (const chunk of req) {
        raw += chunk.toString("utf8");
        if (raw.length > 1024 * 1024) return send(res, 413, { error: "request_too_large" });
      }
      const input = JSON.parse(raw || "{}");
      if (typeof input.name !== "string" || !input.name.trim()) return send(res, 400, { error: "tool_name_required" });
      const result = await mcp.callTool(input.name, input.arguments || {});
      return send(res, 200, result);
    } catch (error) { return send(res, 502, { error: "mcp_tool_failed", message: error.message }); }
  }
  if (url.pathname === "/mcp") return proxyMcp(req, res);
  return send(res, 404, { error: "not_found" });
});

async function shutdown() {
  if (stopping) return;
  stopping = true;
  server.close();
  if (mcpProcess && !mcpProcess.killed) mcpProcess.kill("SIGTERM");
}
process.once("SIGTERM", shutdown);
process.once("SIGINT", shutdown);

if (!TOKEN || TOKEN.length < 32) {
  console.error("REA_API_TOKEN must be configured with at least 32 characters.");
  process.exit(1);
}

try {
  await startMcp();
  server.listen(PORT, HOST, () => {
    console.log(JSON.stringify({ msg: "REA mobile API listening", host: HOST, port: PORT }));
  });
} catch (error) {
  console.error(`Could not start REA MCP: ${error.message}`);
  process.exit(1);
}
