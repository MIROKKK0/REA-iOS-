export function createMcpClient(port) {
  let sessionId = null;
  let requestId = 0;
  let initialized = false;
  let queue = Promise.resolve();
  async function exchange(method, params = {}, notification = false) {
    const headers = { "content-type": "application/json", accept: "application/json, text/event-stream" };
    if (sessionId) headers["mcp-session-id"] = sessionId;
    const payload = notification ? { jsonrpc: "2.0", method, params } : { jsonrpc: "2.0", id: ++requestId, method, params };
    const response = await fetch("http://127.0.0.1:" + port + "/mcp", { method: "POST", headers, body: JSON.stringify(payload), signal: AbortSignal.timeout(300000) });
    const received = response.headers.get("mcp-session-id");
    if (received) sessionId = received;
    const raw = await response.text();
    if (notification && response.status === 202) return null;
    let message = null;
    if ((response.headers.get("content-type") || "").includes("text/event-stream")) {
      const dataLines = raw.split(/\r?\n/).filter(line => line.startsWith("data:")).map(line => line.slice(5).trim());
      for (const data of dataLines) { if (data) { try { message = JSON.parse(data); } catch {} } }
    } else if (raw) { message = JSON.parse(raw); }
    if (!response.ok) throw new Error("MCP HTTP " + response.status + ": " + raw.slice(0, 1200));
    if (message && message.error) throw new Error(message.error.message || "MCP JSON-RPC error");
    if (!notification && !message) throw new Error("MCP returned no JSON-RPC response");
    return message ? message.result : null;
  }
  async function initialize() {
    if (initialized) return;
    const result = await exchange("initialize", { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "rea-mobile-gateway", version: "0.2.0" } });
    if (!result || !result.protocolVersion) throw new Error("Invalid MCP initialize response");
    await exchange("notifications/initialized", {}, true);
    initialized = true;
  }
  function serial(task) {
    const next = queue.then(task, task);
    queue = next.then(() => undefined, () => undefined);
    return next;
  }
  return {
    listTools() { return serial(async () => { await initialize(); return exchange("tools/list", {}); }); },
    callTool(name, args) { return serial(async () => { await initialize(); return exchange("tools/call", { name, arguments: args || {} }); }); },
    reset() { sessionId = null; requestId = 0; initialized = false; }
  };
}
