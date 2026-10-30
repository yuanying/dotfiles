// pi/extensions/vmapi/index.ts のツールのテスト。test/pi-vmapi.bats から node --test で走らせる。
// extension の写しと typebox を置いたディレクトリを VMAPI_EXTENSION で、token を置いた HOME を受け取る。
// fetch は偽物に差し替え、ツールがどの API をどう呼ぶかと、出力スキーマを確かめる。

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

const dir = process.env.VMAPI_EXTENSION;
assert.ok(dir, "VMAPI_EXTENSION is not set");
const { Value } = await import(pathToFileURL(createRequire(join(dir, "index.ts")).resolve("typebox/value")).href);
const { default: register } = await import(pathToFileURL(join(dir, "index.ts")).href);

const tools = new Map<string, any>();
register({ registerTool: (tool: any) => tools.set(tool.name, tool) });

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
const SNAPSHOT = { name: "before-upgrade", vm_state: "running", created_at: "2026-10-30T13:00:00Z" };

type Request = { url: string; method: string; body: unknown; authorization: string };

/** fetch を偽物にして tool を呼ぶ。status と本文を返す偽物で、受けたリクエストを返す。 */
async function run(name: string, params: Record<string, unknown>, status: number, body?: unknown) {
	const requests: Request[] = [];
	const original = globalThis.fetch;
	globalThis.fetch = (async (url: string, init: RequestInit) => {
		requests.push({
			url,
			method: init.method ?? "GET",
			body: init.body === undefined ? undefined : JSON.parse(init.body as string),
			authorization: (init.headers as Record<string, string>).Authorization,
		});
		return new Response(status === 204 ? null : JSON.stringify(body), { status });
	}) as typeof fetch;
	try {
		const tool = tools.get(name);
		assert.ok(tool, `${name} is not registered`);
		const result = await tool.execute("call-1", params, undefined);
		return { requests, result };
	} finally {
		globalThis.fetch = original;
	}
}

function check(schema: unknown, value: unknown) {
	assert.ok(Value.Check(schema, value), JSON.stringify([...Value.Errors(schema, value)]));
}

const API = "https://vm.poissonnerie.dev/api/v1";

test("every tool is codemode only, in the vm namespace", () => {
	assert.deepEqual(
		[...tools.keys()].sort(),
		[
			"vm_create",
			"vm_delete",
			"vm_get",
			"vm_images",
			"vm_list",
			"vm_snapshot_create",
			"vm_snapshot_delete",
			"vm_snapshot_revert",
			"vm_snapshots",
			"vm_start",
			"vm_stop",
			"vm_whoami",
		].sort(),
	);
	for (const tool of tools.values()) {
		assert.equal(tool.exposure, "codemode", tool.name);
		assert.equal(tool.namespace.name, "vm", tool.name);
		assert.ok(tool.outputSchema, tool.name);
	}
});

