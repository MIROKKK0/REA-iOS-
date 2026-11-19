import test from "node:test";
import assert from "node:assert/strict";
import { createMcpClient } from "./mcp-client.mjs";

test("discovers and calls tools through a stateful MCP HTTP session", async () => {
  const originalFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (_url, options) => {
    const body = JSON.parse(options.body);
    seen.push({ body, headers: options.headers });
    if (body.method === "initialize") {
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: { protocolVersion: "2025-03-26", capabilities: {}, serverInfo: { name: "REA", version: "6.9.0" } } }), {
        status: 200, headers: { "content-type": "application/json", "mcp-session-id": "test-session" }
      });
    }
    if (body.method === "notifications/initialized") return new Response(null, { status: 202 });
    if (body.method === "tools/list") {
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: { tools: [{ name: "inspect_artifact" }] } }), {
        status: 200, headers: { "content-type": "application/json" }
      });
    }
    if (body.method === "tools/call") {
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: body.id, result: { content: [{ type: "text", text: "real tool result" }] } }), {
        status: 200, headers: { "content-type": "application/json" }
      });
    }
    throw new Error("Unexpected MCP method " + body.method);
  };
  try {
    const client = createMcpClient(8788);
    const catalog = await client.listTools();
    assert.equal(catalog.tools[0].name, "inspect_artifact");
    const result = await client.callTool("inspect_artifact", { path: "/tmp/sample.ipa" });
    assert.equal(result.content[0].text, "real tool result");
    assert.equal(seen[2].headers["mcp-session-id"], "test-session");
    assert.equal(seen[3].headers["mcp-session-id"], "test-session");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
