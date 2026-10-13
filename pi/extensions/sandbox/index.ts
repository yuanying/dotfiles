// 必要なときだけ有効にするサンドボックス。有効な間は bash と bg_run のコマンドを
// OS のサンドボックスで包み、write / edit の書き込み先を検査する。どちらも
// 書き込めるのは起動ディレクトリ、/tmp、$TMPDIR と設定で足した場所だけ。
// 切り替えるのはユーザーだけ (/sandbox、--sandbox、--no-sandbox、設定の enabled)。
// 決定の経緯は docs/adr/0013。

import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { homedir, constants as osConstants, tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	type BashOperations,
	createBashToolDefinition,
	createLocalBashOperations,
	getAgentDir,
	getShellConfig,
	hasTrustRequiringProjectResources,
	ProjectTrustStore,
} from "@earendil-works/pi-coding-agent";
import { spawnInBwrap } from "./linux.ts";
import { cleanupAfterMacosCommand, resetMacos, wrapForMacos } from "./macos.ts";
import {
	addAllowWrite,
	buildPolicy,
	changedPaths,
	checkExcluded,
	checkWrite,
	coversHome,
	type GitLayout,
	grantTarget,
	type MergedSettings,
	mergeSettings,
	type Policy,
	readSettingsFile,
	snapshot,
} from "./policy.ts";

const STATUS_KEY = "sandbox";
const MESSAGE_TYPE = "sandbox";
// background-bash.ts との受け渡し。リクエストの形は SpawnRequest。
export const SPAWN_CHANNEL = "sandbox:spawn";
// 除外コマンドに渡す、サンドボックスから書ける場所 (JSON の配列)。
export const WRITABLE_ENV = "PI_SANDBOX_WRITABLE";
export const UNCONFINED_JOBS_CHANNEL = "background-bash:unconfined-jobs";

// 許可を問うダイアログ。答えが無ければこの時間で中止にする (許可はしない)。
const PROMPT_TIMEOUT_MS = 10 * 60 * 1000;
const CHOICE_ABORT = "中止 (書き込まない)";
const CHOICE_SESSION = "このセッションだけ許可";
const CHOICE_PROJECT = "このプロジェクトで許可 (.pi/sandbox.json に書く)";
const CHOICE_GLOBAL = "すべてのプロジェクトで許可 (~/.pi/agent/extensions/sandbox.json に書く)";

const DENIAL_NOTE =
	"サンドボックスによる拒否なので、別の書き方や別の場所で回避しようとせず、何が拒否されたかをユーザーに伝えること。";

/** bg_run がコマンドを起動するときに投げる。サンドボックスが有効なら result を埋める。 */
export type SpawnRequest = {
	command: string;
	cwd: string;
	result?: Promise<Launched>;
};

/** 起動したコマンド。終わったら出力を渡して finish() を呼ぶと、出力に足す注意書きが返る。 */
type Launched = { child: ChildProcess; sandboxed: boolean; finish: (output: string) => string[] };

type State = {
	settings: MergedSettings;
	settingsFiles: string[];
	git?: GitLayout;
	cwd: string;
};

const home = homedir();

function globalSettingsPath(): string {
	return join(getAgentDir(), "extensions", "sandbox.json");
}

function projectSettingsPath(cwd: string): string {
	return join(cwd, ".pi", "sandbox.json");
}

/**
 * プロジェクトの設定を信用してよいか。ctx.isProjectTrusted() は、pi が trust を
 * 問わないディレクトリ (sandbox.json しか無い .pi など) でも true を返すので、
 * trust.json の保存済みの判定か、実際に trust を問われて許されたことを要る。
 */
function projectTrusted(ctx: ExtensionContext): boolean {
	const saved = new ProjectTrustStore(getAgentDir()).get(ctx.cwd);
	if (saved !== null) return saved;
	return hasTrustRequiringProjectResources(ctx.cwd) && ctx.isProjectTrusted();
}

