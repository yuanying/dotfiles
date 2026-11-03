// サブスクリプションの利用率の取得・正規化・表示。pi に依存しない部分で、
// test/pi-usage.test.ts から直接読む。pi とのつなぎは index.ts。
//
// Claude と ChatGPT (Codex) の利用率を同じ形 (Usage) にそろえ、
// Claude Code の statusline (claude/statusline-command.sh) と同じ色付きのバーで出す。

import { readFileSync, renameSync, writeFileSync } from "node:fs";

export type DisplayMode = "used" | "remaining";

/** 1 つの利用枠。used は 0〜100 の消費率、resetsAt はリセット時刻 (epoch ミリ秒)。 */
export type Window = { label: string; used: number; resetsAt?: number };

/** windows はフッターに出す枠、details は /usage にだけ出す枠と補足。 */
export type Usage = { windows: Window[]; details?: Window[]; notes?: string[] };

export type Fetch = (url: string, init: RequestInit) => Promise<Response>;

export type Painter = (color: "success" | "warning" | "error", text: string) => string;

const TIMEOUT_MS = 15_000;
// 429 の後に待つ時間。続けて 429 が返るたびに倍にする。
const BACKOFF_MS = 2 * 60 * 1_000;
const MAX_BACKOFF_MS = 15 * 60 * 1_000;

export class HttpError extends Error {
	readonly status: number;
	readonly retryAfterMs: number | undefined;

	constructor(status: number, retryAfterMs: number | undefined) {
		super(`HTTP ${status}`);
		this.status = status;
		this.retryAfterMs = retryAfterMs;
	}
}

export class RateLimited extends Error {
	constructor(retryAt: number) {
		super(`レート制限中 (${new Date(retryAt).toLocaleTimeString()} まで待つ)`);
	}
}

// --- Claude ---------------------------------------------------------------

export const CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage";

type ClaudeWindow = { utilization?: number | null; resets_at?: string | null } | null | undefined;

export type ClaudeUsageResponse = {
	five_hour?: ClaudeWindow;
	seven_day?: ClaudeWindow;
	seven_day_opus?: ClaudeWindow;
	seven_day_sonnet?: ClaudeWindow;
	extra_usage?: { is_enabled?: boolean; utilization?: number | null } | null;
};

function claudeWindow(label: string, window: ClaudeWindow): Window[] {
	if (typeof window?.utilization !== "number") return [];
	const resetsAt = window.resets_at ? Date.parse(window.resets_at) : NaN;
	return [{ label, used: clampPercent(window.utilization), ...(Number.isFinite(resetsAt) ? { resetsAt } : {}) }];
}

/** Claude Code の /usage と同じ非公開エンドポイントの応答。utilization は 0〜100。 */
export function normalizeClaudeUsage(response: ClaudeUsageResponse): Usage {
	const notes: string[] = [];
	const extra = response.extra_usage;
	if (extra?.is_enabled && typeof extra.utilization === "number") {
		notes.push(`Extra usage ${Math.round(extra.utilization)}% used`);
	}
	return {
		windows: [...claudeWindow("5h", response.five_hour), ...claudeWindow("1w", response.seven_day)],
		details: [
			...claudeWindow("1w Opus", response.seven_day_opus),
			...claudeWindow("1w Sonnet", response.seven_day_sonnet),
		],
		...(notes.length > 0 ? { notes } : {}),
	};
}

const RATELIMIT_PREFIX = "anthropic-ratelimit-unified-";
// 0〜1 の割合で来る。大きく超えていたら単位が変わったとみなし、推測の % は出さない。
const MAX_UTILIZATION = 1.5;
// Unix 秒。ミリ秒の値ならこれを超える。
const MAX_EPOCH_SECONDS = 10_000_000_000;

/**
 * Anthropic の応答に付く anthropic-ratelimit-unified-* ヘッダー。pi-claude-bridge も
 * Claude Code の rate_limit_event を同じ名前のヘッダーに組み直して渡してくる。
 * 使える枠が無ければ undefined (前回の値をそのまま使う)。
 */
export function parseClaudeRateLimitHeaders(headers: Record<string, string | undefined>): Window[] | undefined {
	const lookup = new Map(Object.entries(headers).map(([name, value]) => [name.toLowerCase(), value]));
	const windows: Window[] = [];
	for (const [abbreviation, label] of [["5h", "5h"], ["7d", "1w"]] as const) {
		const utilization = parseNumber(lookup.get(`${RATELIMIT_PREFIX}${abbreviation}-utilization`));
		if (utilization === undefined || utilization < 0 || utilization > MAX_UTILIZATION) continue;
		const reset = parseNumber(lookup.get(`${RATELIMIT_PREFIX}${abbreviation}-reset`));
		windows.push({
			label,
			used: clampPercent(utilization * 100),
			...(reset !== undefined && reset > 0 && reset < MAX_EPOCH_SECONDS ? { resetsAt: reset * 1_000 } : {}),
		});
	}
	return windows.length > 0 ? windows : undefined;
}

