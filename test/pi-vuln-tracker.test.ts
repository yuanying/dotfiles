// pi/extensions/vuln-tracker/client.ts の単体テスト。test/pi-vuln-tracker.bats から node --test で走らせる。

import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BASE_URL, type Fetch, getFindings, readToken, type Report } from "../pi/extensions/vuln-tracker/client.ts";

// TASK の契約 F の例。
const REPORT: Report = {
	generatedAt: "2026-10-29T12:00:00Z",
	severities: ["CRITICAL", "HIGH"],
	findings: [
		{
			image: "ghcr.io/yuanying/hshelf",
			tag: "v1.2.3",
			digest: "sha256:0123",
			vulnerabilityID: "CVE-2026-33210",
			severity: "HIGH",
			package: "json",
			installedVersion: "2.18.0",
			fixedVersion: "2.18.1",
			selfBuilt: true,
			sourceRepository: "yuanying/hshelf",
			stage: "fixed-in-main",
			source: {
				state: "pr-open",
				pullRequests: [
					{
						url: "https://github.com/yuanying/hshelf/pull/12",
						repository: "yuanying/hshelf",
						number: 12,
						title: "Bump json to 2.18.1",
						state: "open",
						author: "fraction-vuln-responder[bot]",
						link: "vuln-responder",
					},
				],
			},
			manifest: { state: "no-fix", repository: "yuanying/fleet-infra", pullRequests: [] },
			vex: { state: "none", status: null, reviewBy: null, document: null },
			workloads: [{ namespace: "hshelf", kind: "Deployment", name: "hshelf", container: "app" }],
			firstSeenAt: "2026-10-27T03:00:00Z",
		},
	],
};

function tokenFile(content: string, mode: number): string {
	const path = join(mkdtempSync(join(tmpdir(), "pi-vuln-tracker-test-")), "token");
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

test("the API lives at vuln-tracker.fraction.jp", () => {
	assert.equal(BASE_URL, "https://vuln-tracker.fraction.jp");
});

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

test("getFindings GETs /api/findings with the token as Bearer and refuses redirects", async () => {
	const { fetch, requests } = fake(200);
	assert.deepEqual(await getFindings({ token: "secret", fetch, baseUrl: "https://example.test" }), REPORT);
	assert.equal(requests.length, 1);
	assert.equal(requests[0].url, "https://example.test/api/findings");
	assert.equal(requests[0].init.method, "GET");
	assert.equal(requests[0].init.redirect, "manual");
	const headers = requests[0].init.headers as Record<string, string>;
	assert.equal(headers.Authorization, "Bearer secret");
	assert.equal(headers.Accept, "application/json");
});

test("getFindings keeps keys it does not know", async () => {
	const extended = { ...REPORT, extra: 1, findings: [{ ...REPORT.findings[0], newKey: "x" }] };
	assert.deepEqual(await getFindings({ token: "secret", fetch: fake(200, extended).fetch }), extended);
});

test("getFindings says the cache is not ready on 503, with the API's reason", async () => {
	await assert.rejects(
		getFindings({ token: "secret", fetch: fake(503, { error: "the first scan has not finished" }).fetch }),
		(error: Error) => {
			assert.match(error.message, /not ready.*503.*the first scan has not finished/);
			assert.doesNotMatch(error.message, /secret/);
			return true;
		},
	);
	// 本文が JSON でなくても理由なしで投げる。
	await assert.rejects(getFindings({ token: "secret", fetch: fake(503, "x").fetch }), /not ready.*503/);
});

test("getFindings throws on refused tokens and other statuses, without showing the token", async () => {
	for (const [status, pattern] of [
		[401, /refused the token \(401\).*issue a new token/],
		[403, /refused the token \(403\)/],
		[302, /answered 302/],
		[500, /answered 500/],
	] as const) {
		await assert.rejects(getFindings({ token: "secret", fetch: fake(status, "x").fetch }), (error: Error) => {
			assert.match(error.message, pattern);
			assert.doesNotMatch(error.message, /secret/);
			return true;
		});
	}
});
