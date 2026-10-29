// release-lag (https://github.com/yuanying/release-lag) の JSON の API を呼ぶ。
// release-lag.fraction.jp は gated の内側にあり、fraction-agents の SA
// (system:serviceaccount:fraction-agents:claude) の token を Bearer で付けて通る。
// token は fraction-agents スキルと同じファイルから読み、出力やエラーには載せない。

import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const BASE_URL = "https://release-lag.fraction.jp";
export const TOKEN_FILE = join(homedir(), ".config/fraction-agents/tokens/claude");

/** GET /api/repos と POST /api/refresh の本文 (release-lag の ADR 0004)。 */
export type Report = {
	owner: string;
	refreshedAt: string | null;
	lastAttemptAt: string | null;
	lastSuccess: boolean;
	lastError: string;
	repositories: Repository[];
};

export type Repository = {
	name: string;
	url: string;
	defaultBranch: string;
	private: boolean;
	released: boolean;
	latestTag: string | null;
	releasedAt: string | null;
	daysSinceRelease: number | null;
	commitsSinceRelease: number | null;
	nonRenovateCommitsSinceRelease: number | null;
	compareUrl: string | null;
	error?: string;
};

export type Fetch = (url: string, init: RequestInit) => Promise<Response>;

/** token を読む。他人に読めるファイルは使わない (fraction-agents の agent.mjs と同じ)。 */
export function readToken(path = TOKEN_FILE): string {
	let mode: number;
	try {
		mode = statSync(path).mode;
	} catch (error) {
		throw new Error(`cannot read the token file ${path}: ${(error as NodeJS.ErrnoException).code ?? error}`);
	}
	if ((mode & 0o077) !== 0) {
		throw new Error(`the token file ${path} can be read by others. Ask the user to make it private with chmod 0600.`);
	}
	const token = readFileSync(path, "utf8").trim();
	if (token === "") throw new Error(`the token file ${path} is empty`);
	return token;
}

/**
 * API を 1 回呼ぶ。POST /api/refresh は集計に失敗すると 502 で同じ形の本文を返すので、
 * そのときは ok: false で本文を返す。それ以外の失敗は投げる。
 */
export async function call(
	method: "GET" | "POST",
	path: "/api/repos" | "/api/refresh",
	options: { token: string; signal?: AbortSignal; fetch?: Fetch; baseUrl?: string },
): Promise<{ ok: boolean; report: Report }> {
	const response = await (options.fetch ?? fetch)(`${options.baseUrl ?? BASE_URL}${path}`, {
		method,
		headers: { Authorization: `Bearer ${options.token}`, Accept: "application/json" },
		// 転送先へ token を持っていかせない。API は転送しない。
		redirect: "manual",
		signal: options.signal,
	});
	if (response.status === 401 || response.status === 403) {
		throw new Error(
			`release-lag refused the token (${response.status}): it may have expired, or gated does not let this ServiceAccount in. Ask the user to issue a new token.`,
		);
	}
	if (response.status === 200 || (method === "POST" && response.status === 502)) {
		return { ok: response.status === 200, report: (await response.json()) as Report };
	}
	throw new Error(`release-lag answered ${response.status} ${response.statusText}`.trimEnd());
}