test("the namespace instructions tell the caller what the API does not", () => {
	const { instructions } = tools.get("vm_create").namespace;
	assert.match(instructions, /IP/);
	assert.match(instructions, /ssh/);
	assert.match(instructions, /unique/);
	assert.match(instructions, /#cloud-config/);
	assert.match(instructions, /error\.code|\.code/);
});

test("vm_whoami and vm_images read the caller and the images", async () => {
	const who = await run("vm_whoami", {}, 200, { user: "pi", admin: false });
	assert.deepEqual(who.requests.map((r) => [r.method, r.url]), [["GET", `${API}/whoami`]]);
	assert.equal(who.requests[0].authorization, "Bearer secret");
	assert.deepEqual(who.result.structuredContent, { user: "pi", admin: false });
	assert.equal(who.result.content[0].text, JSON.stringify({ user: "pi", admin: false }));
	check(tools.get("vm_whoami").outputSchema, { user: "pi", admin: false, groups: ["x"] });

	const images = { images: [{ name: "noble", description: "Ubuntu 24.04 LTS" }, { name: "jammy" }] };
	const got = await run("vm_images", {}, 200, images);
	assert.deepEqual(got.requests.map((r) => [r.method, r.url]), [["GET", `${API}/images`]]);
	assert.deepEqual(got.result.structuredContent, images);
	check(tools.get("vm_images").outputSchema, { ...images, next: "x" });
});

test("vm_list lists the VMs, of one owner when asked", async () => {
	const list = { vms: [VM] };
	const all = await run("vm_list", {}, 200, list);
	assert.deepEqual(all.requests.map((r) => r.url), [`${API}/vms`]);
	assert.deepEqual(all.result.structuredContent, list);
	const one = await run("vm_list", { owner: "penelope" }, 200, { vms: [] });
	assert.deepEqual(one.requests.map((r) => r.url), [`${API}/vms?owner=penelope`]);
	check(tools.get("vm_list").outputSchema, list);
	// 状態の値やフィールドが増えても通す。
	check(tools.get("vm_list").outputSchema, { vms: [{ ...VM, state: "migrating", mac: "52:54:00:00:00:01" }], next: null });
});

test("vm_get gets one VM", async () => {
	const got = await run("vm_get", { name: "k8s-test-cp1" }, 200, VM);
	assert.deepEqual(got.requests.map((r) => [r.method, r.url]), [["GET", `${API}/vms/k8s-test-cp1`]]);
	assert.deepEqual(got.result.structuredContent, VM);
	check(tools.get("vm_get").outputSchema, VM);
});

test("vm_create POSTs only the fields given and returns the VM with its IP", async () => {
	const minimal = await run("vm_create", { name: "k8s-test-cp1", image: "noble" }, 201, VM);
	assert.deepEqual(minimal.requests.map((r) => [r.method, r.url]), [["POST", `${API}/vms`]]);
	assert.deepEqual(minimal.requests[0].body, { name: "k8s-test-cp1", image: "noble" });
	assert.deepEqual(minimal.result.structuredContent, VM);

	const full = {
		name: "k8s-test-cp1",
		image: "noble",
		vcpus: 4,
		memory_mib: 4096,
		disk_gib: 40,
		ip: "192.168.40.20",
		user_data: "#cloud-config\npackages: [jq]\n",
	};
	const got = await run("vm_create", full, 201, VM);
	assert.deepEqual(got.requests[0].body, full);
	check(tools.get("vm_create").outputSchema, VM);
});

test("vm_start and vm_stop change the state", async () => {
	const start = await run("vm_start", { name: "k8s-test-cp1" }, 200, VM);
	assert.deepEqual(start.requests.map((r) => [r.method, r.url, r.body]), [["POST", `${API}/vms/k8s-test-cp1/start`, undefined]]);

	const stop = await run("vm_stop", { name: "k8s-test-cp1" }, 202, { ...VM, state: "shutting_down" });
	assert.deepEqual(stop.requests.map((r) => [r.method, r.url, r.body]), [["POST", `${API}/vms/k8s-test-cp1/stop`, undefined]]);
	assert.equal(stop.result.structuredContent.state, "shutting_down");

	const force = await run("vm_stop", { name: "k8s-test-cp1", force: true }, 200, { ...VM, state: "shut_off" });
	assert.deepEqual(force.requests[0].body, { force: true });
	check(tools.get("vm_stop").outputSchema, { ...VM, state: "shut_off" });
});

test("vm_delete deletes the VM and says which", async () => {
	const got = await run("vm_delete", { name: "k8s-test-cp1" }, 204);
	assert.deepEqual(got.requests.map((r) => [r.method, r.url]), [["DELETE", `${API}/vms/k8s-test-cp1`]]);
	assert.deepEqual(got.result.structuredContent, { name: "k8s-test-cp1", deleted: true });
	check(tools.get("vm_delete").outputSchema, got.result.structuredContent);
});

test("the snapshot tools take, list, delete and revert snapshots", async () => {
	const base = `${API}/vms/k8s-test-cp1/snapshots`;
	const take = await run("vm_snapshot_create", { name: "k8s-test-cp1", snapshot: "before-upgrade" }, 201, SNAPSHOT);
	assert.deepEqual(take.requests.map((r) => [r.method, r.url, r.body]), [["POST", base, { name: "before-upgrade" }]]);
	assert.deepEqual(take.result.structuredContent, SNAPSHOT);
	check(tools.get("vm_snapshot_create").outputSchema, { ...SNAPSHOT, vm_state: "pmsuspended", size: 1 });

	const list = await run("vm_snapshots", { name: "k8s-test-cp1" }, 200, { snapshots: [SNAPSHOT] });
	assert.deepEqual(list.requests.map((r) => [r.method, r.url]), [["GET", base]]);
	check(tools.get("vm_snapshots").outputSchema, { snapshots: [SNAPSHOT] });

	const revert = await run("vm_snapshot_revert", { name: "k8s-test-cp1", snapshot: "before-upgrade" }, 200, VM);
	assert.deepEqual(revert.requests.map((r) => [r.method, r.url]), [["POST", `${base}/before-upgrade/revert`]]);
	check(tools.get("vm_snapshot_revert").outputSchema, VM);

	const del = await run("vm_snapshot_delete", { name: "k8s-test-cp1", snapshot: "before-upgrade" }, 204);
	assert.deepEqual(del.requests.map((r) => [r.method, r.url]), [["DELETE", `${base}/before-upgrade`]]);
	assert.deepEqual(del.result.structuredContent, { name: "k8s-test-cp1", snapshot: "before-upgrade", deleted: true });
	check(tools.get("vm_snapshot_delete").outputSchema, del.result.structuredContent);
});

test("a tool throws the API's error, with the code a script can branch on", async () => {
	await assert.rejects(
		run("vm_get", { name: "k8s-test-cp1" }, 404, { error: { code: "not_found", message: 'vm "k8s-test-cp1" not found' } }),
		(error: any) => {
			assert.equal(error.code, "not_found");
			assert.equal(error.status, 404);
			assert.match(error.message, /not_found/);
			assert.doesNotMatch(error.message, /secret/);
			return true;
		},
	);
});

test("parameters with a name take a DNS label", () => {
	for (const [tool, key] of [
		["vm_get", "name"],
		["vm_create", "name"],
		["vm_create", "image"],
		["vm_snapshot_create", "snapshot"],
	]) {
		const schema = tools.get(tool).parameters;
		const ok = { name: "k8s-test-cp1", image: "noble", snapshot: "before-upgrade" };
		const params = Object.fromEntries(Object.keys(schema.properties).filter((k) => k in ok).map((k) => [k, (ok as any)[k]]));
		check(schema, params);
		assert.ok(!Value.Check(schema, { ...params, [key]: "../x" }), `${tool}.${key}`);
	}
});
