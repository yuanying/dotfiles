// test/pi-sandbox.bats から使う。拡張と同じ判定と bwrap で 1 つのコマンドを走らせ、
// 出力の後に `[exit <code>]` と、書き込みを禁じたパスのうち変わったものを出す。
//   node test/pi-sandbox-run.ts <cwd> <command> [<settings JSON>]
// 一時ディレクトリは書き込み先に入れない (テストの $HOME も /tmp の下にあるため)。

import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { spawnInBwrap } from "../pi/extensions/sandbox/linux.ts";
import { buildPolicy, changedPaths, mergeSettings, snapshot, validateSettings } from "../pi/extensions/sandbox/policy.ts";

const [cwd, command, settingsJson] = process.argv.slice(2);
const git = spawnSync("git", ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], {
	cwd,
	encoding: "utf-8",
});
const [gitDir, commonDir] = git.status === 0 ? git.stdout.trim().split("\n") : [];
const policy = buildPolicy({
	cwd,
	home: homedir(),
	temp: [],
	settings: mergeSettings(validateSettings(JSON.parse(settingsJson ?? "{}"), "argv"), undefined),
	settingsFiles: [],
	git: gitDir && commonDir ? { gitDir, commonDir } : undefined,
});
const before = snapshot(policy.denyWrite);
const child = spawnInBwrap(policy, cwd, ["bash", "-c", command], { env: process.env });
child.stdout?.pipe(process.stdout);
child.stderr?.pipe(process.stdout);
child.on("close", (code) => {
	const changed = changedPaths(before, snapshot(policy.denyWrite));
	process.stdout.write(`[exit ${code}]\n`);
	for (const path of changed) process.stdout.write(`[changed ${path}]\n`);
});
