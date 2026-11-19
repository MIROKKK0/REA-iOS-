import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const client = new Client({ name: "rea-bridge-smoke-test", version: "1.0.0" });
const transport = new StdioClientTransport({
  command: process.env.REA_COMMAND || "npx",
  args: ["-y", process.env.REA_PACKAGE || "rea-agents@6.9.0", "mcp"],
  stderr: "pipe"
});
try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  assert.ok(Array.isArray(tools) && tools.length > 0, "REA returned no tools");
  console.log(JSON.stringify({ ok: true, toolCount: tools.length, tools: tools.map(t => t.name) }, null, 2));
} finally {
  await client.close().catch(() => {});
  await transport.close().catch(() => {});
}
