# REA mobile backend

This service launches the official `rea-agents@6.9.0` MCP server on loopback and places an authenticated API gateway in front of its Streamable HTTP `/mcp` endpoint.

## Required environment

- `REA_API_TOKEN`: random secret with at least 32 characters.
- `PORT`: public service port (default 8787).
- `MCP_PORT`: private REA MCP port (default 8788).
- `MAX_UPLOAD_BYTES`: upload cap (default 300 MiB).

Deploy behind a platform-provided HTTPS reverse proxy. Never expose MCP_PORT or the REA MCP listener publicly. Do not use plain HTTP over an untrusted network.

## Routes

- `GET /health`: readiness status; no secret or filesystem paths are disclosed.
- `POST /api/upload?filename=...`: authenticated raw binary upload; returns an opaque upload id and local path for a subsequent REA MCP tool call.
- `POST /mcp` and related Streamable HTTP methods: authenticated pass-through to the official REA MCP server.

The upload endpoint stores files with restrictive permissions in the backend's temporary filesystem. This first version does not yet invoke an analysis tool automatically: callers must use the REA MCP catalog and its documented input schema. Uploads are not durable across ephemeral host restarts.

## Run locally

```sh
export REA_API_TOKEN="$(openssl rand -hex 32)"
npm start
```

Node.js 22.23.4 or newer in the Node 22 line is required by REA 6.9.0. The upstream MCP HTTP transport itself has no TLS or client authentication; this gateway supplies bearer authentication and must remain behind HTTPS.
