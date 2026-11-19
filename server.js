import express from "express";
import multer from "multer";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { mkdir, writeFile, unlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const app = express();
const PORT = Number(process.env.PORT || 8787);
const TOKEN = process.env.REA_BRIDGE_TOKEN;
const REA_COMMAND = process.env.REA_COMMAND || "npx";
const REA_PACKAGE = process.env.REA_PACKAGE || "rea-agents@6.9.0";
const MAX_UPLOAD = Number(process.env.MAX_UPLOAD_BYTES || 200 * 1024 * 1024);
const uploadDir = path.join(os.tmpdir(), "rea-uploads");
await mkdir(uploadDir, { recursive: true });

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

async function withReaClient(fn) {
  const client = new Client({ name: "rea-ios-bridge", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: REA_COMMAND,
    args: ["-y", REA_PACKAGE, "mcp"],
    stderr: "pipe"
  });
  try {
    await client.connect(transport);
    return await fn(client);
  } finally {
    await client.close().catch(() => {});
    await transport.close().catch(() => {});
  }
}

app.get("/health", (_req, res) => res.json({ ok: true, service: "rea-bridge" }));

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
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_UPLOAD, files: 1 }
});
app.post("/api/upload", requireAuth, upload.single("file"), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: "file_required" });
  const safeName = path.basename(req.file.originalname || "artifact").replace(/[^a-zA-Z0-9._-]/g, "_").slice(0, 100);
  const id = randomUUID();
  const filePath = path.join(uploadDir, `${id}-${safeName}`);
  try {
    await writeFile(filePath, req.file.buffer, { flag: "wx", mode: 0o600 });
    res.status(201).json({ id, fileName: safeName, size: req.file.size, filePath, note: "Use this path only with a REA tool whose discovered input schema accepts a file path." });
  } catch (error) {
    console.error("Upload failed:", error);
    res.status(500).json({ error: "upload_failed" });
  }
});

app.use((error, _req, res, _next) => {
  if (error?.code === "LIMIT_FILE_SIZE") return res.status(413).json({ error: "file_too_large" });
  console.error(error);
  res.status(400).json({ error: "bad_request" });
});

const server = app.listen(PORT, "0.0.0.0", () => console.log(`REA bridge listening on ${PORT}`));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
