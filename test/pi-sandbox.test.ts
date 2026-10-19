// pi/extensions/sandbox の判定ロジックの単体テスト。test/pi-sandbox.bats から
// node --test で走らせる (docs/adr/0013)。

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, renameSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { bwrapArgs, unixSocketFilter } from "../pi/extensions/sandbox/bwrap.ts";
import { dialogQueue } from "../pi/extensions/sandbox/dialog.ts";
import {
	addAllowWrite,
	buildPolicy,
	changedPaths,
	checkExcluded,
	checkWrite,
	coversHome,
	grantTarget,
	mergeSettings,
	type Policy,
	readSettingsFile,
	snapshot,
	splitSimpleCommand,
	validateSettings,
} from "../pi/extensions/sandbox/policy.ts";

function scratch(): string {
	return realpathSync(mkdtempSync(join(tmpdir(), "pi-sandbox-test-")));
}

function policyIn(cwd: string, home: string, extra: Parameters<typeof mergeSettings>[0] = {}): Policy {
	return buildPolicy({
		cwd,
		home,
		temp: [join(home, "tmp")],
		settings: mergeSettings(extra, undefined),
		settingsFiles: [join(home, "global.json")],
	});
}

function executable(path: string, body = "#!/bin/sh\n"): string {
	writeFileSync(path, body);
	chmodSync(path, 0o755);
	return path;
}

test("settings: lists are united and the project's booleans win", () => {
	const merged = mergeSettings(
		{ enabled: false, allowWrite: ["~/a", "~/b"], excludedCommands: ["herdr"] },
		{ enabled: true, allowWrite: ["~/b", "~/c"], allowAllUnixSockets: true },
	);
	assert.deepEqual(merged.allowWrite, ["~/a", "~/b", "~/c"]);
	assert.deepEqual(merged.excludedCommands, ["herdr"]);
	assert.equal(merged.enabled, true);
	assert.equal(merged.allowAllUnixSockets, true);
});

test("settings: unknown keys and wrong types are refused", () => {
	assert.throws(() => validateSettings({ allowWrites: [] }, "x"), /知らない設定/);
	assert.throws(() => validateSettings({ allowWrite: "~/a" }, "x"), /文字列の配列/);
	assert.throws(() => validateSettings({ enabled: "yes" }, "x"), /true \/ false/);
	assert.throws(() => validateSettings([], "x"), /オブジェクト/);
});

test("settings: a missing file is no settings, a broken one is an error", () => {
	const dir = scratch();
	assert.equal(readSettingsFile(join(dir, "none.json")), undefined);
	writeFileSync(join(dir, "broken.json"), "{");
	assert.throws(() => readSettingsFile(join(dir, "broken.json")));
});

test("write: the launch directory, /tmp and configured paths are writable", () => {
	const home = scratch();
	const cwd = join(home, "proj");
	mkdirSync(join(home, "cache"), { recursive: true });
	mkdirSync(cwd);
	const policy = policyIn(cwd, home, { allowWrite: ["~/cache"] });
	assert.equal(checkWrite(policy, "src/new.ts", cwd, home).allowed, true);
	assert.equal(checkWrite(policy, "~/tmp/x", cwd, home).allowed, true, "a writable root need not exist yet");
	assert.equal(checkWrite(policy, "~/cache/x", cwd, home).allowed, true);
	assert.equal(checkWrite(policy, "~/other", cwd, home).allowed, false);
	assert.equal(checkWrite(policy, "../other", cwd, home).allowed, false);
	assert.equal(checkWrite(policy, `${cwd}2/x`, cwd, home).allowed, false);
	assert.equal((checkWrite(policy, "~/other", cwd, home) as { kind: string }).kind, "outside");
});

