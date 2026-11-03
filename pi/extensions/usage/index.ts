// Claude と ChatGPT (Codex) のサブスクリプションの利用率をフッターに色付きのバーで
// 出し、/usage で詳細を見せる。取得と表示は core.ts。
//
// - Claude (anthropic / claude-bridge): Claude Code の /usage と同じ非公開 API を
//   pi の anthropic 認証 (/login anthropic) で読む。応答に付く
//   anthropic-ratelimit-unified-* ヘッダーでも更新する。pi-claude-bridge は
//   Claude Code の報告をこのヘッダーにして渡してくるので、anthropic 認証の無い
//   ホストでも最初の応答の後から出る。~/.claude は読まない。
// - Codex (openai / openai-codex): ChatGPT の非公開 API を openai-codex の認証
//   (/login openai-codex) で読む。openai の ChatGPT 認証はこの API に拒まれるため、
//   モデルが openai でも openai-codex の認証を使う。フッターはプラン全体の枠。
//
// 取得結果は ~/.pi/agent/usage-cache-<名前>.json に置いて全セッションで共有する。

import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import {
	cachedQuery,
	type DisplayMode,
	fetchClaudeUsage,
	fetchCodexUsage,
	formatDetails,
	formatStatus,
	type Painter,
	parseClaudeRateLimitHeaders,
	readCache,
	recordWindows,
	type Usage,
} from "./core.ts";

const STATUS_KEY = "usage";
const CONFIG_FILE = "usage.json";
const REFRESH_MS = 5 * 60 * 1_000;
// リセットまでのカウントダウンと、他のセッションが取った値を拾うための描き直しの間隔。
// 取りに行くのは共有の値が REFRESH_MS より古いときだけ。
const TICK_MS = 60 * 1_000;
const CODEX_ORIGIN = "https://chatgpt.com";

type Source = {
	name: string;
	title: string;
	// 認証が無ければ undefined を返す。
	fetch: (ctx: ExtensionContext, signal: AbortSignal) => Promise<Usage | undefined>;
	missingAuth: string;
};

const CLAUDE: Source = {
	name: "claude",
	title: "Claude usage",
	fetch: async (ctx, signal) => {
		const token = await claudeOAuthToken(ctx);
		return token ? fetchClaudeUsage(token, signal) : undefined;
	},
	missingAuth: "anthropic の OAuth 認証がない (/login anthropic)",
};

const CODEX: Source = {
	name: "codex",
	title: "ChatGPT usage",
	fetch: async (ctx, signal) => {
		const authorization = await codexAuthorization(ctx);
		return authorization ? fetchCodexUsage(authorization, signal) : undefined;
	},
	missingAuth: "openai-codex の認証がない (/login openai-codex)",
};

const SOURCES: Record<string, Source> = {
	anthropic: CLAUDE,
	"claude-bridge": CLAUDE,
	openai: CODEX,
	"openai-codex": CODEX,
};

function cachePath(source: Source): string {
	return join(getAgentDir(), `usage-cache-${source.name}.json`);
}

function loadDisplayMode(): DisplayMode {
	try {
		const config = JSON.parse(readFileSync(join(getAgentDir(), CONFIG_FILE), "utf8"));
		return config?.displayMode === "used" ? "used" : "remaining";
	} catch {
		return "remaining";
	}
}

function bearer(headers: Record<string, string | null | undefined> | undefined): string | undefined {
	const authorization = Object.entries(headers ?? {}).find(([name]) => name.toLowerCase() === "authorization")?.[1];
	return typeof authorization === "string" ? authorization.match(/^Bearer\s+(.+)$/i)?.[1] : undefined;
}

// API キーには利用率がないので undefined を返す。
async function claudeOAuthToken(ctx: ExtensionContext): Promise<string | undefined> {
	const resolved = await ctx.modelRegistry.getProviderAuth("anthropic");
	if (!resolved) return undefined;
	const token = bearer(resolved.auth.headers);
	if (token) return token;
	if (resolved.source?.toLowerCase().includes("oauth")) return resolved.auth.apiKey;
	return undefined;
}

