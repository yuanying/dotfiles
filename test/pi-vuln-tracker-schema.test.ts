// pi/extensions/vuln-tracker/index.ts の出力スキーマのテスト。test/pi-vuln-tracker.bats から
// node --test で走らせる。extension の写しと typebox を置いたディレクトリを VULN_TRACKER_EXTENSION で受け取る。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

const dir = process.env.VULN_TRACKER_EXTENSION;
assert.ok(dir, "VULN_TRACKER_EXTENSION is not set");
const { Value } = await import(pathToFileURL(createRequire(join(dir, "index.ts")).resolve("typebox/value")).href);
const { default: register } = await import(pathToFileURL(join(dir, "index.ts")).href);

const tools: any[] = [];
register({ registerTool: (tool: unknown) => tools.push(tool) });
const tool = tools.find((t) => t.name === "vuln_tracker_findings");

const PR = {
	url: "https://github.com/yuanying/hshelf/pull/12",
	repository: "yuanying/hshelf",
	number: 12,
	title: "Fix CVE-2026-33210",
	state: "open",
	author: "yuanying",
	link: "mentions-id",
};

function report(finding: Record<string, unknown> = {}) {
	return {
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
				source: { state: "pr-open", pullRequests: [PR] },
				manifest: { state: "no-fix", repository: "yuanying/fleet-infra", pullRequests: [] },
				vex: { state: "none", status: null, reviewBy: null, document: null },
				workloads: [{ namespace: "hshelf", kind: "Deployment", name: "hshelf", container: "app" }],
				firstSeenAt: "2026-10-27T03:00:00Z",
				...finding,
			},
		],
	};
}

test("the tool is codemode only, in the vuln_tracker namespace", () => {
	assert.equal(tool.exposure, "codemode");
	assert.equal(tool.namespace.name, "vuln_tracker");
});

test("the output schema accepts the contract's example", () => {
	assert.ok(Value.Check(tool.outputSchema, report()));
});

test("the output schema accepts keys and enum values vuln-tracker adds later", () => {
	const future = {
		...report({
			newKey: 1,
			source: { state: "abandoned", pullRequests: [{ ...PR, state: "draft", link: "dependabot", extra: true }] },
			manifest: { state: "partially-merged", repository: null, pullRequests: [] },
		}),
		extra: "x",
	};
	assert.ok(Value.Check(tool.outputSchema, future), JSON.stringify([...Value.Errors(tool.outputSchema, future)]));
});

test("the output schema accepts a finding present since vuln-tracker was installed (firstSeenAt null)", () => {
	const old = report({ firstSeenAt: null });
	assert.ok(Value.Check(tool.outputSchema, old), JSON.stringify([...Value.Errors(tool.outputSchema, old)]));
});

test("the output schema accepts the keys vuln-tracker added to the contract (ADR 0015)", () => {
	const full = report({
		fixable: true,
		vex: {
			state: "not-exploitable",
			status: "not_affected",
			reviewBy: "2026-12-01",
			document: "https://github.com/yuanying/fleet-infra/blob/main/vex/hshelf.json",
			reason: "the vulnerable code is not reachable",
			expired: false,
			pullRequests: [PR],
		},
	});
	assert.ok(Value.Check(tool.outputSchema, full), JSON.stringify([...Value.Errors(tool.outputSchema, full)]));
	// 型に足したキーは任意。足す前の版の本文も通す。
	assert.ok(Value.Check(tool.outputSchema, report()));
});
