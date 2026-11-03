// pi/extensions/usage/core.ts の単体テスト。test/pi-usage.bats から node --test で走らせる。

import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
	cachedQuery,
	CODEX_USAGE_URL,
	type Fetch,
	fetchCodexUsage,
	formatStatus,
	HttpError,
	nextBackoff,
	normalizeClaudeUsage,
	normalizeCodexUsage,
	parseClaudeRateLimitHeaders,
	RateLimited,
	readCache,
	recordWindows,
	settle,
	type Usage,
	windowLabel,
	writeCache,
} from "../pi/extensions/usage/core.ts";

const NOW = Date.parse("2026-11-03T12:00:00Z");
const HOUR = 60 * 60 * 1_000;

function cacheFile(): string {
	return join(mkdtempSync(join(tmpdir(), "pi-usage-test-")), "cache.json");
}

test("Claude's usage API puts 5h and 1w in the footer and the per-model weeks in details", () => {
	const usage = normalizeClaudeUsage({
		five_hour: { utilization: 23, resets_at: "2026-11-03T14:10:00Z" },
		seven_day: { utilization: 61, resets_at: null },
		seven_day_opus: { utilization: 40, resets_at: null },
		seven_day_sonnet: null,
		extra_usage: { is_enabled: true, utilization: 12.4 },
	});
	assert.deepEqual(usage.windows, [
		{ label: "5h", used: 23, resetsAt: Date.parse("2026-11-03T14:10:00Z") },
		{ label: "1w", used: 61 },
	]);
	assert.deepEqual(usage.details, [{ label: "1w Opus", used: 40 }]);
	assert.deepEqual(usage.notes, ["Extra usage 12% used"]);
});

test("the unified rate-limit headers are fractions with resets in Unix seconds", () => {
	const windows = parseClaudeRateLimitHeaders({
		"Anthropic-Ratelimit-Unified-5h-Utilization": "0.25",
		"anthropic-ratelimit-unified-5h-reset": String(NOW / 1_000 + 3_600),
		"anthropic-ratelimit-unified-7d-utilization": "0.5",
		"anthropic-ratelimit-unified-status": "allowed",
		"content-type": "text/event-stream",
	});
	assert.deepEqual(windows, [
		{ label: "5h", used: 25, resetsAt: NOW + HOUR },
		{ label: "1w", used: 50 },
	]);
});

test("headers without a usable window, or on a changed scale, are ignored", () => {
	assert.equal(parseClaudeRateLimitHeaders({ "content-type": "application/json" }), undefined);
	assert.equal(parseClaudeRateLimitHeaders({ "anthropic-ratelimit-unified-5h-utilization": "25" }), undefined);
});

test("Codex's plan-wide windows go to the footer, labelled by their length", () => {
	const usage = normalizeCodexUsage({
		rate_limit: {
			primary_window: { used_percent: 12, limit_window_seconds: 18_000, reset_at: NOW / 1_000 + 600 },
			secondary_window: { used_percent: 140, limit_window_seconds: 604_800, reset_at: null },
		},
		additional_rate_limits: [
			{ limit_name: "gpt-5.6-spark", rate_limit: { primary_window: { used_percent: 90, limit_window_seconds: 18_000 } } },
		],
		credits: { has_credits: true, balance: "5" },
	});
	assert.deepEqual(usage.windows, [
		{ label: "5h", used: 12, resetsAt: NOW + 600_000 },
		{ label: "1w", used: 100 },
	]);
	assert.deepEqual(usage.details, [{ label: "gpt-5.6-spark 5h", used: 90 }]);
	assert.deepEqual(usage.notes, ["Credits 5"]);
});

test("window lengths become compact labels", () => {
	assert.equal(windowLabel(18_000), "5h");
	assert.equal(windowLabel(604_800), "1w");
	assert.equal(windowLabel(2_592_000), "30d");
	assert.equal(windowLabel(90), "2m");
});

