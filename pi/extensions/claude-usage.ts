// claude-bridge (pi-claude-agent-sdk) と anthropic で Claude サブスクリプションの
// 5 時間・週間の利用率をフッターに出す。@specode/pi-subscription-usage が
// Anthropic に対応していないための補完で、displayMode はそちらに揃える。
// 利用率は Claude Code の statusline (claude/statusline-command.sh) と同じく
// 色付きのバーで出す。
//
// 取得先は Claude Code の /usage と同じ非公開エンドポイント。認証は claude-bridge と
// 同じく pi の anthropic 認証 (/login anthropic) だけを使い、~/.claude は読まない。

import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { getAgentDir } from "@earendil-works/pi-coding-agent";

const PROVIDERS = new Set(["claude-bridge", "anthropic"]);
const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
const STATUS_KEY = "claude-usage";
const REFRESH_MS = 5 * 60 * 1_000;
const TIMEOUT_MS = 15_000;

type Window = { utilization?: number | null; resets_at?: string | null } | null | undefined;

type UsageResponse = {
	five_hour?: Window;
	seven_day?: Window;
	seven_day_opus?: Window;
	seven_day_sonnet?: Window;
	extra_usage?: {
		is_enabled?: boolean;
		monthly_limit?: number | null;
		used_credits?: number | null;
		utilization?: number | null;
	} | null;
};

type DisplayMode = "used" | "remaining";

type Painter = (color: "success" | "warning" | "error", text: string) => string;

export function formatCountdown(ms: number): string | undefined {
	if (!Number.isFinite(ms) || ms <= 0) return undefined;
	const minutes = Math.floor(ms / 60_000);
	if (minutes < 1) return "<1m";
	const days = Math.floor(minutes / 1_440);
	const hours = Math.floor((minutes % 1_440) / 60);
	const mins = minutes % 60;
	if (days > 0) return `${days}d${hours}h`;
	if (hours > 0) return `${hours}h${mins}m`;
	return `${mins}m`;
}

export function formatWindow(label: string, window: Window, mode: DisplayMode, now: number): string | undefined {
	if (typeof window?.utilization !== "number") return undefined;
	const used = Math.min(100, Math.max(0, window.utilization));
	const percent = Math.round(mode === "used" ? used : 100 - used);
	const resetsAt = window.resets_at ? Date.parse(window.resets_at) : NaN;
	const countdown = formatCountdown(resetsAt - now);
	return countdown ? `${label} ${percent}% ↻${countdown}` : `${label} ${percent}%`;
}

export function progressBar(percent: number): string {
	const filled = Math.min(10, Math.max(0, Math.floor(percent / 10)));
	return "▰".repeat(filled) + "▱".repeat(10 - filled);
}

// "5h ▰▰▱▱▱▱▱▱▱▱ 23% ↻2h10m" の形。色は表示モードに関係なく消費した割合で
// statusline と同じ閾値 (50% / 80%) で決める。
export function formatGauge(
	label: string,
	window: Window,
	mode: DisplayMode,
	now: number,
	paint: Painter,
): string | undefined {
	if (typeof window?.utilization !== "number") return undefined;
	const used = Math.min(100, Math.max(0, window.utilization));
	const percent = Math.round(mode === "used" ? used : 100 - used);
	const color = used < 50 ? "success" : used < 80 ? "warning" : "error";
	const resetsAt = window.resets_at ? Date.parse(window.resets_at) : NaN;
	const countdown = formatCountdown(resetsAt - now);
	const gauge = paint(color, `${progressBar(percent)} ${percent}%`);
	return countdown ? `${label} ${gauge} ↻${countdown}` : `${label} ${gauge}`;
}

export function formatStatus(
	usage: UsageResponse,
	mode: DisplayMode,
	now: number,
	paint: Painter = (_color, text) => text,
): string | undefined {
	const parts = [
		formatGauge("5h", usage.five_hour, mode, now, paint),
		formatGauge("1w", usage.seven_day, mode, now, paint),
	].filter((part): part is string => part !== undefined);
	return parts.length > 0 ? parts.join(" · ") : undefined;
}

export function formatDetails(usage: UsageResponse, mode: DisplayMode, now: number): string {
	const rows: [string, Window][] = [
		["5h", usage.five_hour],
		["1w", usage.seven_day],
		["1w Opus", usage.seven_day_opus],
		["1w Sonnet", usage.seven_day_sonnet],
	];
	const lines = rows.flatMap(([label, window]) => {
		const text = formatWindow(label, window, mode, now);
		if (!text) return [];
		const resetsAt = window?.resets_at ? new Date(window.resets_at) : undefined;
		return [resetsAt ? `${text} (${resetsAt.toLocaleString()})` : text];
	});
	const extra = usage.extra_usage;
	if (extra?.is_enabled && typeof extra.utilization === "number") {
		lines.push(`Extra usage ${Math.round(extra.utilization)}% used`);
	}
	const heading = mode === "used" ? "Claude usage (used)" : "Claude usage (remaining)";
	return lines.length > 0 ? [heading, ...lines].join("\n") : "Claude usage: 利用率が返らなかった";
}

