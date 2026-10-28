// pi/extensions/gofmt.ts の単体テスト。test/pi-gofmt.bats から node --test で走らせる。

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import register, { gofmt, note, toolPath } from "../pi/extensions/gofmt.ts";

type Handler = (event: unknown, ctx: { cwd: string }) => Promise<unknown>;

function scratch(): string {
	return mkdtempSync(join(tmpdir(), "pi-gofmt-test-"));
}

function handler(): Handler {
	let registered: Handler | undefined;
	register({
		on(name: string, fn: Handler) {
			assert.equal(name, "tool_result");
			registered = fn;
		},
	} as never);
	assert.ok(registered);
	return registered;
}

function event(toolName: string, path: string, isError = false) {
	return { type: "tool_result", toolName, toolCallId: "1", input: { path }, content: [{ type: "text", text: "ok" }], isError };
}

test("gofmt formats an unformatted file", () => {
	const dir = scratch();
	const path = join(dir, "main.go");
	writeFileSync(path, "package main\nfunc main(){}\n");
	assert.deepEqual(gofmt(path), { kind: "formatted" });
	assert.equal(readFileSync(path, "utf8"), "package main\n\nfunc main() {}\n");
	assert.deepEqual(gofmt(path), { kind: "unchanged" });
});

test("gofmt reports a syntax error and leaves the file alone", () => {
	const dir = scratch();
	const path = join(dir, "main.go");
	writeFileSync(path, "package main\nfunc main( {\n");
	const result = gofmt(path);
	assert.equal(result.kind, "error");
	assert.match(result.kind === "error" ? result.message : "", /expected/);
	assert.equal(readFileSync(path, "utf8"), "package main\nfunc main( {\n");
});

test("gofmt that is not installed does nothing", () => {
	assert.deepEqual(gofmt("main.go", "gofmt-that-does-not-exist"), { kind: "unavailable" });
});

test("paths resolve as write and edit resolve them", () => {
	assert.equal(toolPath("a.go", "/work", "/home/u"), "/work/a.go");
	assert.equal(toolPath("@a.go", "/work", "/home/u"), "/work/a.go");
	assert.equal(toolPath("~/src/a.go", "/work", "/home/u"), "/home/u/src/a.go");
	assert.equal(toolPath("/abs/a.go", "/work", "/home/u"), "/abs/a.go");
});

test("only a formatted file or an error has a note", () => {
	assert.match(note("a.go", { kind: "formatted" }) ?? "", /^gofmt reformatted a\.go\. Read it again/);
	assert.match(note("a.go", { kind: "error", message: "boom" }) ?? "", /could not format a\.go:\nboom$/);
	assert.equal(note("a.go", { kind: "unchanged" }), undefined);
	assert.equal(note("a.go", { kind: "unavailable" }), undefined);
});

test("a write of a .go file, relative to cwd, is formatted and the note is appended", async () => {
	const dir = scratch();
	writeFileSync(join(dir, "main.go"), "package main\nfunc main(){}\n");
	const result = (await handler()(event("write", "main.go"), { cwd: dir })) as { content: { text: string }[] };
	assert.equal(result.content.length, 2);
	assert.equal(result.content[0].text, "ok");
	assert.match(result.content[1].text, /^gofmt reformatted main\.go/);
	assert.equal(readFileSync(join(dir, "main.go"), "utf8"), "package main\n\nfunc main() {}\n");
});

test("a formatted file leaves the result as it was", async () => {
	const dir = scratch();
	writeFileSync(join(dir, "main.go"), "package main\n\nfunc main() {}\n");
	assert.equal(await handler()(event("edit", "main.go"), { cwd: dir }), undefined);
});

test("other tools, other files and failed calls are not touched", async () => {
	const dir = scratch();
	const unformatted = "package main\nfunc main(){}\n";
	writeFileSync(join(dir, "main.go"), unformatted);
	writeFileSync(join(dir, "notes.txt"), unformatted);
	const run = handler();
	assert.equal(await run(event("read", "main.go"), { cwd: dir }), undefined);
	assert.equal(await run(event("write", "notes.txt"), { cwd: dir }), undefined);
	assert.equal(await run(event("write", "main.go", true), { cwd: dir }), undefined);
	assert.equal(readFileSync(join(dir, "main.go"), "utf8"), unformatted);
});
