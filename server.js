import express from "express";
import multer from "multer";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, readdir, stat, unlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const app = express();
const PORT = Number(process.env.PORT || 8787);
const TOKEN = process.env.REA_BRIDGE_TOKEN;
const REA_COMMAND = process.env.REA_COMMAND || "./node_modules/.bin/rea";
const REA_PACKAGE = process.env.REA_PACKAGE || "rea-agents@6.10.1";
const MAX_UPLOAD = Number(process.env.MAX_UPLOAD_BYTES || 200 * 1024 * 1024);
const uploadDir = path.join(os.tmpdir(), "rea-uploads");
await mkdir(uploadDir, { recursive: true });
for (const entry of await readdir(uploadDir).catch(() => [])) {
  const candidate = path.join(uploadDir, entry);
  try {
    const info = await stat(candidate);
    if (info.isFile() && Date.now() - info.mtimeMs > 6 * 60 * 60 * 1000) await unlink(candidate);
  } catch {}
}

if (!TOKEN || TOKEN.length < 32) {
  console.error("REA_BRIDGE_TOKEN must be configured with at least 32 characters");
  process.exit(1);
}

app.disable("x-powered-by");
app.use(express.json({ limit: "2mb" }));

function authorized(req) {
  const value = req.get("authorization") || "";
  const expected = Buffer.from(`Bearer ${TOKEN}`);
  const actual = Buffer.from(value);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
function requireAuth(req, res, next) {
  if (!authorized(req)) return res.status(401).json({ error: "unauthorized" });
  next();
}

let reaClientPromise = null;

async function getReaClient() {
  if (!reaClientPromise) {
    reaClientPromise = (async () => {
      const client = new Client({ name: "rea-ios-bridge", version: "1.0.0" });
      const transport = new StdioClientTransport({
        command: REA_COMMAND,
        args: process.env.REA_COMMAND ? ["-y", REA_PACKAGE, "mcp"] : ["mcp"],
        stderr: "pipe"
      });
      try {
        await client.connect(transport);
        transport.stderr?.on("data", chunk => {
          const line = String(chunk).trim();
          if (line) console.error("[rea-stderr]", line.slice(0, 4000));
        });
        console.log("REA MCP stdio connection established");
        return { client, transport };
      } catch (error) {
        await client.close().catch(() => {});
        await transport.close().catch(() => {});
        throw error;
      }
    })().catch(error => {
      reaClientPromise = null;
      throw error;
    });
  }
  return reaClientPromise;
}

async function withReaClient(fn) {
  const { client } = await getReaClient();
  return fn(client);
}

let reaStartup = { ready: false, toolCount: 0, checkedAt: null, error: null };
app.get("/health", (_req, res) => res.json({ ok: true, service: "rea-bridge", reaReady: reaStartup.ready, toolCount: reaStartup.toolCount }));
app.get("/api/ready", requireAuth, (_req, res) => {
  res.status(reaStartup.ready ? 200 : 503).json(reaStartup);
});

app.get("/api/tools", requireAuth, async (_req, res) => {
  try {
    const result = await withReaClient(client => client.listTools());
    res.json({ tools: result.tools, nextCursor: result.nextCursor ?? null });
  } catch (error) {
    console.error("REA listTools failed:", error);
    res.status(502).json({ error: "rea_unavailable", detail: String(error.message || error) });
  }
});

app.post("/api/tools/:name/call", requireAuth, async (req, res) => {
  const name = req.params.name;
  const args = req.body?.arguments ?? {};
  if (!/^[a-zA-Z0-9_.-]{1,128}$/.test(name) || typeof args !== "object" || Array.isArray(args)) {
    return res.status(400).json({ error: "invalid_tool_request" });
  }
  try {
    const result = await withReaClient(client => client.callTool({ name, arguments: args }));
    res.json(result);
  } catch (error) {
    console.error("REA callTool failed:", error);
    res.status(502).json({ error: "rea_tool_failed", detail: String(error.message || error) });
  }
});

const upload = multer({
  storage: multer.diskStorage({
    destination: (_req, _file, callback) => callback(null, uploadDir),
    filename: (_req, file, callback) => {
      const safeName = path.basename(file.originalname || "artifact")
        .replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 100);
      callback(null, randomUUID() + "-" + safeName);
    }
  }),
  limits: { fileSize: MAX_UPLOAD, files: 1 }
});
app.post("/api/upload", requireAuth, upload.single("file"), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: "file_required" });
  res.status(201).json({
    id: req.file.filename,
    fileName: path.basename(req.file.originalname || "artifact"),
    size: req.file.size,
    filePath: req.file.path,
    note: "Temporary upload; use only with a REA tool whose discovered input schema accepts a file path."
  });
});

app.get("/api/uploads/:id", requireAuth, async (req, res) => {
  const id = req.params.id;
  if (path.basename(id) !== id || !/^[0-9a-f-]{36}-[A-Za-z0-9._-]{1,100}$/i.test(id)) {
    return res.status(400).json({ error: "invalid_upload_id" });
  }
  const filePath = path.join(uploadDir, id);
  try {
    const info = await stat(filePath);
    if (!info.isFile()) return res.status(404).json({ error: "upload_not_found" });
    if (Date.now() - info.mtimeMs > 6 * 60 * 60 * 1000) {
      await unlink(filePath).catch(() => {});
      return res.status(404).json({ error: "upload_expired" });
    }
    res.setHeader("Content-Type", "application/octet-stream");
    res.setHeader("Content-Length", String(info.size));
    res.setHeader("Content-Disposition", 'attachment; filename="authorized-analysis.ipa"');
    const stream = createReadStream(filePath);
    stream.on("error", error => {
      console.error("IPA download stream failed:", error.message);
      if (!res.headersSent) res.status(500).end();
      else res.destroy(error);
    });
    stream.pipe(res);
  } catch (error) {
    if (error.code === "ENOENT") return res.status(404).json({ error: "upload_not_found" });
    console.error("IPA download failed:", error.message);
    res.status(500).json({ error: "download_failed" });
  }
});

app.use((error, _req, res, _next) => {
  if (error?.code === "LIMIT_FILE_SIZE") return res.status(413).json({ error: "file_too_large" });
  console.error(error);
  res.status(400).json({ error: "bad_request" });
});

const server = app.listen(PORT, "0.0.0.0", () => {
  console.log(`REA bridge listening on ${PORT}`);
  withReaClient(async client => {
    const result = await client.listTools();
    reaStartup = { ready: Array.isArray(result.tools) && result.tools.length > 0, toolCount: result.tools?.length ?? 0, checkedAt: new Date().toISOString(), error: null };
    console.log(`REA MCP startup discovery: ${reaStartup.toolCount} tools`);
  }).catch(error => {
    reaStartup = { ready: false, toolCount: 0, checkedAt: new Date().toISOString(), error: String(error.message || error) };
    console.error("REA MCP startup discovery failed:", error);
  });
});
async function shutdown() {
  server.close();
  if (reaClientPromise) {
    try {
      const { client, transport } = await reaClientPromise;
      await client.close().catch(() => {});
      await transport.close().catch(() => {});
    } catch {}
  }
  process.exit(0);
}
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