// プロキシ向けに解決された認証は ChatGPT に送らない。
async function codexAuthorization(ctx: ExtensionContext): Promise<string | undefined> {
	const resolved = await ctx.modelRegistry.getProviderAuth("openai-codex");
	if (!resolved) return undefined;
	if (resolved.auth.baseUrl && !resolved.auth.baseUrl.startsWith(CODEX_ORIGIN)) return undefined;
	const token = bearer(resolved.auth.headers) ?? resolved.auth.apiKey;
	return token ? `Bearer ${token}` : undefined;
}

export default function usage(pi: ExtensionAPI): void {
	let displayMode: DisplayMode = "remaining";
	let timer: ReturnType<typeof setInterval> | undefined;
	let controller: AbortController | undefined;

	const sourceOf = (ctx: ExtensionContext) => SOURCES[ctx.model?.provider ?? ""];

	function show(ctx: ExtensionContext, value: Usage | undefined): void {
		const theme = ctx.ui.theme;
		const paint: Painter = (color, text) => theme.fg(color, text);
		ctx.ui.setStatus(STATUS_KEY, value && formatStatus(value, displayMode, Date.now(), paint));
	}

	async function query(ctx: ExtensionContext, source: Source, maxAgeMs: number): Promise<Usage | undefined> {
		controller?.abort();
		const current = new AbortController();
		controller = current;
		try {
			return await cachedQuery(cachePath(source), maxAgeMs, () => source.fetch(ctx, current.signal));
		} finally {
			if (controller === current) controller = undefined;
		}
	}

	async function refresh(ctx: ExtensionContext): Promise<void> {
		const source = sourceOf(ctx);
		if (!source) {
			ctx.ui.setStatus(STATUS_KEY, undefined);
			return;
		}
		try {
			const value = await query(ctx, source, REFRESH_MS);
			if (sourceOf(ctx) === source) show(ctx, value);
		} catch (error) {
			if ((error as Error)?.name === "AbortError" || sourceOf(ctx) !== source) return;
			// 取れない間は前回の値を出す。
			const cached = readCache(cachePath(source)).usage;
			if (cached) show(ctx, cached);
			else ctx.ui.setStatus(STATUS_KEY, `${source.name} usage error`);
		}
	}

	function stop(ctx: ExtensionContext): void {
		if (timer) clearInterval(timer);
		timer = undefined;
		controller?.abort();
		controller = undefined;
		ctx.ui.setStatus(STATUS_KEY, undefined);
	}

	pi.on("session_start", async (_event, ctx) => {
		if (!ctx.hasUI) return;
		displayMode = loadDisplayMode();
		if (timer) clearInterval(timer);
		timer = setInterval(() => void refresh(ctx), TICK_MS);
		void refresh(ctx);
	});
	pi.on("model_select", async (_event, ctx) => {
		if (ctx.hasUI) void refresh(ctx);
	});
	pi.on("after_provider_response", (event, ctx) => {
		if (!ctx.hasUI || sourceOf(ctx) !== CLAUDE) return;
		const windows = parseClaudeRateLimitHeaders(event.headers);
		if (windows) show(ctx, recordWindows(cachePath(CLAUDE), windows));
	});
	pi.on("session_shutdown", async (_event, ctx) => stop(ctx));

	pi.registerCommand("usage", {
		description: "Claude / ChatGPT サブスクリプションの利用率を取り直して詳しく表示する",
		handler: async (_args, ctx) => {
			const source = sourceOf(ctx);
			if (!source) {
				ctx.ui.notify(`${ctx.model?.provider ?? "モデル未選択"} の利用率には対応していない`, "warning");
				return;
			}
			const path = cachePath(source);
			try {
				const value = await query(ctx, source, 0);
				if (!value) {
					ctx.ui.notify(source.missingAuth, "warning");
					return;
				}
				show(ctx, value);
				ctx.ui.notify(formatDetails(source.title, value, displayMode, Date.now(), readCache(path).at), "info");
			} catch (error) {
				const message = `${source.title} の取得に失敗した: ${(error as Error)?.message ?? error}`;
				const cache = readCache(path);
				if (cache.usage) {
					const details = formatDetails(source.title, cache.usage, displayMode, Date.now(), cache.at);
					ctx.ui.notify(`${message}\n前回の値:\n${details}`, "warning");
					return;
				}
				ctx.ui.notify(message, "error");
			}
		},
	});
}
