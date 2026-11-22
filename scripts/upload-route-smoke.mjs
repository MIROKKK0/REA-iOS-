import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";

const port = 18788;
const token = "upload-route-smoke-token-0123456789abcdef";
const base = `http://127.0.0.1:${port}`;
const child = spawn(process.execPath, ["server.js"], {
  cwd: process.cwd(),
  env: { ...process.env, PORT: String(port), REA_BRIDGE_TOKEN: token },
  stdio: "ignore"
});
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let uploadID = "";
try {
  let ready = false;
  for (let i = 0; i < 80; i++) {
    try {
      const response = await fetch(base + "/health");
      if (response.ok) { ready = true; break; }
    } catch {}
    await sleep(250);
  }
  assert.ok(ready, "REA bridge HTTP listener did not start");

  const bytes = Buffer.from("ULTRON-REA-UPLOAD-ROUNDTRIP-TEST");
  const form = new FormData();
  form.append("file", new Blob([bytes], { type: "application/octet-stream" }), "roundtrip.ipa");
  const uploaded = await fetch(base + "/api/upload", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: form
  });
  assert.equal(uploaded.status, 201, "authenticated upload should return 201");
  const metadata = await uploaded.json();
  uploadID = metadata.id;
  assert.match(uploadID, /^[0-9a-f-]{36}-roundtrip\.ipa$/i);
  assert.equal(metadata.size, bytes.length);

  const denied = await fetch(base + `/api/uploads/${uploadID}`);
  assert.equal(denied.status, 401, "download must require bearer authentication");

  const downloaded = await fetch(base + `/api/uploads/${uploadID}`, {
    headers: { Authorization: `Bearer ${token}` }
  });
  assert.equal(downloaded.status, 200, "authenticated download should return 200");
  assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), bytes, "downloaded bytes must match uploaded bytes");
  console.log("REA bridge authenticated disk-upload/download roundtrip passed.");
} finally {
  if (uploadID) await fs.unlink(path.join(os.tmpdir(), "rea-uploads", uploadID)).catch(() => {});
  child.kill("SIGTERM");
  await Promise.race([
    new Promise(resolve => child.once("exit", resolve)),
    sleep(5000)
  ]);
  if (child.exitCode === null) child.kill("SIGKILL");
}