test("fetchCodexUsage sends pi's openai-codex authorization to the ChatGPT usage API", async () => {
	const requests: { url: string; init: RequestInit }[] = [];
	const fetchFn: Fetch = async (url, init) => {
		requests.push({ url, init });
		return new Response(JSON.stringify({ rate_limit: null }), { status: 200 });
	};
	const usage = await fetchCodexUsage("Bearer token", new AbortController().signal, fetchFn);
	assert.deepEqual(usage, { windows: [] });
	assert.equal(requests[0]?.url, CODEX_USAGE_URL);
	assert.equal((requests[0]?.init.headers as Record<string, string>).Authorization, "Bearer token");
});

test("a window past its reset counts from zero again", () => {
	const usage: Usage = { windows: [{ label: "5h", used: 80, resetsAt: NOW - 1 }, { label: "1w", used: 30, resetsAt: NOW + HOUR }] };
	assert.deepEqual(settle(usage, NOW).windows, [{ label: "5h", used: 0 }, { label: "1w", used: 30, resetsAt: NOW + HOUR }]);
});

test("the footer shows a bar per window in the chosen display mode", () => {
	const usage: Usage = { windows: [{ label: "5h", used: 23, resetsAt: NOW + 2 * HOUR + 10 * 60_000 }, { label: "1w", used: 85 }] };
	assert.equal(formatStatus(usage, "used", NOW), "5h ▰▰▱▱▱▱▱▱▱▱ 23% ↻2h10m · 1w ▰▰▰▰▰▰▰▰▱▱ 85%");
	assert.equal(formatStatus(usage, "remaining", NOW), "5h ▰▰▰▰▰▰▰▱▱▱ 77% ↻2h10m · 1w ▰▱▱▱▱▱▱▱▱▱ 15%");
	const colors: string[] = [];
	formatStatus(usage, "used", NOW, (color, text) => (colors.push(color), text));
	assert.deepEqual(colors, ["success", "error"]);
	assert.equal(formatStatus({ windows: [] }, "used", NOW), undefined);
});

test("a fresh shared result is used without fetching", async () => {
	const path = cacheFile();
	const usage: Usage = { windows: [{ label: "5h", used: 1 }] };
	writeCache(path, { usage, at: Date.now() });
	const result = await cachedQuery(path, 60_000, async () => assert.fail("fetched a fresh result"));
	assert.deepEqual(result, usage);
});

test("a 429 is shared as a wait that doubles, and the old value survives it", async () => {
	const path = cacheFile();
	const usage: Usage = { windows: [{ label: "5h", used: 1 }] };
	writeCache(path, { usage, at: 0 });
	await assert.rejects(cachedQuery(path, 60_000, async () => { throw new HttpError(429, undefined); }), RateLimited);
	const cache = readCache(path);
	assert.equal(cache.backoffMs, 2 * 60_000);
	assert.deepEqual(cache.usage, usage);
	await assert.rejects(cachedQuery(path, 60_000, async () => assert.fail("fetched while waiting")), RateLimited);
	assert.equal(nextBackoff(cache.backoffMs, undefined), 4 * 60_000);
	assert.equal(nextBackoff(15 * 60_000, undefined), 15 * 60_000);
	assert.equal(nextBackoff(undefined, 10 * 60_000), 10 * 60_000);
});

test("without credentials the last shared value is kept", async () => {
	const path = cacheFile();
	const usage: Usage = { windows: [{ label: "5h", used: 1 }] };
	writeCache(path, { usage, at: 0 });
	assert.deepEqual(await cachedQuery(path, 60_000, async () => undefined), usage);
	assert.equal(await cachedQuery(cacheFile(), 60_000, async () => undefined), undefined);
});

test("windows from response headers replace the footer but keep the API's details", () => {
	const path = cacheFile();
	writeCache(path, { usage: { windows: [{ label: "5h", used: 1 }], details: [{ label: "1w Opus", used: 2 }] }, at: 0, backoffMs: 120_000 });
	const usage = recordWindows(path, [{ label: "5h", used: 9 }]);
	assert.deepEqual(usage, { windows: [{ label: "5h", used: 9 }], details: [{ label: "1w Opus", used: 2 }] });
	const cache = readCache(path);
	assert.ok((cache.at ?? 0) > 0);
	assert.equal(cache.backoffMs, 120_000);
});
