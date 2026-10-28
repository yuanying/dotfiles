// write / edit で .go のファイルを書いたら gofmt をかける。Claude Code では
// claude/hooks/gofmt.sh が PostToolUse フックとして同じことをする。
//
// 整形するとファイルの中身が、モデルが覚えている中身とずれる。そのままだと次の
// edit の oldText が合わなくなるので、整形したときは結果にそう書き足し、編集の前に
// 読み直させる。構文エラーで整形できなかったときも、gofmt のメッセージを書き足す。
// gofmt が無いホストでは何もしない。

import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type GofmtResult =
	| { kind: "unchanged" }
	| { kind: "formatted" }
	| { kind: "error"; message: string }
	| { kind: "unavailable" };

export function gofmt(path: string, command = "gofmt"): GofmtResult {
	const listed = spawnSync(command, ["-l", path], { encoding: "utf8" });
	if (listed.error) return { kind: "unavailable" };
	if (listed.status !== 0) return { kind: "error", message: listed.stderr.trim() };
	if (listed.stdout.trim() === "") return { kind: "unchanged" };
	const written = spawnSync(command, ["-w", path], { encoding: "utf8" });
	if (written.error || written.status !== 0) return { kind: "error", message: (written.stderr ?? "").trim() };
	return { kind: "formatted" };
}

/** write / edit と同じく、先頭の @ を落として ~ を展開し、相対パスは cwd から解決する。 */
export function toolPath(path: string, cwd: string, home = homedir()): string {
	let expanded = path.startsWith("@") ? path.slice(1) : path;
	if (expanded === "~") expanded = home;
	else if (expanded.startsWith("~/")) expanded = join(home, expanded.slice(2));
	return resolve(cwd, expanded);
}

export function note(path: string, result: GofmtResult): string | undefined {
	switch (result.kind) {
		case "formatted":
			return `gofmt reformatted ${path}. Read it again before editing it.`;
		case "error":
			return `gofmt could not format ${path}:\n${result.message}`;
		default:
			return undefined;
	}
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_result", async (event, ctx) => {
		if (event.isError) return;
		if (event.toolName !== "write" && event.toolName !== "edit") return;
		const input = event.input.path;
		if (typeof input !== "string" || !input.endsWith(".go")) return;

		const text = note(input, gofmt(toolPath(input, ctx.cwd)));
		if (!text) return;
		return { content: [...event.content, { type: "text", text }] };
	});
}