export async function fetchClaudeUsage(token: string, signal: AbortSignal, fetchFn: Fetch = fetch): Promise<Usage> {
	const response = await fetchFn(CLAUDE_USAGE_URL, {
		headers: {
			Authorization: `Bearer ${token}`,
			"anthropic-beta": "oauth-2025-04-20",
			"Content-Type": "application/json",
		},
		signal: AbortSignal.any([signal, AbortSignal.timeout(TIMEOUT_MS)]),
	});
	if (!response.ok) throw httpError(response);
	return normalizeClaudeUsage((await response.json()) as ClaudeUsageResponse);
}

// --- Codex (ChatGPT) ------------------------------------------------------

export const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";

type CodexWindow = { used_percent?: unknown; limit_window_seconds?: unknown; reset_at?: unknown } | null | undefined;

type CodexRateLimit = { primary_window?: CodexWindow; secondary_window?: CodexWindow } | null | undefined;

export type CodexUsageResponse = {
	rate_limit?: CodexRateLimit;
	additional_rate_limits?: { limit_name?: unknown; rate_limit?: CodexRateLimit }[] | null;
	credits?: { has_credits?: boolean; unlimited?: boolean; balance?: unknown } | null;
};

/** 枠の長さを "5h" や "1w" にする。 */
export function windowLabel(seconds: number): string {
	const minutes = Math.ceil(seconds / 60);
	if (minutes % 10_080 === 0) return `${minutes / 10_080}w`;
	if (minutes % 1_440 === 0) return `${minutes / 1_440}d`;
	if (minutes % 60 === 0) return `${minutes / 60}h`;
	return `${minutes}m`;
}

function codexWindows(rateLimit: CodexRateLimit, prefix = ""): Window[] {
	return [rateLimit?.primary_window, rateLimit?.secondary_window].flatMap((window) => {
		const used = parseNumber(window?.used_percent);
		const seconds = parseNumber(window?.limit_window_seconds);
		if (used === undefined || seconds === undefined || seconds <= 0) return [];
		const reset = parseNumber(window?.reset_at);
		return [{
			label: `${prefix}${windowLabel(seconds)}`,
			used: clampPercent(used),
			...(reset !== undefined && reset > 0 && reset < MAX_EPOCH_SECONDS ? { resetsAt: reset * 1_000 } : {}),
		}];
	});
}

/** ChatGPT のプラン全体の枠 (rate_limit) をフッターに、モデル別の枠を details に置く。 */
export function normalizeCodexUsage(response: CodexUsageResponse): Usage {
	const details = (response.additional_rate_limits ?? []).flatMap((limit) =>
		typeof limit?.limit_name === "string" ? codexWindows(limit.rate_limit, `${limit.limit_name} `) : [],
	);
	const notes: string[] = [];
	const credits = response.credits;
	if (credits?.has_credits) {
		const balance = parseNumber(credits.balance);
		notes.push(`Credits ${credits.unlimited ? "unlimited" : (balance ?? "available")}`);
	}
	return {
		windows: codexWindows(response.rate_limit),
		...(details.length > 0 ? { details } : {}),
		...(notes.length > 0 ? { notes } : {}),
	};
}

export async function fetchCodexUsage(authorization: string, signal: AbortSignal, fetchFn: Fetch = fetch): Promise<Usage> {
	const response = await fetchFn(CODEX_USAGE_URL, {
		headers: { Accept: "application/json", Authorization: authorization },
		redirect: "error",
		signal: AbortSignal.any([signal, AbortSignal.timeout(TIMEOUT_MS)]),
	});
	if (!response.ok) throw httpError(response);
	return normalizeCodexUsage((await response.json()) as CodexUsageResponse);
}

// --- 表示 -----------------------------------------------------------------

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

export function progressBar(percent: number): string {
	const filled = Math.min(10, Math.max(0, Math.floor(percent / 10)));
	return "▰".repeat(filled) + "▱".repeat(10 - filled);
}

function displayPercent(window: Window, mode: DisplayMode): number {
	return Math.round(mode === "used" ? window.used : 100 - window.used);
}

/**
 * 利用率は取得したときの値なので、リセット時刻を過ぎた枠は 0% から数え直す。
 * 古い % を出し続けると、次に取れるまで使いすぎに見える。
 */
export function settle(usage: Usage, now: number): Usage {
	const reset = (window: Window): Window =>
		window.resetsAt !== undefined && window.resetsAt <= now ? { label: window.label, used: 0 } : window;
	return { ...usage, windows: usage.windows.map(reset), ...(usage.details ? { details: usage.details.map(reset) } : {}) };
}

