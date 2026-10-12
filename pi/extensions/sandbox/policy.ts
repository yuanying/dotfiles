// サンドボックスの判定ロジック。pi を import しないので node --test で直接試せる。
// 設定の読み込みとマージ、書き込みを許す / 禁じるパスの組み立て、
// write / edit の書き込み先の判定、除外コマンドの判定を持つ。
// 決定の経緯は docs/adr/0013。

import { accessSync, constants, existsSync, lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import { delimiter, dirname, isAbsolute, join, resolve, sep } from "node:path";

export type SandboxSettings = {
	enabled?: boolean;
	allowWrite?: string[];
	denyWrite?: string[];
	denyRead?: string[];
	excludedCommands?: string[];
	allowAllUnixSockets?: boolean;
};

export type MergedSettings = {
	enabled: boolean;
	allowWrite: string[];
	denyWrite: string[];
	denyRead: string[];
	excludedCommands: string[];
	allowAllUnixSockets: boolean;
};

const LIST_KEYS = ["allowWrite", "denyWrite", "denyRead", "excludedCommands"] as const;
const BOOLEAN_KEYS = ["enabled", "allowAllUnixSockets"] as const;

// 書き込み可能なルートの直下で、常に書き込みを禁じる名前。
// どれもサンドボックスの外で後から読まれ、実行につながる。
export const PROTECTED_NAMES = [
	".git/hooks",
	".git/config",
	".git/config.worktree",
	".pi",
	".claude",
	".vscode",
	".idea",
	".envrc",
	".mcp.json",
	".gitmodules",
	".gitconfig",
	".ripgreprc",
	".bashrc",
	".bash_profile",
	".zshrc",
	".zprofile",
	".zshenv",
	".profile",
];

/** JSON の設定を読む。無ければ undefined、壊れていれば例外。 */
export function readSettingsFile(path: string): SandboxSettings | undefined {
	if (!existsSync(path)) return undefined;
	const parsed: unknown = JSON.parse(readFileSync(path, "utf-8"));
	return validateSettings(parsed, path);
}

export function validateSettings(value: unknown, source: string): SandboxSettings {
	if (typeof value !== "object" || value === null || Array.isArray(value)) {
		throw new Error(`${source}: 設定はオブジェクトで書く`);
	}
	const record = value as Record<string, unknown>;
	const settings: SandboxSettings = {};
	for (const key of Object.keys(record)) {
		if ((LIST_KEYS as readonly string[]).includes(key)) {
			const list = record[key];
			if (!Array.isArray(list) || !list.every((item) => typeof item === "string")) {
				throw new Error(`${source}: ${key} は文字列の配列で書く`);
			}
			settings[key as (typeof LIST_KEYS)[number]] = list as string[];
		} else if ((BOOLEAN_KEYS as readonly string[]).includes(key)) {
			if (typeof record[key] !== "boolean") throw new Error(`${source}: ${key} は true / false で書く`);
			settings[key as (typeof BOOLEAN_KEYS)[number]] = record[key] as boolean;
		} else {
			throw new Error(`${source}: 知らない設定 ${key}`);
		}
	}
	return settings;
}

/** グローバルとプロジェクトを重ねる。リストは和集合、真偽値はプロジェクトが勝つ。 */
export function mergeSettings(global: SandboxSettings | undefined, project: SandboxSettings | undefined): MergedSettings {
	const layers = [global ?? {}, project ?? {}];
	const merged: MergedSettings = {
		enabled: false,
		allowWrite: [],
		denyWrite: [],
		denyRead: [],
		excludedCommands: [],
		allowAllUnixSockets: false,
	};
	for (const layer of layers) {
		for (const key of LIST_KEYS) {
			for (const item of layer[key] ?? []) if (!merged[key].includes(item)) merged[key].push(item);
		}
		for (const key of BOOLEAN_KEYS) if (layer[key] !== undefined) merged[key] = layer[key] as boolean;
	}
	return merged;
}

/** `~` を展開し、相対パスは base から解決する。 */
export function expandPath(path: string, base: string, home: string): string {
	let expanded = path;
	if (expanded === "~") expanded = home;
	else if (expanded.startsWith("~/")) expanded = join(home, expanded.slice(2));
	return resolve(base, expanded);
}

/**
 * シンボリックリンクを展開した実体のパス。まだ無いパスは、存在する一番近い親の
 * realpath に残りを継ぎ足す。書き込みはリンクの先へ届くので、判定はこちらで行う。
 */
export function realpathForWrite(path: string): string {
	let current = path;
	const rest: string[] = [];
	for (;;) {
		try {
			return join(realpathSync(current), ...rest);
		} catch {
			const parent = dirname(current);
			if (parent === current) return path;
			rest.unshift(current.slice(parent.length).replace(/^\//, ""));
			current = parent;
		}
	}
}

export function isAtOrUnder(path: string, dir: string): boolean {
	if (dir === "/") return true;
	return path === dir || path.startsWith(dir + sep);
}

export type GitLayout = {
	/** `git rev-parse --git-dir` の絶対パス */
	gitDir: string;
	/** `git rev-parse --git-common-dir` の絶対パス */
	commonDir: string;
};

export type PolicyInput = {
	cwd: string;
	home: string;
	/** 一時ディレクトリ (/tmp と $TMPDIR)。書き込みを許すが、保護する名前は置かない */
	temp: string[];
	settings: MergedSettings;
	/** 常に書き込みを禁じる設定ファイル */
	settingsFiles: string[];
	git?: GitLayout;
};

export type Policy = {
	/** 書き込みを許すパス (実体)。存在するものだけ */
	writable: string[];
	/** 書き込みを禁じるパス (実体)。存在しないものも含む (後から作られたら警告する) */
	denyWrite: string[];
	/** 読み込みを禁じるパス (実体)。存在するものだけ */
	denyRead: string[];
	excludedCommands: string[];
	allowAllUnixSockets: boolean;
};

function unique(paths: string[]): string[] {
	return [...new Set(paths)];
}

export function buildPolicy(input: PolicyInput): Policy {
	const { cwd, home, settings } = input;
	const expand = (path: string) => realpathForWrite(expandPath(path, cwd, home));
	const roots = unique([cwd, ...input.temp, ...settings.allowWrite].map(expand));
	const writable = roots.filter((path) => existsSync(path));
	// 保護する名前は、起動ディレクトリと設定で足した書き込み先の直下に置く。
	// 一時ディレクトリはどこからも読まれないので外す。
	const configured = unique([cwd, ...settings.allowWrite].map(expand));
	const deny: string[] = [];
	for (const root of configured) for (const name of PROTECTED_NAMES) deny.push(join(root, name));
	const realCwd = expand(cwd);
	const common = input.git ? realpathForWrite(input.git.commonDir) : undefined;
	if (input.git && common && !isAtOrUnder(common, realCwd)) {
		// worktree や、リポジトリの下位ディレクトリで起動したとき。.git の実体が
		// 起動ディレクトリの外にある。コミットに要るので書かせるが、外の git が
		// 実行する hooks と config は守る。
		writable.push(common);
		deny.push(join(common, "hooks"), join(common, "config"), join(common, "config.worktree"));
		deny.push(join(realpathForWrite(input.git.gitDir), "config.worktree"));
	}
	for (const path of input.settingsFiles) deny.push(realpathForWrite(path));
	for (const path of settings.denyWrite) deny.push(expand(path));
	const denyRead = unique(settings.denyRead.map(expand)).filter((path) => existsSync(path));
	return {
		writable: unique(writable),
		denyWrite: unique(deny),
		denyRead,
		excludedCommands: settings.excludedCommands,
		allowAllUnixSockets: settings.allowAllUnixSockets,
	};
}

export type WriteDecision = { allowed: true; path: string } | { allowed: false; path: string; reason: string };

/** write / edit の書き込み先を判定する。 */
export function checkWrite(policy: Policy, target: string, cwd: string, home: string): WriteDecision {
	const path = realpathForWrite(expandPath(target, cwd, home));
	const denied = policy.denyWrite.find((dir) => isAtOrUnder(path, dir));
	if (denied) return { allowed: false, path, reason: `${denied} はサンドボックスで書き込みを禁じている` };
	if (!policy.writable.some((dir) => isAtOrUnder(path, dir))) {
		return { allowed: false, path, reason: `${path} はサンドボックスで書き込みを許した場所の外にある` };
	}
	return { allowed: true, path };
}

/**
 * 単純なコマンドなら、シェルが渡すのと同じ語に分けて返す。そうでなければ undefined。
 * 許すのは素の語と引用符で囲んだ文字列、語頭の `~` だけ。展開 ($ とバッククォート)、
 * グロブ、演算子、リダイレクト、代入、エスケープは一切受け付けない。
 */
export function splitSimpleCommand(command: string, home: string): string[] | undefined {
	const words: string[] = [];
	let word: string | undefined;
	let i = 0;
	const plain = /[A-Za-z0-9_.\/:@%+,^=-]/;
	const text = command.trim();
	while (i < text.length) {
		const ch = text[i];
		if (ch === "~") {
			// シェルが展開するのは語頭の `~` と `~/` だけ。それ以外の位置は拒む。
			const next = text[i + 1];
			if (word !== undefined || !(next === undefined || next === "/" || next === " " || next === "\t")) return undefined;
			word = home;
			i++;
		} else if (ch === " " || ch === "\t") {
			if (word !== undefined) words.push(word);
			word = undefined;
			i++;
		} else if (ch === "'") {
			const end = text.indexOf("'", i + 1);
			if (end < 0) return undefined;
			word = (word ?? "") + text.slice(i + 1, end);
			i = end + 1;
		} else if (ch === '"') {
			const end = text.indexOf('"', i + 1);
			if (end < 0) return undefined;
			const inner = text.slice(i + 1, end);
			if (/[$`\\!]/.test(inner)) return undefined;
			word = (word ?? "") + inner;
			i = end + 1;
		} else if (plain.test(ch)) {
			word = (word ?? "") + ch;
			i++;
		} else {
			return undefined;
		}
	}
	if (word !== undefined) words.push(word);
	if (words.length === 0) return undefined;
	// 先頭が代入 (FOO=bar cmd) なら環境を変えられるので単純とみなさない。
	if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0])) return undefined;
	return words;
}

function isExecutable(path: string): boolean {
	try {
		return statSync(path).isFile() && (accessSync(path, constants.X_OK), true);
	} catch {
		return false;
	}
}

/** シェルと同じように実行ファイルを探し、実体のパスを返す。 */
export function resolveExecutable(name: string, cwd: string, home: string, pathEnv: string): string | undefined {
	let candidate: string | undefined;
	if (name.includes("/")) {
		const path = expandPath(name, cwd, home);
		if (isExecutable(path)) candidate = path;
	} else {
		for (const dir of pathEnv.split(delimiter)) {
			if (!dir || !isAbsolute(dir)) continue;
			const path = join(dir, name);
			if (isExecutable(path)) {
				candidate = path;
				break;
			}
		}
	}
	return candidate === undefined ? undefined : realpathSync(candidate);
}

export type Exclusion = { excluded: true; command: string } | { excluded: false; note?: string };

function shellQuote(word: string): string {
	return `'${word.replaceAll("'", `'\\''`)}'`;
}

/**
 * サンドボックスの外で実行してよいコマンドか。単純なコマンドで、実行ファイルの
 * 実体が除外リストのどれかと同じで、しかもサンドボックスから書き換えられない
 * 場所にあるときだけ外に出す。
 */
export function checkExcluded(policy: Policy, command: string, cwd: string, home: string, pathEnv: string): Exclusion {
	if (policy.excludedCommands.length === 0) return { excluded: false };
	const words = splitSimpleCommand(command, home);
	if (!words) return { excluded: false };
	const executable = resolveExecutable(words[0], cwd, home, pathEnv);
	if (!executable) return { excluded: false };
	const listed = policy.excludedCommands.some(
		(entry) => resolveExecutable(entry, cwd, home, pathEnv) === executable,
	);
	if (!listed) return { excluded: false };
	if (policy.writable.some((dir) => isAtOrUnder(executable, dir))) {
		return {
			excluded: false,
			note: `${executable} はサンドボックスから書き換えられる場所にあるので、除外せずサンドボックス内で実行した`,
		};
	}
	// 実行ファイルは判定した実体の絶対パスで呼ぶ。PATH を引き直すと、その間に
	// 書き込み可能な場所へ同名のものを置かれうるため。
	return { excluded: true, command: [executable, ...words.slice(1)].map(shellQuote).join(" ") };
}

/** 保護したパスの同一性。無ければ null。 */
export type Snapshot = Map<string, string | null>;

export function snapshot(paths: string[]): Snapshot {
	const result: Snapshot = new Map();
	for (const path of paths) {
		try {
			const stat = lstatSync(path);
			result.set(path, `${stat.dev}:${stat.ino}`);
		} catch {
			result.set(path, null);
		}
	}
	return result;
}

/** 前後の snapshot で、作られた / 置き換えられた / 消えたパスを返す。 */
export function changedPaths(before: Snapshot, after: Snapshot): string[] {
	const changed: string[] = [];
	for (const [path, identity] of before) if (after.get(path) !== identity) changed.push(path);
	return changed;
}

/** 起動ディレクトリが $HOME かその上だと、ほぼ全部が書き込み可能になる。 */
export function coversHome(cwd: string, home: string): boolean {
	return isAtOrUnder(home, cwd);
}
