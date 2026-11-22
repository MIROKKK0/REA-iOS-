import assert from "node:assert/strict";
import test from "node:test";
import { startDiscoveryRetry } from "../rea-startup.js";

test("retries a transient MCP timeout and becomes ready after discovery", async () => {
  let attempts = 0;
  const states = [];
  const delays = [];
  const failures = [];

  const retry = startDiscoveryRetry({
    discover: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("MCP request timed out");
      return { tools: Array.from({ length: 255 }, (_, index) => ({ name: `tool_${index}` })) };
    },
    onState: state => states.push(state),
    onFailure: async error => failures.push(error.message),
    delays: [100, 200],
    sleep: async delay => delays.push(delay)
  });

  const result = await retry.done;
  assert.equal(attempts, 2);
  assert.deepEqual(delays, [100]);
  assert.deepEqual(failures, ["MCP request timed out"]);
  assert.equal(states[0].ready, false);
  assert.equal(states[1].ready, true);
  assert.equal(states[1].toolCount, 255);
  assert.equal(result.ready, true);
});

test("an empty MCP catalog is not marked ready", async () => {
  let attempts = 0;
  const retry = startDiscoveryRetry({
    discover: async () => {
      attempts += 1;
      return attempts === 1 ? { tools: [] } : { tools: [{ name: "inspect_web_page" }] };
    },
    onState: () => {},
    delays: [1],
    sleep: async () => {}
  });

  const result = await retry.done;
  assert.equal(attempts, 2);
  assert.equal(result.ready, true);
  assert.equal(result.toolCount, 1);
});