function gitLayout(cwd: string): GitLayout | undefined {
	const result = spawnSync("git", ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], {
		cwd,
		encoding: "utf-8",
	});
	if (result.status !== 0) return undefined;
	const [gitDir, commonDir] = result.stdout.trim().split("\n");
	return gitDir && commonDir ? { gitDir, commonDir } : undefined;
}

function bwrapUsable(): string | undefined {
	const result = spawnSync("bwrap", ["--ro-bind", "/", "/", "--dev", "/dev", "--unshare-pid", "--proc", "/proc", "true"], {
		encoding: "utf-8",
	});
	if (result.error) return `bwrap を起動できない: ${result.error.message}`;
	if (result.status !== 0) return `bwrap が動かない: ${result.stderr.trim()}`;
	return undefined;
}

function shellArgv(command: string): { argv: string[]; stdin?: string } {
	const shell = getShellConfig();
	return shell.commandTransport === "stdin"
		? { argv: [shell.shell, ...shell.args], stdin: command }
		: { argv: [shell.shell, ...shell.args, command] };
}

function spawnLocal(command: string, cwd: string, env?: NodeJS.ProcessEnv): ChildProcess {
	const { argv, stdin } = shellArgv(command);
	const child = spawn(argv[0], argv.slice(1), {
		cwd,
		env,
		detached: true,
		stdio: [stdin === undefined ? "ignore" : "pipe", "pipe", "pipe"],
	});
	child.on("error", () => {});
	if (stdin !== undefined) {
		child.stdin?.on("error", () => {});
		child.stdin?.end(stdin);
	}
	return child;
}

function killGroup(child: ChildProcess): void {
	if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
	try {
		process.kill(-child.pid, "SIGKILL");
	} catch {
		child.kill("SIGKILL");
	}
}