test("write: protected names and the settings files are denied", () => {
	const home = scratch();
	const cwd = join(home, "proj");
	mkdirSync(join(cwd, ".git", "hooks"), { recursive: true });
	const policy = policyIn(cwd, home);
	for (const target of [".git/hooks/pre-commit", ".git/config", ".pi/sandbox.json", ".pi/extensions/x.ts", ".claude/settings.json", ".envrc", ".vscode/tasks.json"]) {
		assert.equal(checkWrite(policy, target, cwd, home).allowed, false, target);
	}
	assert.equal(checkWrite(policy, ".git/HEAD", cwd, home).allowed, true);
	assert.equal((checkWrite(policy, ".pi/x", cwd, home) as { kind: string }).kind, "denied");
	assert.equal(checkWrite(policy, "~/global.json", cwd, home).allowed, false);
});

test("write: a symlink out of the launch directory is judged by its target", () => {
	const home = scratch();
	const cwd = join(home, "proj");
	mkdirSync(cwd);
	mkdirSync(join(home, "outside"));
	symlinkSync(join(home, "outside"), join(cwd, "link"));
	symlinkSync(join(cwd, ".git"), join(cwd, "gitlink"));
	mkdirSync(join(cwd, ".git", "hooks"), { recursive: true });
	const policy = policyIn(cwd, home);
	assert.equal(checkWrite(policy, "link/new/file", cwd, home).allowed, false);
	assert.equal(checkWrite(policy, "gitlink/hooks/pre-commit", cwd, home).allowed, false);
});

test("git: a worktree's common directory is writable except hooks and config", () => {
	const home = scratch();
	const cwd = join(home, "worktree");
	const common = join(home, "main", ".git");
	mkdirSync(cwd);
	mkdirSync(join(common, "worktrees", "w"), { recursive: true });
	const policy = buildPolicy({
		cwd,
		home,
		temp: [join(home, "tmp")],
		settings: mergeSettings(undefined, undefined),
		settingsFiles: [],
		git: { gitDir: join(common, "worktrees", "w"), commonDir: common },
	});
	assert.equal(checkWrite(policy, join(common, "objects", "ab", "cd"), cwd, home).allowed, true);
	assert.equal(checkWrite(policy, join(common, "worktrees", "w", "index"), cwd, home).allowed, true);
	assert.equal(checkWrite(policy, join(common, "hooks", "post-checkout"), cwd, home).allowed, false);
	assert.equal(checkWrite(policy, join(common, "config"), cwd, home).allowed, false);
	assert.equal(checkWrite(policy, join(common, "worktrees", "w", "config.worktree"), cwd, home).allowed, false);
	assert.equal(checkWrite(policy, join(home, "main", "README"), cwd, home).allowed, false);
});

test("simple commands: words and quotes pass, anything the shell would expand does not", () => {
	const home = "/home/u";
	assert.deepEqual(splitSimpleCommand("herdr pane list", home), ["herdr", "pane", "list"]);
	assert.deepEqual(splitSimpleCommand(`herdr agent start 'a b' "c|d;e"`, home), ["herdr", "agent", "start", "a b", "c|d;e"]);
	assert.deepEqual(splitSimpleCommand(`p.sh work "line1\nline2"`, home), ["p.sh", "work", "line1\nline2"]);
	assert.deepEqual(splitSimpleCommand("~/bin/x --base=abc ~", home), ["/home/u/bin/x", "--base=abc", "/home/u"]);
	assert.deepEqual(splitSimpleCommand(`x ""`, home), ["x", ""]);
	for (const command of [
		"herdr pane list | jq .",
		"herdr a && rm -rf ~",
		"herdr a; rm x",
		"herdr a > /tmp/x",
		"herdr a < /tmp/x",
		"herdr $(id)",
		"herdr `id`",
		`herdr "$HOME"`,
		`herdr "\`id\`"`,
		"herdr a\nrm x",
		"FOO=1 herdr a",
		"herdr a*",
		"herdr a~b",
		"herdr 'unterminated",
		"herdr a &",
		"herdr a # comment",
		"herdr \\; x",
		"",
	]) {
		assert.equal(splitSimpleCommand(command, home), undefined, command);
	}
});

