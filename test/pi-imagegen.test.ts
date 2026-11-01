import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, mkdir, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { accountId, generate } from "../pi/extensions/imagegen/client.ts";

const token = `header.${Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "test-account" } })).toString("base64url")}.signature`;
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=", "base64");
const makeCwd = () => mkdtemp(join(tmpdir(), "pi imagegen-"));
function fake(status = 200, body: unknown = { data: [{ b64_json: png.toString("base64") }] }) {
	const calls: { url: string; init: RequestInit }[] = [];
	const fetch: typeof globalThis.fetch = async (url, init) => {
		calls.push({ url: String(url), init: init! });
		return new Response(JSON.stringify(body), { status });
	};
	return { calls, fetch };
}

test("saves PNG relative to any cwd, using the provider's current OAuth token", async () => {
	const cwd = await makeCwd();
	const f = fake();
	let authCalls = 0;
	const result = await generate({ prompt: "a circle", output: "assets/new.png", background: "transparent" }, {
		cwd, getToken: async () => { authCalls++; return token; }, fetch: f.fetch,
	});
	assert.equal(authCalls, 1);
	assert.equal(result.path, join(cwd, "assets/new.png"));
	assert.deepEqual(await readFile(result.path), png);
	assert.equal(f.calls[0].url, "https://chatgpt.com/backend-api/codex/images/generations");
	assert.equal(f.calls[0].init.redirect, "manual");
	const headers = f.calls[0].init.headers as Record<string, string>;
	assert.equal(headers.Authorization, `Bearer ${token}`);
	assert.equal(headers["chatgpt-account-id"], "test-account");
	assert.equal(headers.originator, "pi");
	assert.deepEqual(JSON.parse(String(f.calls[0].init.body)), {
		model: "gpt-image-2", prompt: "a circle", background: "transparent", quality: "auto", size: "auto",
	});
});

test("edits with ordered local references resolved through symlinks, independent of checkout location", async () => {
	const cwd = await makeCwd();
	await writeFile(join(cwd, "original.png"), png);
	await symlink(join(cwd, "original.png"), join(cwd, "linked.png"));
	const f = fake();
	const result = await generate({ prompt: "make image 1 green", referenceImages: ["linked.png"] }, {
		cwd, getToken: async () => token, fetch: f.fetch,
	});
	assert.match(result.path, /output\/imagegen\/.*\.png$/);
	assert.equal(f.calls[0].url, "https://chatgpt.com/backend-api/codex/images/edits");
	const body = JSON.parse(String(f.calls[0].init.body));
	assert.deepEqual(body.images, [{ image_url: `data:image/png;base64,${png.toString("base64")}` }]);
});

test("existing outputs (including symlink targets) are preserved without sending a request", async () => {
	const cwd = await makeCwd();
	await writeFile(join(cwd, "old.png"), png);
	await symlink(join(cwd, "old.png"), join(cwd, "linked.png"));
	const f = fake();
	for (const output of ["old.png", "linked.png"]) {
		await assert.rejects(generate({ prompt: "circle", output }, { cwd, getToken: async () => token, fetch: f.fetch }), /already exists/);
	}
	assert.equal(f.calls.length, 0);
	assert.deepEqual(await readFile(join(cwd, "old.png")), png);
});

test("missing, invalid, and failed auth produce login guidance without exposing credentials", async () => {
	const cwd = await makeCwd();
	const f = fake();
	for (const getToken of [async () => undefined, async () => "private-secret", async () => { throw new Error(token); }]) {
		await assert.rejects(generate({ prompt: "circle" }, { cwd, getToken, fetch: f.fetch }), (error: Error) => {
			assert.match(error.message, /\/login openai-codex/);
			assert.doesNotMatch(error.message, /private-secret|signature/);
			return true;
		});
	}
	assert.equal(f.calls.length, 0);
	assert.throws(() => accountId("malformed"), /OAuth/);
});

test("API failures and redirects are not retried, and upstream bodies stay private", async () => {
	for (const status of [302, 400, 401, 403, 429, 500]) {
		const f = fake(status, { error: { message: token } });
		await assert.rejects(generate({ prompt: "circle" }, { cwd: await makeCwd(), getToken: async () => token, fetch: f.fetch }), (error: Error) => {
			assert.match(error.message, new RegExp(`HTTP ${status}`));
			assert.ok(!error.message.includes(token));
			return true;
		});
		assert.equal(f.calls.length, 1);
	}
});

test("bad references and non-PNG or empty responses do not create output files", async () => {
	const cwd = await makeCwd();
	await writeFile(join(cwd, "bad.png"), "not an image");
	const f = fake();
	await assert.rejects(generate({ prompt: "circle", referenceImages: ["bad.png"] }, { cwd, getToken: async () => token, fetch: f.fetch }), /PNG, JPEG, or WebP/);
	assert.equal(f.calls.length, 0);
	for (const body of [{ data: [] }, { data: [{ b64_json: "bm90LXBvbmctZGF0YQ==" }] }]) {
		await assert.rejects(generate({ prompt: "circle", output: "bad-output.png" }, { cwd, getToken: async () => token, fetch: fake(200, body).fetch }), /no image data|PNG/);
		await assert.rejects(readFile(join(cwd, "bad-output.png")), /ENOENT/);
	}
});

test("cancellation reaches the transport and never retries", async () => {
	const cwd = await makeCwd();
	const controller = new AbortController();
	controller.abort();
	let calls = 0;
	await assert.rejects(generate({ prompt: "circle" }, {
		cwd, getToken: async () => token, signal: controller.signal,
		fetch: async (_url, init) => { calls++; assert.equal(init?.signal?.aborted, true); throw new Error(token); },
	}), (error: Error) => {
		assert.match(error.message, /cancelled/);
		assert.ok(!error.message.includes(token));
		return true;
	});
	assert.equal(calls, 1);
});

test("an output created during generation is not overwritten", async () => {
	const cwd = await makeCwd();
	await mkdir(join(cwd, "assets"));
	const output = join(cwd, "assets/race.png");
	await assert.rejects(generate({ prompt: "circle", output }, {
		cwd, getToken: async () => token,
		fetch: async () => { await writeFile(output, "preserve"); return new Response(JSON.stringify({ data: [{ b64_json: png.toString("base64") }] })); },
	}), /EEXIST/);
	assert.equal(await readFile(output, "utf8"), "preserve");
});
