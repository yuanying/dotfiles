import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const STATUS = "codex-weekly";
const INTERVAL_MS = 5 * 60 * 1000;
const USAGE_URL = "https://chatgpt.com/backend-api/codex/usage";

type Usage = {
  rate_limit?: { secondary_window?: { used_percent?: number; reset_at?: number } };
};

export function weeklyStatus(usage: Usage): string | undefined {
  const window = usage.rate_limit?.secondary_window;
  if (!window || typeof window.used_percent !== "number" || !Number.isFinite(window.used_percent)) return;
  const percent = Math.max(0, Math.min(100, Math.round(window.used_percent)));
  const reset = window.reset_at && Number.isFinite(window.reset_at)
    ? ` · resets ${new Date(window.reset_at * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}`
    : "";
  return `Weekly: ${percent}% used${reset}`;
}

function accountId(token: string): string | undefined {
  try {
    const payload = token.split(".")[1];
    if (!payload) return;
    const claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    return claims["https://api.openai.com/auth"]?.chatgpt_account_id;
  } catch {
    return;
  }
}

export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setInterval> | undefined;
  let generation = 0;

  async function refresh(ctx: ExtensionContext) {
    const current = ++generation;
    if (ctx.mode !== "tui" || ctx.model?.provider !== "openai-codex") {
      ctx.ui.setStatus(STATUS, undefined);
      return;
    }
    try {
      const auth = await ctx.modelRegistry.getApiKeyAndHeaders(ctx.model);
      if (!auth.ok || !auth.apiKey) throw new Error("No Codex OAuth token");
      const account = auth.headers?.["chatgpt-account-id"] ?? accountId(auth.apiKey);
      const headers: Record<string, string> = { Authorization: `Bearer ${auth.apiKey}` };
      if (account) headers["chatgpt-account-id"] = account;
      const response = await fetch(USAGE_URL, { headers, signal: AbortSignal.timeout(8000) });
      if (!response.ok) throw new Error(`Usage request failed: ${response.status}`);
      const label = weeklyStatus(await response.json() as Usage);
      if (current === generation) ctx.ui.setStatus(STATUS, label ?? "Weekly: unavailable");
    } catch {
      if (current === generation) ctx.ui.setStatus(STATUS, "Weekly: unavailable");
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    await refresh(ctx);
    if (timer) clearInterval(timer);
    timer = ctx.mode === "tui" ? setInterval(() => void refresh(ctx), INTERVAL_MS) : undefined;
  });
  pi.on("model_select", async (_event, ctx) => { await refresh(ctx); });
  pi.on("session_shutdown", (_event, ctx) => {
    ++generation;
    if (timer) clearInterval(timer);
    timer = undefined;
    ctx.ui.setStatus(STATUS, undefined);
  });
}
