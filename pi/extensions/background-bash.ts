// シェルコマンドをバックグラウンドで走らせ、終了したら会話へ結果を差し込んで
// エージェントを呼び戻す。pi 本体には Claude Code の run_in_background に当たる
// 機能が無いための補完。herdr-tasks の coordinator が worker ごとに
// `herdr agent wait` を置き、座って待たずに完了を受け取るために使う。
//
// ジョブは pi のプロセスに属する。セッションの終了や /reload では殺し、
// 結果も届けない (届け先のセッションがもう無いため)。

import { spawn, type ChildProcess } from "node:child_process";
import { createWriteStream, mkdtempSync, type WriteStream } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { formatSize, getShellConfig, truncateTail } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const MESSAGE_TYPE = "background-bash";
const STATUS_KEY = "background-bash";
// 結果に載せる出力の末尾。全文はログファイルに残す。
const TAIL_LINES = 100;
const TAIL_BYTES = 8 * 1024;
// メモリに持つ出力の上限。末尾を切り出すのに足りればよい。
const BUFFER_BYTES = 4 * TAIL_BYTES;

type Job = {
	id: string;
	command: string;
	cwd: string;
	startedAt: number;
	child: ChildProcess;
	log: WriteStream;
	logPath: string;
	output: string;
	killed: boolean;
};

export function formatDuration(ms: number): string {
	const seconds = Math.max(0, Math.round(ms / 1_000));
	const minutes = Math.floor(seconds / 60);
	const hours = Math.floor(minutes / 60);
	if (hours > 0) return `${hours}h${minutes % 60}m`;
	if (minutes > 0) return `${minutes}m${seconds % 60}s`;
	return `${seconds}s`;
}

export function formatResult(
	job: Pick<Job, "id" | "command" | "cwd" | "logPath" | "output">,
	code: number | null,
	signal: NodeJS.Signals | null,
	elapsedMs: number,
): string {
	const exit = signal ? `signal ${signal}` : `exit code ${code}`;
	const tail = truncateTail(job.output, { maxLines: TAIL_LINES, maxBytes: TAIL_BYTES });
	const lines = [
		`バックグラウンドジョブ ${job.id} が終了した (${exit}, ${formatDuration(elapsedMs)})。`,
		`command: ${job.command}`,
		`cwd: ${job.cwd}`,
		`log: ${job.logPath}`,
	];
	if (!tail.content.trim()) {
		lines.push("", "(出力なし)");
	} else {
		const note = tail.truncated ? ` (末尾 ${tail.outputLines} 行 / ${formatSize(tail.outputBytes)}。全文は log)` : "";
		lines.push("", `output${note}:`, tail.content);
	}
	return lines.join("\n");
}

function killGroup(child: ChildProcess): void {
	if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) return;
	try {
		// detached で起動しているので、負の pid でプロセスグループごと止まる。
		process.kill(-child.pid, "SIGTERM");
	} catch {
		child.kill("SIGTERM");
	}
}

