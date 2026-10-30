// vmapi (https://github.com/yuanying/vmapi) の JSON の API を呼ぶ。契約は vmapi の api/openapi.yaml。
// vm.poissonnerie.dev は devbox proxy の内側にあり、`devbox-proxy token --service vm --user pi`
// で発行した token を Bearer で付けて通る。proxy はその名前を VM の持ち主として vmapi に渡す。
// token はファイルから読み、出力やエラーには載せない。

import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const BASE_URL = "https://vm.poissonnerie.dev";
export const TOKEN_FILE = join(homedir(), ".config/vmapi/tokens/pi");

const ISSUE = "Ask the user to issue a new one with `devbox-proxy token --service vm --user pi` on boucherie.";

/** VM・スナップショット・イメージの名前 (api/openapi.yaml の Name)。パスに入れる前にこれで確かめる。 */
export const NAME_PATTERN = "^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$";
const NAME = new RegExp(NAME_PATTERN);

export type Fetch = (url: string, init: RequestInit) => Promise<Response>;

/**
 * API が返したエラー。code は API の error.code (知らない値も来る)。
 * 本文がエラーの形でなければ code は無い。スクリプトは code で分岐できる。
 */
export class VmapiError extends Error {
	readonly status: number | undefined;
	readonly code: string | undefined;

	constructor(message: string, status?: number, code?: string) {
		super(message);
		this.name = "VmapiError";
		this.status = status;
		this.code = code;
	}
}

/** token を読む。他人に読めるファイルは使わない (fraction-agents の agent.mjs と同じ)。 */
export function readToken(path = TOKEN_FILE): string {
	let mode: number;
	try {
		mode = statSync(path).mode;
	} catch (error) {
		throw new Error(`cannot read the token file ${path}: ${(error as NodeJS.ErrnoException).code ?? error}. ${ISSUE}`);
	}
	if ((mode & 0o077) !== 0) {
		throw new Error(`the token file ${path} can be read by others. Ask the user to make it private with chmod 0600.`);
	}
	const token = readFileSync(path, "utf8").trim();
	if (token === "") throw new Error(`the token file ${path} is empty`);
	return token;
}

/**
 * /api/v1/ の下を 1 回呼び、JSON の本文をそのまま返す (204 は null)。
 * segments は URL のパスの部品で、名前は DNS のラベルでなければ送る前に投げる。
 * 2xx 以外はすべて VmapiError で投げる。
 */
export async function call(
	method: "GET" | "POST" | "DELETE",
	segments: string[],
	options: {
		token: string;
		body?: unknown;
		query?: Record<string, string | undefined>;
		signal?: AbortSignal;
		fetch?: Fetch;
		baseUrl?: string;
	},
): Promise<unknown> {
	for (const segment of segments) {
		if (!NAME.test(segment)) {
			throw new VmapiError(
				`${JSON.stringify(segment)} is not a valid name: a lowercase letter first, then lowercase letters, digits and hyphens, not ending in a hyphen, 63 characters at most`,
				undefined,
				"invalid_argument",
			);
		}
	}
	const url = new URL(`${options.baseUrl ?? BASE_URL}/api/v1/${segments.join("/")}`);
	for (const [key, value] of Object.entries(options.query ?? {})) {
		if (value !== undefined) url.searchParams.set(key, value);
	}
	const headers: Record<string, string> = { Authorization: `Bearer ${options.token}`, Accept: "application/json" };
	if (options.body !== undefined) headers["Content-Type"] = "application/json";
	const response = await (options.fetch ?? fetch)(url.toString(), {
		method,
		headers,
		body: options.body === undefined ? undefined : JSON.stringify(options.body),
		// 転送先へ token を持っていかせない。API は転送しない。
		redirect: "manual",
		signal: options.signal,
	});
	if (response.status === 204) return null;
	if (response.status >= 200 && response.status < 300) return await response.json();

	if (response.status === 401) {
		throw new VmapiError(`vmapi refused the token (401): it has probably expired. ${ISSUE}`, 401, "unauthenticated");
	}
	let error: { code?: unknown; message?: unknown } | undefined;
	try {
		error = ((await response.json()) as { error?: { code?: unknown; message?: unknown } })?.error;
	} catch {
		// 本文がエラーの形でなくても、状態コードは伝える。
	}
	if (typeof error?.code === "string") {
		const message = typeof error.message === "string" ? `: ${error.message}` : "";
		throw new VmapiError(`vmapi answered ${response.status} ${error.code}${message}`, response.status, error.code);
	}
	throw new VmapiError(`vmapi answered ${response.status} ${response.statusText}`.trimEnd(), response.status);
}