test("excluded commands: only the listed file, called as a simple command, runs outside", () => {
	const home = scratch();
	const cwd = join(home, "proj");
	const bin = join(home, "bin");
	mkdirSync(cwd);
	mkdirSync(bin);
	executable(join(bin, "herdr"));
	executable(join(bin, "other"));
	const policy = policyIn(cwd, home, { excludedCommands: ["herdr"] });
	const path = bin;
	const result = checkExcluded(policy, "herdr pane list", cwd, home, path);
	assert.deepEqual(result, { excluded: true, command: `'${join(bin, "herdr")}' 'pane' 'list'` });
	assert.equal(checkExcluded(policy, "other pane list", cwd, home, path).excluded, false);
	assert.equal(checkExcluded(policy, "herdr pane list | sh", cwd, home, path).excluded, false);
	assert.equal(checkExcluded(policy, "nothing", cwd, home, path).excluded, false);
	assert.equal(checkExcluded(policy, `herdr "it's"`, cwd, home, path).excluded, true);
	assert.match(
		(checkExcluded(policy, `herdr "it's"`, cwd, home, path) as { command: string }).command,
		/'it'\\''s'$/,
	);
});

test("excluded commands: an entry resolving to a writable file is not excluded", () => {
	const home = scratch();
	const cwd = join(home, "proj");
	mkdirSync(join(cwd, "bin"), { recursive: true });
	const helper = executable(join(cwd, "bin", "helper"));
	mkdirSync(join(home, "bin"));
	symlinkSync(helper, join(home, "bin", "helper"));
	const policy = policyIn(cwd, home, { excludedCommands: ["~/bin/helper"] });
	const result = checkExcluded(policy, "~/bin/helper --x", cwd, home, "");
	assert.equal(result.excluded, false);
	assert.match((result as { note?: string }).note ?? "", /書き換えられる/);
});

test("excluded commands: another spelling of the same file matches", () => {
	const home = scratch();
	const cwd = join(home, "proj");
	mkdirSync(cwd);
	mkdirSync(join(home, "real"));
	const helper = executable(join(home, "real", "helper"));
	mkdirSync(join(home, "bin"));
	symlinkSync(helper, join(home, "bin", "helper"));
	const policy = policyIn(cwd, home, { excludedCommands: ["~/bin/helper"] });
	assert.equal(checkExcluded(policy, `${helper} x`, cwd, home, "").excluded, true);
});

test("snapshots: creation, replacement and removal are reported", () => {
	const dir = scratch();
	const kept = join(dir, "kept");
	const replaced = join(dir, "replaced");
	const created = join(dir, "created");
	mkdirSync(kept);
	mkdirSync(replaced);
	const before = snapshot([kept, replaced, created]);
	renameSync(replaced, join(dir, "moved"));
	mkdirSync(replaced);
	mkdirSync(created);
	assert.deepEqual(changedPaths(before, snapshot([kept, replaced, created])).sort(), [created, replaced].sort());
});

test("home: starting in $HOME or above it is flagged", () => {
	assert.equal(coversHome("/home/u", "/home/u"), true);
	assert.equal(coversHome("/", "/home/u"), true);
	assert.equal(coversHome("/home/u/src", "/home/u"), false);
});

test("bwrap: binds go from shallow to deep, denies over the writable ones", () => {
	const dir = scratch();
	mkdirSync(join(dir, "a", ".git", "hooks"), { recursive: true });
	const policy: Policy = {
		writable: [join(dir, "a"), "/dev/shm"],
		denyWrite: [join(dir, "a", ".git", "hooks"), join(dir, "a", ".pi")],
		denyRead: [],
		excludedCommands: [],
		allowAllUnixSockets: false,
	};
	policy.writable.push(join(dir, "not-yet"));
	const args = bwrapArgs(policy, join(dir, "a"), 3);
	const text = args.join(" ");
	assert.ok(text.indexOf(`--bind ${dir}/a ${dir}/a`) < text.indexOf(`--ro-bind ${dir}/a/.git/hooks`));
	assert.ok(!text.includes("/dev/shm"), "/dev comes from --dev");
	assert.ok(!text.includes(".pi"), "a path that does not exist cannot be bound");
	assert.ok(!text.includes("not-yet"), "nor a writable root that does not exist yet");
	assert.deepEqual(args.slice(-5), ["--seccomp", "3", "--chdir", `${dir}/a`, "--"]);
	assert.ok(!bwrapArgs(policy, join(dir, "a"), undefined).includes("--seccomp"));
});