export default function backgroundBash(pi: ExtensionAPI): void {
	const jobs = new Map<string, Job>();
	let nextId = 1;
	let logDir: string | undefined;
	let ui: ExtensionContext["ui"] | undefined;
	// セッションが終わった後に終了したジョブの結果は、古いランタイムへ送らない。
	let alive = false;

	function updateStatus(): void {
		ui?.setStatus(STATUS_KEY, jobs.size > 0 ? `bg ${jobs.size}` : undefined);
	}

	function finish(job: Job, code: number | null, signal: NodeJS.Signals | null): void {
		if (!jobs.delete(job.id)) return;
		job.log.end();
		updateStatus();
		// bg_kill で止めたものは、止めた本人が知っているので呼び戻さない。
		if (!alive || job.killed) return;
		const text = formatResult(job, code, signal, Date.now() - job.startedAt);
		pi.sendMessage(
			{
				customType: MESSAGE_TYPE,
				content: [{ type: "text", text }],
				display: true,
				details: { id: job.id, command: job.command, code, signal, logPath: job.logPath },
			},
			// idle なら新しいターンを始め、処理中なら今の処理が終わってから届ける。
			{ triggerTurn: true, deliverAs: "followUp" },
		);
	}

	function start(command: string, cwd: string): Job {
		logDir ??= mkdtempSync(join(tmpdir(), "pi-background-bash-"));
		const id = `bg${nextId++}`;
		const logPath = join(logDir, `${id}.log`);
		const log = createWriteStream(logPath);
		const shell = getShellConfig();
		const stdin = shell.commandTransport === "stdin";
		const child = spawn(shell.shell, stdin ? shell.args : [...shell.args, command], {
			cwd,
			detached: true,
			stdio: [stdin ? "pipe" : "ignore", "pipe", "pipe"],
		});
		if (stdin) child.stdin?.end(command);
		const job: Job = { id, command, cwd, startedAt: Date.now(), child, log, logPath, output: "", killed: false };
		const capture = (chunk: Buffer) => {
			log.write(chunk);
			job.output += chunk.toString("utf-8");
			if (job.output.length > BUFFER_BYTES) job.output = job.output.slice(-BUFFER_BYTES);
		};
		child.stdout?.on("data", capture);
		child.stderr?.on("data", capture);
		child.on("error", (error) => {
			capture(Buffer.from(`\n[background-bash] ${error.message}\n`));
			finish(job, null, null);
		});
		child.on("close", (code, signal) => finish(job, code, signal));
		jobs.set(id, job);
		updateStatus();
		return job;
	}

	pi.on("session_start", async (_event, ctx) => {
		alive = true;
		ui = ctx.ui;
		updateStatus();
	});

	pi.on("session_shutdown", async () => {
		alive = false;
		for (const job of jobs.values()) {
			job.killed = true;
			killGroup(job.child);
		}
		ui?.setStatus(STATUS_KEY, undefined);
		ui = undefined;
	});

	pi.registerTool({
		name: "bg_run",
		label: "Background Bash",
		description:
			"シェルコマンドをバックグラウンドで起動し、すぐに戻る。コマンドが終了すると、exit code と出力の末尾が" +
			"メッセージとして会話に届き、ターンが始まる。完了を待つためにポーリングや sleep をしないこと。" +
			"長く待つだけのコマンド (例: `herdr agent wait <name> --until done --until blocked`) に使う。" +
			"対話的な入力を求めるコマンドには使えない (stdin は閉じている)。",
		parameters: Type.Object({
			command: Type.String({ description: "実行するシェルコマンド" }),
			cwd: Type.Optional(Type.String({ description: "作業ディレクトリ (既定: セッションの cwd)" })),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			const job = start(params.command, params.cwd ?? ctx.cwd);
			return {
				content: [
					{
						type: "text",
						text: `${job.id} をバックグラウンドで起動した (pid ${job.child.pid ?? "?"})。終了すると結果が届く。log: ${job.logPath}`,
					},
				],
				details: { id: job.id, command: job.command, cwd: job.cwd, logPath: job.logPath },
			};
		},
	});

	pi.registerTool({
		name: "bg_list",
		label: "Background Jobs",
		description: "bg_run で起動して、まだ終了していないバックグラウンドジョブの一覧を返す。",
		parameters: Type.Object({}),
		async execute() {
			const now = Date.now();
			const lines = [...jobs.values()].map(
				(job) => `${job.id}  ${formatDuration(now - job.startedAt)}  ${job.command}  (log: ${job.logPath})`,
			);
			return {
				content: [{ type: "text", text: lines.length > 0 ? lines.join("\n") : "実行中のバックグラウンドジョブは無い。" }],
				details: { ids: [...jobs.keys()] },
			};
		},
	});

	pi.registerTool({
		name: "bg_kill",
		label: "Kill Background Job",
		description: "bg_run で起動したバックグラウンドジョブを止める。止めたジョブの結果は届かない。",
		parameters: Type.Object({
			id: Type.String({ description: "bg_run が返したジョブ ID (例: bg1)" }),
		}),
		async execute(_toolCallId, params) {
			const job = jobs.get(params.id);
			if (!job) throw new Error(`${params.id} という実行中のジョブは無い`);
			job.killed = true;
			killGroup(job.child);
			return {
				content: [{ type: "text", text: `${job.id} に SIGTERM を送った。log: ${job.logPath}` }],
				details: { id: job.id },
			};
		},
	});
}
