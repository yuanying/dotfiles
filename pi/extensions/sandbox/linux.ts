// bwrap でコマンドを起動する。seccomp フィルタは fd 3 のパイプで渡す。
// ファイルにすると、サンドボックスから書ける /tmp などに置いた場合に
// 次の起動の前へ差し替えられうるため。

import { type ChildProcess, spawn } from "node:child_process";
import { bwrapArgs, unixSocketFilter } from "./bwrap.ts";
import type { Policy } from "./policy.ts";

export type SpawnOptions = {
	env?: NodeJS.ProcessEnv;
	/** コマンドを標準入力で渡すシェル用。渡さなければ stdin は閉じる */
	stdin?: string;
	bwrap?: string;
};

const SECCOMP_FD = 3;

/** argv をサンドボックスの中で起動する。detached なので負の pid でグループごと止められる。 */
export function spawnInBwrap(policy: Policy, cwd: string, argv: string[], options: SpawnOptions = {}): ChildProcess {
	const seccomp = !policy.allowAllUnixSockets;
	const args = [...bwrapArgs(policy, cwd, seccomp ? SECCOMP_FD : undefined), ...argv];
	const stdio: ("pipe" | "ignore")[] = [options.stdin === undefined ? "ignore" : "pipe", "pipe", "pipe"];
	if (seccomp) stdio.push("pipe");
	const child = spawn(options.bwrap ?? "bwrap", args, { cwd, env: options.env, detached: true, stdio });
	// 呼び出し側がリスナーを付ける前に起動に失敗しても、pi ごと落ちないようにする。
	child.on("error", () => {});
	if (seccomp) {
		const pipe = child.stdio[SECCOMP_FD] as NodeJS.WritableStream | null;
		pipe?.on("error", () => {});
		pipe?.end(unixSocketFilter());
	}
	if (options.stdin !== undefined) {
		child.stdin?.on("error", () => {});
		child.stdin?.end(options.stdin);
	}
	return child;
}