/** 出力に、サンドボックスに拒否された跡があるか。 */
function looksDenied(output: string): boolean {
	return /Read-only file system|socket: operation not permitted|Os \{ code: 1, kind: PermissionDenied/i.test(output);
}

export default function sandbox(pi: ExtensionAPI): void {
	let state: State | undefined;
	let ui: ExtensionContext["ui"] | undefined;
	// 「このセッションだけ許可」した場所。メモリにだけ持ち、/sandbox off/on では残し、
	// セッションの終了で消える。モデルからは触れない。
	let sessionGrants: string[] = [];

	pi.registerFlag("sandbox", { description: "サンドボックスを有効にして起動する", type: "boolean", default: false });
	pi.registerFlag("no-sandbox", { description: "設定に関わらずサンドボックスを無効にして起動する", type: "boolean", default: false });

	function policyFor(current: State): Policy {
		return buildPolicy({
			cwd: current.cwd,
			home,
			temp: ["/tmp", tmpdir()],
			settings: { ...current.settings, allowWrite: [...current.settings.allowWrite, ...sessionGrants] },
			settingsFiles: current.settingsFiles,
			git: current.git,
		});
	}

	/** コマンドを起動する。サンドボックスの外へ出す (除外) か中で起動するかを決める。 */
	async function launch(current: State, command: string, cwd: string, env: NodeJS.ProcessEnv | undefined): Promise<Launched> {
		const policy = policyFor(current);
		const path = env?.PATH ?? process.env.PATH ?? "";
		const exclusion = checkExcluded(policy, command, cwd, home, path);
		if (exclusion.excluded) {
			// 外で動くコマンドに、サンドボックスから書ける場所を教える。herdr-task-worktree は
			// これを見て、サンドボックスの中で仕込めるリポジトリには git を実行しない。
			// 単純なコマンドしか除外しないので、モデルがこの変数を書き換えることはできない。
			const outsideEnv = { ...(env ?? process.env), [WRITABLE_ENV]: JSON.stringify(policy.writable) };
			return { child: spawnLocal(exclusion.command, cwd, outsideEnv), sandboxed: false, finish: () => [] };
		}
		const notes = exclusion.note ? [`[sandbox] ${exclusion.note}`] : [];
		const before = snapshot(policy.denyWrite);
		let child: ChildProcess;
		if (process.platform === "darwin") {
			child = spawnLocal(await wrapForMacos(policy, command), cwd, env);
		} else {
			const { argv, stdin } = shellArgv(command);
			child = spawnInBwrap(policy, cwd, argv, { env, stdin });
		}
		const finish = (output: string) => {
			if (process.platform === "darwin") cleanupAfterMacosCommand();
			if (looksDenied(output)) {
				notes.push(
					`[sandbox] サンドボックスが有効。書き込めるのは /sandbox で示す場所だけで、Unix ソケット (herdr、docker など) は塞いでいる。${DENIAL_NOTE}`,
				);
			}
			const changed = changedPaths(before, snapshot(policy.denyWrite));
			if (changed.length > 0) {
				const message = `[sandbox] 警告: 書き込みを禁じたパスが作られた / 置き換えられた: ${changed.join(", ")}。サンドボックスの外で読まれる前に中身を確認すること。`;
				notes.push(message);
				ui?.notify(message, "warning");
			}
			return notes;
		};
		return { child, sandboxed: true, finish };
	}

	const localOps = createLocalBashOperations();
	const operations: BashOperations = {
		async exec(command, cwd, options) {
			const current = state;
			if (!current) return localOps.exec(command, cwd, options);
			if (options.signal?.aborted) throw new Error("aborted");
			const { child, finish } = await launch(current, command, cwd, options.env);
			let output = "";
			const onData = (chunk: Buffer) => {
				output = (output + chunk.toString("utf-8")).slice(-16 * 1024);
				options.onData(chunk);
			};
			child.stdout?.on("data", onData);
			child.stderr?.on("data", onData);
			let timedOut = false;
			const timer =
				options.timeout && options.timeout > 0
					? setTimeout(() => {
							timedOut = true;
							killGroup(child);
						}, options.timeout * 1000)
					: undefined;
			const onAbort = () => killGroup(child);
			options.signal?.addEventListener("abort", onAbort, { once: true });
			try {
				const code = await new Promise<number | null>((resolve, reject) => {
					child.on("error", reject);
					child.on("close", (exitCode, signal) =>
						resolve(exitCode ?? (signal ? 128 + (osConstants.signals[signal] ?? 0) : 1)),
					);
				});
				const notes = finish(output);
				if (notes.length > 0) options.onData(Buffer.from(`\n${notes.join("\n")}\n`));
				if (options.signal?.aborted) throw new Error("aborted");
				if (timedOut) throw new Error(`timeout:${options.timeout}`);
				return { exitCode: code };
			} finally {
				if (timer) clearTimeout(timer);
				options.signal?.removeEventListener("abort", onAbort);
			}
		},
	};

	// 組み込みの bash を、実行部分だけ差し替えたもので置き換える。
	const bash = createBashToolDefinition(process.cwd(), { operations });
	pi.registerTool({ ...bash, label: "bash" });

	pi.on("tool_call", async (event, ctx) => {
		const current = state;
		if (!current || (event.toolName !== "write" && event.toolName !== "edit")) return;
		const target = (event.input as { path?: unknown }).path;
		if (typeof target !== "string") return { block: true, reason: "[sandbox] 書き込み先が読めない" };
		const decision = checkWrite(policyFor(current), target, ctx.cwd, home);
		if (decision.allowed) return;
		if (decision.kind === "outside" && ctx.hasUI && (await askToAllow(ctx, decision.path))) {
			const retry = state ? checkWrite(policyFor(state), target, ctx.cwd, home) : undefined;
			if (!retry || retry.allowed) return;
			return { block: true, reason: `[sandbox] ${retry.reason}。${DENIAL_NOTE}` };
		}
		return { block: true, reason: `[sandbox] ${decision.reason}。${DENIAL_NOTE}` };
	});

	/**
	 * 許可した場所の外への書き込みを、ユーザーに許すか問う。許したら設定に足して
	 * 読み直し、true を返す。禁止パス (denyWrite) への書き込みは問わずに拒む。
	 */
	async function askToAllow(ctx: ExtensionContext, path: string): Promise<boolean> {
		const grant = grantTarget(path, home);
		const choices = [CHOICE_ABORT, CHOICE_SESSION];
		if (projectTrusted(ctx)) choices.push(CHOICE_PROJECT);
		choices.push(CHOICE_GLOBAL);
		const title = [
			`サンドボックス: ${path} への書き込みは許可した場所の外にある。`,
			`許可すると ${grant} ${grant === path ? "" : "以下"}に書き込めるようになる (bash からも)。`,
		].join("\n");
		const choice = await ctx.ui.select(title, choices, { timeout: PROMPT_TIMEOUT_MS });
		if (choice === undefined || choice === CHOICE_ABORT) return false;
		try {
			if (choice === CHOICE_SESSION) {
				if (!sessionGrants.includes(grant)) sessionGrants.push(grant);
			} else {
				addAllowWrite(choice === CHOICE_PROJECT ? projectSettingsPath(ctx.cwd) : globalSettingsPath(), grant);
				const loaded = loadSettings(ctx);
				if (!loaded.state) throw new Error(loaded.error ?? "設定を読み直せない");
				if (state) state = loaded.state;
			}
		} catch (error) {
			ctx.ui.notify(`許可を保存できない: ${error instanceof Error ? error.message : error}`, "error");
			return false;
		}
		ctx.ui.notify(`${grant} への書き込みを許可した (${choice})`, "info");
		return true;
	}

	pi.events.on(SPAWN_CHANNEL, (data) => {
		const request = data as SpawnRequest;
		const current = state;
		if (!current) return;
		// 例外も result の reject として届ける。握りつぶされると bg_run が素で起動してしまう。
		request.result = launch(current, request.command, request.cwd, undefined);
	});

	function loadSettings(ctx: ExtensionContext): { state?: State; messages: string[]; error?: string } {
		const messages: string[] = [];
		const globalPath = globalSettingsPath();
		const projectPath = projectSettingsPath(ctx.cwd);
		try {
			const global = readSettingsFile(globalPath);
			let project = readSettingsFile(projectPath);
			if (project && !projectTrusted(ctx)) {
				messages.push(`${projectPath} は trust していないプロジェクトの設定なので読まなかった (/trust で信用できる)`);
				project = undefined;
			}
			return {
				state: {
					settings: mergeSettings(global, project),
					settingsFiles: [globalPath, projectPath],
					git: gitLayout(ctx.cwd),
					cwd: ctx.cwd,
				},
				messages,
			};
		} catch (error) {
			return { messages, error: `サンドボックスの設定を読めない: ${error instanceof Error ? error.message : error}` };
		}
	}

	function describe(current: State): string[] {
		const policy = policyFor(current);
		return [
			`書き込める場所: ${policy.writable.join(", ")}`,
			"書き込みを禁じた場所: 起動ディレクトリの .git/hooks、.git/config、.pi、.claude、.envrc など (一覧は /sandbox)",
			`サンドボックスの外で実行するコマンド (単独のコマンドとして呼んだときだけ): ${policy.excludedCommands.join(", ") || "なし"}`,
			`Unix ソケット: ${policy.allowAllUnixSockets ? "許可" : "塞いでいる (herdr、docker などは使えない)"}`,
			"ネットワーク: 制限しない",
		];
	}

	function tellModel(text: string): void {
		pi.sendMessage(
			{ customType: MESSAGE_TYPE, content: [{ type: "text", text }], display: true, details: undefined },
			{ deliverAs: "nextTurn" },
		);
	}

	function enable(ctx: ExtensionContext): boolean {
		if (process.platform === "linux") {
			const problem = bwrapUsable();
			if (problem) {
				ctx.ui.notify(`サンドボックスを有効にできない: ${problem}`, "error");
				return false;
			}
		} else if (process.platform !== "darwin") {
			ctx.ui.notify(`サンドボックスは ${process.platform} では使えない`, "error");
			return false;
		}
		const loaded = loadSettings(ctx);
		for (const message of loaded.messages) ctx.ui.notify(message, "warning");
		if (!loaded.state) {
			ctx.ui.notify(loaded.error ?? "サンドボックスを有効にできない", "error");
			return false;
		}
		state = loaded.state;
		ctx.ui.setStatus(STATUS_KEY, ctx.ui.theme.fg("accent", "sandbox"));
		if (coversHome(ctx.cwd, home)) {
			ctx.ui.notify("起動ディレクトリが $HOME かその上なので、ほぼ全体が書き込み可能になっている", "warning");
		}
		const unconfined: { jobs: string[] } = { jobs: [] };
		pi.events.emit(UNCONFINED_JOBS_CHANNEL, unconfined);
		if (unconfined.jobs.length > 0) {
			ctx.ui.notify(`サンドボックスの外で実行中の bg_run ジョブ: ${unconfined.jobs.join(", ")}`, "warning");
		}
		return true;
	}

	function disable(ctx: ExtensionContext): void {
		state = undefined;
		ctx.ui.setStatus(STATUS_KEY, undefined);
	}

	pi.on("session_start", async (_event, ctx) => {
		ui = ctx.ui;
		if (pi.getFlag("no-sandbox")) return;
		let wanted = pi.getFlag("sandbox") === true;
		if (!wanted) {
			const loaded = loadSettings(ctx);
			wanted = loaded.state?.settings.enabled ?? false;
			if (loaded.error) ctx.ui.notify(loaded.error, "error");
		}
		if (wanted && enable(ctx)) {
			tellModel(["サンドボックスが有効になっている。", ...describe(state as State), DENIAL_NOTE].join("\n"));
		}
	});

	pi.on("session_shutdown", async () => {
		state = undefined;
		sessionGrants = [];
		ui = undefined;
		if (process.platform === "darwin") await resetMacos().catch(() => {});
	});

	pi.registerCommand("sandbox", {
		description: "サンドボックスの切り替え (/sandbox on | off) と状態の表示 (/sandbox)",
		getArgumentCompletions: (prefix) =>
			["on", "off", "status"].filter((item) => item.startsWith(prefix)).map((item) => ({ value: item, label: item })),
		handler: async (args, ctx) => {
			const action = args.trim() || "status";
			if (action === "on") {
				if (!enable(ctx)) return;
				const lines = describe(state as State);
				ctx.ui.notify(["サンドボックスを有効にした", ...lines].join("\n"), "info");
				tellModel(["ユーザーがサンドボックスを有効にした。", ...lines, DENIAL_NOTE].join("\n"));
			} else if (action === "off") {
				if (!state) {
					ctx.ui.notify("サンドボックスはもともと無効", "info");
					return;
				}
				disable(ctx);
				ctx.ui.notify("サンドボックスを無効にした", "info");
				tellModel("ユーザーがサンドボックスを無効にした。書き込み先の制限は無くなった。");
			} else if (action === "status") {
				if (!state) {
					ctx.ui.notify("サンドボックスは無効 (/sandbox on で有効にする)", "info");
					return;
				}
				const policy = policyFor(state);
				ctx.ui.notify(
					[
						"サンドボックスは有効",
						...describe(state),
						"書き込みを禁じた場所:",
						...policy.denyWrite.map((path) => `  ${path}`),
					].join("\n"),
					"info",
				);
			} else {
				ctx.ui.notify(`知らない引数: ${action} (on / off / status)`, "error");
			}
		},
	});
}
