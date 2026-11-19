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
  const candidates = new Set([
    "binary_overview", "open_binary", "inspect_artifact", "extract_artifact",
    "inspect_web_page", "analyze_web_bundle", "inspect_api_contract",
    "project_apple_application_graph"
  ]);
  console.log(JSON.stringify({
    ok: true,
    toolCount: tools.length,
    tools: tools.map(t => t.name),
    candidateSchemas: tools.filter(t => candidates.has(t.name)).map(t => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema
    }))
  }, null, 2));
} finally {
  await client.close().catch(() => {});
  await transport.close().catch(() => {});
}
