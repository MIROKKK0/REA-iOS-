const DEFAULT_RETRY_DELAYS_MS = [10_000, 30_000, 60_000, 120_000, 300_000];

export function startDiscoveryRetry({
  discover,
  onState,
  onFailure = async () => {},
  delays = DEFAULT_RETRY_DELAYS_MS,
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
}) {
  let stopped = false;
  let attempts = 0;

  const done = (async () => {
    while (!stopped) {
      try {
        const result = await discover();
        const tools = Array.isArray(result?.tools) ? result.tools : [];
        if (tools.length === 0) {
          throw new Error("REA MCP returned an empty tools catalog");
        }
        const state = {
          ready: true,
          toolCount: tools.length,
          checkedAt: new Date().toISOString(),
          error: null
        };
        onState(state);
        return state;
      } catch (error) {
        const state = {
          ready: false,
          toolCount: 0,
          checkedAt: new Date().toISOString(),
          error: String(error?.message || error).slice(0, 1000)
        };
        onState(state);
        try {
          await onFailure(error);
        } catch {}
        if (stopped) break;
        const delay = delays[Math.min(attempts, delays.length - 1)] ?? 300_000;
        attempts += 1;
        await sleep(delay);
      }
    }
    return { ready: false, toolCount: 0, checkedAt: new Date().toISOString(), error: "discovery_stopped" };
  })();

  return {
    done,
    stop() {
      stopped = true;
    }
  };
}
