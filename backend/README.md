# REA mobile backend

This service launches the official `rea-agents@6.9.0` MCP server on loopback and places an authenticated API gateway in front of its Streamable HTTP `/mcp` endpoint.

## Required environment

- `REA_API_TOKEN`: random secret with at least 32 characters.
- `PORT`: public service port (default 8787).
- `MCP_PORT`: private REA MCP port (default 8788).
- `MAX_UPLOAD_BYTES`: upload cap (default 300 MiB).

## Routes

- `GET /health`: readiness status; no secret or filesystem paths are disclosed.
- `POST /api/upload?filename=...`: authenticated raw binary upload; returns the stored absolute path.
- `GET /api/tools`: authenticated live MCP `tools/list` catalog, including input schemas.
- `POST /api/tools/call`: authenticated generic MCP `tools/call`; JSON body: `{"name":"tool_name","arguments":{}}`.
- `POST /mcp`: authenticated pass-through to the official Streamable HTTP MCP endpoint.

The iOS app uses the catalog's real tool names and schemas. It does not assume a tool name or fabricate analysis output. Select a tool, supply arguments matching its schema, and inspect the server's actual response.

## Run locally

Requires Node.js 22.23.4 or newer and the official CLI:

```sh
npm install --global rea-agents@6.9.0
export REA_API_TOKEN="$(openssl rand -hex 32)"
npm start
```

## Deployment and security

Deploy the Dockerfile behind a platform-provided HTTPS reverse proxy. Configure `REA_API_TOKEN` as a secret with at least 32 random characters. Never expose `MCP_PORT` or the REA MCP listener publicly. The upstream MCP HTTP transport itself has no TLS or client authentication; this gateway supplies bearer authentication and must remain behind HTTPS.

Uploads are stored with restrictive permissions in the backend's temporary filesystem. They are not durable across ephemeral host restarts. The live CI smoke test verifies startup and tool discovery; a full analysis still requires a supported sample and any provider/tooling needed by the selected REA tool.
