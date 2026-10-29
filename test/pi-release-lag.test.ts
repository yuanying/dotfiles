// pi/extensions/release-lag/client.ts の単体テスト。test/pi-release-lag.bats から node --test で走らせる。

import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { call, type Fetch, readToken, type Report } from "../pi/extensions/release-lag/client.ts";

const REPORT: Report = {
	owner: "yuanying",
	refreshedAt: "2026-10-29T12:00:00Z",
	lastAttemptAt: "2026-10-29T12:00:00Z",
	lastSuccess: true,
	lastError: "",
	repositories: [],
};

function tokenFile(content: string, mode: number): string {
	const path = join(mkdtempSync(join(tmpdir(), "pi-release-lag-test-")), "token");
	writeFileSync(path, content);
	chmodSync(path, mode);
	return path;
}

function fake(status: number, body: unknown = REPORT) {
	const requests: { url: string; init: RequestInit }[] = [];
	const fetch: Fetch = async (url, init) => {
		requests.push({ url, init });
		return new Response(JSON.stringify(body), { status });
	};
	return { fetch, requests };
}

test("readToken reads a private token file and trims it", () => {
	assert.equal(readToken(tokenFile("secret\n", 0o600)), "secret");
});

test("readToken refuses a token file others can read, without showing the token", () => {
	assert.throws(() => readToken(tokenFile("secret", 0o644)), (error: Error) => {
		assert.match(error.message, /chmod 0600/);
		assert.doesNotMatch(error.message, /secret/);
		return true;
	});
});

test("readToken refuses an empty or missing token file", () => {
	assert.throws(() => readToken(tokenFile("\n", 0o600)), /is empty/);
	assert.throws(() => readToken("/nonexistent/token"), /ENOENT/);
});

test("call sends the token as Bearer and refuses redirects", async () => {
	const { fetch, requests } = fake(200);
	const got = await call("GET", "/api/repos", { token: "secret", fetch, baseUrl: "https://example.test" });
	assert.deepEqual(got, { ok: true, report: REPORT });
	assert.equal(requests[0].url, "https://example.test/api/repos");
	assert.equal(requests[0].init.method, "GET");
	assert.equal(requests[0].init.redirect, "manual");
	assert.equal((requests[0].init.headers as Record<string, string>).Authorization, "Bearer secret");
});

test("call returns the report of a failed refresh (502) as not ok", async () => {
	const failed = { ...REPORT, lastSuccess: false, lastError: "rate limited" };
	const got = await call("POST", "/api/refresh", { token: "secret", fetch: fake(502, failed).fetch });
	assert.deepEqual(got, { ok: false, report: failed });
});

test("call throws on 502 for GET, on refused tokens, and on other statuses, without showing the token", async () => {
	for (const [method, path, status, pattern] of [
		["GET", "/api/repos", 502, /answered 502/],
		["GET", "/api/repos", 401, /refused the token \(401\).*issue a new token/],
		["POST", "/api/refresh", 403, /refused the token \(403\)/],
		["GET", "/api/repos", 302, /answered 302/],
	] as const) {
		await assert.rejects(call(method, path, { token: "secret", fetch: fake(status, "x").fetch }), (error: Error) => {
			assert.match(error.message, pattern);
			assert.doesNotMatch(error.message, /secret/);
			return true;
		});
	}
});