// "5h ▰▰▱▱▱▱▱▱▱▱ 23% ↻2h10m" の形。色は表示モードに関係なく消費した割合で
// statusline と同じ閾値 (50% / 80%) で決める。
export function formatGauge(window: Window, mode: DisplayMode, now: number, paint: Painter): string {
	const percent = displayPercent(window, mode);
	const color = window.used < 50 ? "success" : window.used < 80 ? "warning" : "error";
	const countdown = window.resetsAt === undefined ? undefined : formatCountdown(window.resetsAt - now);
	const gauge = paint(color, `${progressBar(percent)} ${percent}%`);
	return countdown ? `${window.label} ${gauge} ↻${countdown}` : `${window.label} ${gauge}`;
}

export function formatStatus(
	usage: Usage,
	mode: DisplayMode,
	now: number,
	paint: Painter = (_color, text) => text,
): string | undefined {
	const settled = settle(usage, now);
	if (settled.windows.length === 0) return undefined;
	return settled.windows.map((window) => formatGauge(window, mode, now, paint)).join(" · ");
}

export function formatDetails(title: string, usage: Usage, mode: DisplayMode, now: number, capturedAt?: number): string {
	const settled = settle(usage, now);
	const lines = [...settled.windows, ...(settled.details ?? [])].map((window) => {
		const countdown = window.resetsAt === undefined ? undefined : formatCountdown(window.resetsAt - now);
		const text = `${window.label} ${displayPercent(window, mode)}%${countdown ? ` ↻${countdown}` : ""}`;
		return window.resetsAt === undefined ? text : `${text} (${new Date(window.resetsAt).toLocaleString()})`;
	});
	lines.push(...(settled.notes ?? []));
	if (lines.length === 0) return `${title}: 利用率が返らなかった`;
	const heading = `${title} (${mode})${capturedAt ? ` ${new Date(capturedAt).toLocaleTimeString()} 時点` : ""}`;
	return [heading, ...lines].join("\n");
}

// --- セッションの間で共有するキャッシュ -----------------------------------

/**
 * 利用率の API はレート制限が厳しく、herdr の worker など複数のセッションが同じ
 * アカウントで叩く。取得結果と 429 の後の待ち時間はファイルに置いて共有する。
 */
export type Cache = { usage?: Usage; at?: number; retryAt?: number; backoffMs?: number };

export function readCache(path: string): Cache {
	try {
		return JSON.parse(readFileSync(path, "utf8")) as Cache;
	} catch {
		return {};
	}
}

// 他のセッションが読みかけのファイルを壊さないよう、別名で書いてから置き換える。
export function writeCache(path: string, cache: Cache): void {
	const tmp = `${path}.${process.pid}.tmp`;
	try {
		writeFileSync(tmp, JSON.stringify(cache));
		renameSync(tmp, path);
	} catch {
		// 書けなくても、このセッションの次の取得まで困らない。
	}
}

// 429 の後にいつまで待つか。retry-after があればそれと比べて長い方を取る。
export function nextBackoff(previousMs: number | undefined, retryAfterMs: number | undefined): number {
	const doubled = previousMs ? Math.min(MAX_BACKOFF_MS, previousMs * 2) : BACKOFF_MS;
	return Math.max(doubled, retryAfterMs ?? 0);
}

/**
 * 共有の取得結果が maxAgeMs より新しければそれを返し、古ければ fetcher で取りに行く。
 * fetcher が undefined を返したら (認証が無いなど) 前回の値を返す。
 * 429 の後の待ち時間の間は取りに行かず RateLimited を投げる。
 */
export async function cachedQuery(
	path: string,
	maxAgeMs: number,
	fetcher: () => Promise<Usage | undefined>,
): Promise<Usage | undefined> {
	const cache = readCache(path);
	const now = Date.now();
	if (cache.usage && cache.at && now - cache.at < maxAgeMs) return cache.usage;
	if (cache.retryAt && now < cache.retryAt) throw new RateLimited(cache.retryAt);
	try {
		const usage = await fetcher();
		if (!usage) return cache.usage;
		writeCache(path, { usage, at: Date.now() });
		return usage;
	} catch (error) {
		if (error instanceof HttpError && error.status === 429) {
			const backoffMs = nextBackoff(cache.backoffMs, error.retryAfterMs);
			const retryAt = Date.now() + backoffMs;
			writeCache(path, { ...readCache(path), retryAt, backoffMs });
			throw new RateLimited(retryAt);
		}
		throw error;
	}
}

/** 応答ヘッダーで知ったフッターの枠を、API で取った details を残したまま書き込む。 */
export function recordWindows(path: string, windows: Window[]): Usage {
	const cache = readCache(path);
	const usage: Usage = { ...cache.usage, windows };
	writeCache(path, { ...cache, usage, at: Date.now() });
	return usage;
}

function httpError(response: Response): HttpError {
	const retryAfter = Number(response.headers.get("retry-after"));
	return new HttpError(response.status, retryAfter > 0 ? retryAfter * 1_000 : undefined);
}

function parseNumber(value: unknown): number | undefined {
	if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
	if (typeof value !== "string" || !value.trim()) return undefined;
	const parsed = Number(value);
	return Number.isFinite(parsed) ? parsed : undefined;
}

function clampPercent(value: number): number {
	return Math.min(100, Math.max(0, value));
}