test("seccomp: one filter per architecture, eight bytes per instruction", () => {
	for (const arch of ["x64", "arm64"]) {
		const filter = unixSocketFilter(arch);
		assert.equal(filter.length % 8, 0);
		// 最後の命令は ALLOW。
		assert.equal(filter.readUInt32LE(filter.length - 4), 0x7fff0000);
	}
	assert.throws(() => unixSocketFilter("ia32"));
});

test("grants: the parent directory, but never $HOME or above", () => {
	assert.equal(grantTarget("/home/u/.local/state/notes/a.md", "/home/u"), "/home/u/.local/state/notes");
	assert.equal(grantTarget("/home/u/a.md", "/home/u"), "/home/u/a.md");
	assert.equal(grantTarget("/etc/a.conf", "/home/u"), "/etc");
	assert.equal(grantTarget("/a.conf", "/home/u"), "/a.conf");
});

test("grants: allowWrite is extended and the other keys are kept", () => {
	const dir = scratch();
	const file = join(dir, "nested", "sandbox.json");
	addAllowWrite(file, "/srv/a");
	assert.deepEqual(readSettingsFile(file), { allowWrite: ["/srv/a"] });
	writeFileSync(file, JSON.stringify({ enabled: true, allowWrite: ["/srv/a"], excludedCommands: ["herdr"] }));
	addAllowWrite(file, "/srv/b");
	addAllowWrite(file, "/srv/b");
	assert.deepEqual(readSettingsFile(file), { enabled: true, allowWrite: ["/srv/a", "/srv/b"], excludedCommands: ["herdr"] });
	writeFileSync(file, "{");
	assert.throws(() => addAllowWrite(file, "/srv/c"));
});

/** 外から閉じられるダイアログ。開いたかどうかを opened で見る。 */
function fakeDialog(): { show: () => Promise<string>; close: (answer: string) => void; opened: () => boolean } {
	let opened = false;
	let close = (_answer: string) => {};
	const show = () => {
		opened = true;
		return new Promise<string>((resolve) => {
			close = resolve;
		});
	};
	return { show, close: (answer) => close(answer), opened: () => opened };
}

const settle = () => new Promise((resolve) => setImmediate(resolve));

test("dialogs: the next one opens only after the previous one closes", async () => {
	const queue = dialogQueue();
	const first = fakeDialog();
	const second = fakeDialog();
	const a = queue(first.show);
	const b = queue(second.show);
	await settle();
	assert.equal(first.opened(), true);
	assert.equal(second.opened(), false);
	first.close("one");
	assert.equal(await a, "one");
	await settle();
	assert.equal(second.opened(), true);
	second.close("two");
	assert.equal(await b, "two");
});

test("dialogs: aborting while queued returns at once and keeps the order", async () => {
	const queue = dialogQueue();
	const first = fakeDialog();
	const second = fakeDialog();
	const third = fakeDialog();
	const controller = new AbortController();
	const a = queue(first.show);
	const b = queue(second.show, controller.signal);
	const c = queue(third.show);
	await settle();
	controller.abort();
	assert.equal(await b, undefined);
	await settle();
	assert.equal(second.opened(), false);
	assert.equal(third.opened(), false);
	first.close("one");
	await a;
	await settle();
	assert.equal(third.opened(), true);
	third.close("three");
	assert.equal(await c, "three");
});

test("dialogs: an already aborted signal never opens the dialog", async () => {
	const queue = dialogQueue();
	const dialog = fakeDialog();
	const controller = new AbortController();
	controller.abort();
	assert.equal(await queue(dialog.show, controller.signal), undefined);
	assert.equal(dialog.opened(), false);
});

test("dialogs: a dialog that throws does not block the next one", async () => {
	const queue = dialogQueue();
	const next = fakeDialog();
	await assert.rejects(queue(() => Promise.reject(new Error("boom"))));
	const b = queue(next.show);
	await settle();
	assert.equal(next.opened(), true);
	next.close("ok");
	assert.equal(await b, "ok");
});