// @specode/pi-subscription-usage と同じ設定ファイルを読み、表示を揃える。
function loadDisplayMode(): DisplayMode {
	try {
		const config = JSON.parse(readFileSync(join(getAgentDir(), "subscription-usage.json"), "utf8"));
		return config?.displayMode === "used" ? "used" : "remaining";
	} catch {
		return "remaining";
	}
}

// pi-claude-agent-sdk の buildClaudeChildEnv と同じ読み方で OAuth トークンを取り出す。
// API キーには利用率がないので undefined を返す。
async function resolveOAuthToken(ctx: ExtensionContext): Promise<string | undefined> {
	const resolved = await ctx.modelRegistry.getProviderAuth("anthropic");
	if (!resolved) return undefined;
	const headers = Object.entries(resolved.auth.headers ?? {});
	const authorization = headers.find(([name]) => name.toLowerCase() === "authorization")?.[1];
	const bearer = typeof authorization === "string" ? authorization.match(/^Bearer\s+(.+)$/i)?.[1] : undefined;
	if (bearer) return bearer;
	if (resolved.source?.toLowerCase().includes("oauth")) return resolved.auth.apiKey;
	return undefined;
}

async function fetchUsage(token: string, signal: AbortSignal): Promise<UsageResponse> {
	const response = await fetch(USAGE_URL, {
		headers: {
			Authorization: `Bearer ${token}`,
			"anthropic-beta": "oauth-2025-04-20",
			"Content-Type": "application/json",
		},
		signal: AbortSignal.any([signal, AbortSignal.timeout(TIMEOUT_MS)]),
	});
	if (!response.ok) throw new Error(`HTTP ${response.status}`);
	return (await response.json()) as UsageResponse;
}

export default function claudeUsage(pi: ExtensionAPI): void {
	let displayMode: DisplayMode = "remaining";
	let last: { usage: UsageResponse; at: number } | undefined;
	let timer: ReturnType<typeof setTimeout> | undefined;
	let controller: AbortController | undefined;

	const active = (ctx: ExtensionContext) => PROVIDERS.has(ctx.model?.provider ?? "");

	function showUsage(ctx: ExtensionContext, usage: UsageResponse | undefined): void {
		const theme = ctx.ui.theme;
		const paint: Painter = (color, text) => theme.fg(color, text);
		ctx.ui.setStatus(STATUS_KEY, usage && formatStatus(usage, displayMode, Date.now(), paint));
	}

	function stop(ctx: ExtensionContext): void {
		if (timer) clearTimeout(timer);
		timer = undefined;
		controller?.abort();
		controller = undefined;
		ctx.ui.setStatus(STATUS_KEY, undefined);
	}

	async function query(ctx: ExtensionContext): Promise<UsageResponse | undefined> {
		controller?.abort();
		const current = new AbortController();
		controller = current;
		try {
			const token = await resolveOAuthToken(ctx);
			if (!token) return undefined;
			const usage = await fetchUsage(token, current.signal);
			last = { usage, at: Date.now() };
			return usage;
		} finally {
			if (controller === current) controller = undefined;
		}
	}

	async function refresh(ctx: ExtensionContext, force: boolean): Promise<void> {
		if (!active(ctx)) {
			stop(ctx);
			return;
		}
		if (timer) clearTimeout(timer);
		timer = setTimeout(() => void refresh(ctx, true), REFRESH_MS);
		try {
			const usage = !force && last && Date.now() - last.at < REFRESH_MS ? last.usage : await query(ctx);
			if (active(ctx)) showUsage(ctx, usage);
		} catch (error) {
			if ((error as Error)?.name === "AbortError") return;
			if (active(ctx)) ctx.ui.setStatus(STATUS_KEY, "claude usage error");
		}
	}

	pi.on("session_start", async (_event, ctx) => {
		displayMode = loadDisplayMode();
		void refresh(ctx, false);
	});
	pi.on("model_select", async (_event, ctx) => void refresh(ctx, false));
	pi.on("agent_end", async (_event, ctx) => void refresh(ctx, true));
	pi.on("session_shutdown", async (_event, ctx) => stop(ctx));

	pi.registerCommand("claude-usage", {
		description: "Claude サブスクリプションの 5 時間・週間の利用率を表示する",
		handler: async (_args, ctx) => {
			try {
				const usage = await query(ctx);
				if (!usage) {
					ctx.ui.notify("anthropic の OAuth 認証がない (/login anthropic)", "warning");
					return;
				}
				if (active(ctx)) showUsage(ctx, usage);
				ctx.ui.notify(formatDetails(usage, displayMode, Date.now()), "info");
			} catch (error) {
				ctx.ui.notify(`Claude usage の取得に失敗した: ${(error as Error)?.message ?? error}`, "error");
			}
		},
	});
}
