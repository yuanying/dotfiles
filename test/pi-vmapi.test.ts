// pi/extensions/vmapi/client.ts の単体テスト。test/pi-vmapi.bats から node --test で走らせる。

import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BASE_URL, call, type Fetch, readToken, TOKEN_FILE, VmapiError } from "../pi/extensions/vmapi/client.ts";

// vmapi の api/openapi.yaml の VM の例。
const VM = {
	name: "k8s-test-cp1",
	owner: "pi",
	image: "noble",
	vcpus: 2,
	memory_mib: 2048,
	disk_gib: 20,
	ip: "192.168.40.10",
	state: "running",
	created_at: "2026-10-30T12:00:00Z",
};

function tokenFile(content: string, mode: number): string {
	const path = join(mkdtempSync(join(tmpdir(), "pi-vmapi-test-")), "token");
	writeFileSync(path, content);
	chmodSync(path, mode);
	return path;
}

function fake(status: number, body: unknown = VM) {
	const requests: { url: string; init: RequestInit }[] = [];
	const fetch: Fetch = async (url, init) => {
		requests.push({ url, init });
		return new Response(status === 204 ? null : typeof body === "string" ? body : JSON.stringify(body), { status });
	};
	return { fetch, requests };
}

function errorBody(code: string, message: string) {
	return { error: { code, message } };
}

test("the API lives at vm.poissonnerie.dev and the token at ~/.config/vmapi/tokens/pi", () => {
	assert.equal(BASE_URL, "https://vm.poissonnerie.dev");
	assert.equal(TOKEN_FILE, join(homedir(), ".config/vmapi/tokens/pi"));
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

test("readToken refuses an empty or missing token file, and says how to issue one", () => {
	assert.throws(() => readToken(tokenFile("\n", 0o600)), /is empty/);
	assert.throws(() => readToken("/nonexistent/token"), (error: Error) => {
		assert.match(error.message, /ENOENT/);
		assert.match(error.message, /devbox-proxy token --service vm --user pi/);
		return true;
	});
});

test("call GETs with the token as Bearer, refuses redirects and returns the JSON as it is", async () => {
	const { fetch, requests } = fake(200, { vms: [{ ...VM, extra: 1 }], next: null });
	const got = await call("GET", ["vms"], { token: "secret", fetch, baseUrl: "https://example.test" });
	assert.deepEqual(got, { vms: [{ ...VM, extra: 1 }], next: null });
	assert.equal(requests.length, 1);
	assert.equal(requests[0].url, "https://example.test/api/v1/vms");
	assert.equal(requests[0].init.method, "GET");
	assert.equal(requests[0].init.redirect, "manual");
	assert.equal(requests[0].init.body, undefined);
	const headers = requests[0].init.headers as Record<string, string>;
	assert.equal(headers.Authorization, "Bearer secret");
	assert.equal(headers.Accept, "application/json");
	assert.equal(headers["Content-Type"], undefined);
});

test("call puts the query in the URL, leaving out unset values", async () => {
	const { fetch, requests } = fake(200, { vms: [] });
	await call("GET", ["vms"], { token: "t", fetch, query: { owner: "penelope" } });
	assert.equal(requests[0].url, `${BASE_URL}/api/v1/vms?owner=penelope`);
	await call("GET", ["vms"], { token: "t", fetch, query: { owner: undefined } });
	assert.equal(requests[1].url, `${BASE_URL}/api/v1/vms`);
});

test("call POSTs a JSON body and joins the path segments", async () => {
	const { fetch, requests } = fake(201);
	await call("POST", ["vms", "k8s-test-cp1", "snapshots"], { token: "t", fetch, body: { name: "before-upgrade" } });
	assert.equal(requests[0].url, `${BASE_URL}/api/v1/vms/k8s-test-cp1/snapshots`);
	assert.equal(requests[0].init.method, "POST");
	assert.equal(requests[0].init.body, '{"name":"before-upgrade"}');
	assert.equal((requests[0].init.headers as Record<string, string>)["Content-Type"], "application/json");
});

test("call returns null on 204", async () => {
	assert.equal(await call("DELETE", ["vms", "k8s-test-cp1"], { token: "t", fetch: fake(204).fetch }), null);
});

test("call refuses names that are not DNS labels before sending anything", async () => {
	for (const name of ["..", ".", "a/b", "A", "x?y", "", "-a"]) {
		const { fetch, requests } = fake(200);
		await assert.rejects(call("GET", ["vms", name], { token: "t", fetch }), (error: Error) => {
			assert.ok(error instanceof VmapiError);
			assert.equal((error as VmapiError).code, "invalid_argument");
			return true;
		});
		assert.equal(requests.length, 0);
	}
});

test("call throws the API's error code and message, with the status, without showing the token", async () => {
	for (const [status, code, message] of [
		[400, "invalid_argument", 'unknown field "memory"'],
		[403, "permission_denied", "only an admin can list other owners' VMs"],
		[404, "not_found", 'vm "k8s-test-cp1" not found'],
		[409, "ip_in_use", "192.168.40.10 is used by another VM"],
		[503, "unavailable", "libvirt is not reachable"],
		[500, "internal", "boom"],
	] as const) {
		await assert.rejects(
			call("GET", ["vms", "k8s-test-cp1"], { token: "secret", fetch: fake(status, errorBody(code, message)).fetch }),
			(error: Error) => {
				assert.ok(error instanceof VmapiError);
				assert.equal((error as VmapiError).status, status);
				assert.equal((error as VmapiError).code, code);
				assert.ok(error.message.includes(String(status)));
				assert.ok(error.message.includes(code));
				assert.ok(error.message.includes(message));
				assert.doesNotMatch(error.message, /secret/);
				return true;
			},
		);
	}
});

test("call keeps codes it does not know", async () => {
	await assert.rejects(
		call("GET", ["vms"], { token: "t", fetch: fake(429, errorBody("rate_limited", "slow down")).fetch }),
		(error: VmapiError) => error.code === "rate_limited" && error.status === 429,
	);
});

test("call says the token has expired on 401 and how to issue a new one, whatever the body", async () => {
	for (const body of [errorBody("unauthenticated", "no user"), "Unauthorized"]) {
		await assert.rejects(call("GET", ["whoami"], { token: "secret", fetch: fake(401, body).fetch }), (error: Error) => {
			assert.equal((error as VmapiError).code, "unauthenticated");
			assert.match(error.message, /expired/);
			assert.match(error.message, /devbox-proxy token --service vm --user pi/);
			assert.doesNotMatch(error.message, /secret/);
			return true;
		});
	}
});

test("call throws on redirects and bodies that are not the error shape, with the status", async () => {
	for (const status of [302, 502]) {
		await assert.rejects(call("GET", ["vms"], { token: "secret", fetch: fake(status, "<html>").fetch }), (error: Error) => {
			assert.ok(error instanceof VmapiError);
			assert.equal((error as VmapiError).status, status);
			assert.equal((error as VmapiError).code, undefined);
			assert.match(error.message, new RegExp(`answered ${status}`));
			assert.doesNotMatch(error.message, /secret/);
			return true;
		});
	}
});
