import { randomUUID } from "node:crypto";

export function createMcpClient(port) {
  let sessionId = null;
  let requestId = 0;
  async function request(method, params = {}, notification = false) {
    const headers = { "content-type": "application/json", "accept": "application/json, text/event-stream" };
    if (sessionId) headers["mcp-session-id"] = sessionId;
    const payload = notification
      ? { jsonrpc: "2.0", method, params }
      : { jsonrpc: "2.0", id: ++requestId, method, params };
    const response = await fetch("http://127.0.0.1:" + port + "/mcp", {
      method: "POST", headers, body: JSON.stringify(payload), signal: AbortSignal.timeout(240000)
    });
    const receivedSession = response.headers.get("mcp-session-id");
    if (receivedSession) sessionId = receivedSession;
    if (notification && response.status === 202) return { accepted: true };
    const raw = await response.text();
    let message = null;
    if ((response.headers.get("content-type") || "").includes("text/event-stream")) {
      const data = raw.split("\n").filter(line => line.startsWith("data:")).map(line => line.slice(5).trim()).join("\n");
      if (data) message = JSON.parse(data);
    } else if (raw) message = JSON.parse(raw);
    if (!response.ok) throw new Error("MCP HTTP " + response.status + ": " + raw.slice(0, 1000));
    if (message && message.error) throw new Error(message.error.message || "MCP request failed");
    return message ? message.result : null;
  }
  async function initialize() {
    if (sessionId) return;
    await request("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "rea-mobile-gateway", version: "0.1.0" } });
    await request("notifications/initialized", {}, true);
  }
  return {
    async listTools() { await initialize(); return request("tools/list", {}); },
    async callTool(name, args) { await initialize(); return request("tools/call", { name, arguments: args || {} }); },
    reset() { sessionId = null; requestId = 0; }
  };
}
