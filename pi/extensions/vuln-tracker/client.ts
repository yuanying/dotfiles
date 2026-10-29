// vuln-tracker (https://github.com/yuanying/vuln-tracker) の JSON の API を呼ぶ。
// vuln-tracker.fraction.jp は gated の内側にあり、fraction-agents の SA
// (system:serviceaccount:fraction-agents:claude) の token を Bearer で付けて通る。
// token は fraction-agents スキルと同じファイルから読み、出力やエラーには載せない。

import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const BASE_URL = "https://vuln-tracker.fraction.jp";
export const TOKEN_FILE = join(homedir(), ".config/fraction-agents/tokens/claude");

/** GET /api/findings の本文 (vuln-tracker の ADR にある契約)。知らないキーが増えても壊れない。 */
export type Report = {
	generatedAt: string;
	severities: string[];
	findings: Finding[];
};

export type Finding = {
	image: string;
	tag: string;
	digest: string;
	vulnerabilityID: string;
	severity: string;
	package: string;
	installedVersion: string;
	fixedVersion: string;
	fixable?: boolean;
	selfBuilt: boolean;
	sourceRepository: string | null;
	stage: string;
	source: { state: SourceState; pullRequests: PullRequest[] };
	manifest: { state: ManifestState; repository: string | null; pullRequests: PullRequest[] };
	vex: {
		state: string;
		status: string | null;
		reviewBy: string | null;
		document: string | null;
		reason?: string | null;
		expired?: boolean;
		pullRequests?: PullRequest[];
	};
	workloads: { namespace: string; kind: string; name: string; container: string }[];
	/** 導入時からあった発見は null。 */
	firstSeenAt: string | null;
};

export type SourceState = "unaddressed" | "pr-open" | "merged" | "released" | "not-applicable" | "unknown";
export type ManifestState = "no-fix" | "unaddressed" | "pr-open" | "merged" | "unknown";

export type PullRequest = {
	url: string;
	repository: string;
	number: number;
	title: string;
	state: "open" | "merged" | "closed";
	author: string;
	link: "vuln-responder" | "renovate" | "mentions-id";
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
 * GET /api/findings を 1 回呼ぶ。起動直後でスキャンが揃っていないと 503 と
 * {"error": "..."} が返るので、その理由を添えて投げる。200 以外はすべて投げる。
 */
export async function getFindings(options: {
	token: string;
	signal?: AbortSignal;
	fetch?: Fetch;
	baseUrl?: string;
}): Promise<Report> {
	const response = await (options.fetch ?? fetch)(`${options.baseUrl ?? BASE_URL}/api/findings`, {
		method: "GET",
		headers: { Authorization: `Bearer ${options.token}`, Accept: "application/json" },
		// 転送先へ token を持っていかせない。API は転送しない。
		redirect: "manual",
		signal: options.signal,
	});
	if (response.status === 401 || response.status === 403) {
		throw new Error(
			`vuln-tracker refused the token (${response.status}): it may have expired, or gated does not let this ServiceAccount in. Ask the user to issue a new token.`,
		);
	}
	if (response.status === 503) {
		let reason = "";
		try {
			const body = (await response.json()) as { error?: unknown };
			if (typeof body?.error === "string") reason = `: ${body.error}`;
		} catch {
			// 理由が読めなくても 503 であることは伝える。
		}
		throw new Error(`vuln-tracker is not ready yet (503), try again in a few minutes${reason}`);
	}
	if (response.status === 200) return (await response.json()) as Report;
	throw new Error(`vuln-tracker answered ${response.status} ${response.statusText}`.trimEnd());
}
