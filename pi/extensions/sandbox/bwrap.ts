// Linux のサンドボックス。bubblewrap を直接呼ぶ。
// devbox のホストは unprivileged user namespace を禁じているので、入れ子の
// namespace を要る sandbox-runtime の apply-seccomp は動かない。setuid の bwrap に
// 自前の seccomp フィルタを --seccomp で渡して Unix ソケットを塞ぐ (docs/adr/0013)。

import { existsSync, statSync } from "node:fs";
import type { Policy } from "./policy.ts";

// seccomp_data: { int nr; u32 arch; u64 instruction_pointer; u64 args[6]; }
const OFFSET_NR = 0;
const OFFSET_ARCH = 4;
const OFFSET_ARG0_LOW = 16;

const BPF_LD_W_ABS = 0x20;
const BPF_JEQ_K = 0x15;
const BPF_JGE_K = 0x35;
const BPF_RET_K = 0x06;

const SECCOMP_RET_KILL_PROCESS = 0x80000000;
const SECCOMP_RET_ERRNO = 0x00050000;
const SECCOMP_RET_ALLOW = 0x7fff0000;
const EPERM = 1;
const AF_UNIX = 1;

type Arch = { audit: number; socket: number; ioUring: number[]; x32Bit?: number };

const ARCHES: Record<string, Arch> = {
	// x86-64 の x32 ABI は番号に 0x40000000 が立つ。番号の比較をすり抜けるので殺す。
	x64: { audit: 0xc000003e, socket: 41, ioUring: [425, 426, 427], x32Bit: 0x40000000 },
	arm64: { audit: 0xc00000b7, socket: 198, ioUring: [425, 426, 427] },
};

type Insn = [code: number, jt: number, jf: number, k: number];

/**
 * socket(AF_UNIX, ...) と io_uring_* を EPERM にする seccomp フィルタ (cBPF)。
 * io_uring は IORING_OP_SOCKET で socket() の判定を迂回できるので一緒に塞ぐ。
 * 別のアーキテクチャの呼び出し (32 ビット互換や x32) は番号が食い違うので殺す。
 */
export function unixSocketFilter(arch: string = process.arch): Buffer {
	const spec = ARCHES[arch];
	if (!spec) throw new Error(`seccomp フィルタが無いアーキテクチャ: ${arch}`);
	const deny = SECCOMP_RET_ERRNO | EPERM;
	const prog: Insn[] = [
		[BPF_LD_W_ABS, 0, 0, OFFSET_ARCH],
		[BPF_JEQ_K, 1, 0, spec.audit],
		[BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS],
		[BPF_LD_W_ABS, 0, 0, OFFSET_NR],
	];
	if (spec.x32Bit !== undefined) {
		prog.push([BPF_JGE_K, 0, 1, spec.x32Bit], [BPF_RET_K, 0, 0, SECCOMP_RET_KILL_PROCESS]);
	}
	for (const nr of spec.ioUring) prog.push([BPF_JEQ_K, 0, 1, nr], [BPF_RET_K, 0, 0, deny]);
	prog.push(
		[BPF_JEQ_K, 0, 3, spec.socket],
		[BPF_LD_W_ABS, 0, 0, OFFSET_ARG0_LOW],
		[BPF_JEQ_K, 0, 1, AF_UNIX],
		[BPF_RET_K, 0, 0, deny],
		[BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW],
	);
	const buffer = Buffer.alloc(prog.length * 8);
	prog.forEach(([code, jt, jf, k], index) => {
		buffer.writeUInt16LE(code, index * 8);
		buffer.writeUInt8(jt, index * 8 + 2);
		buffer.writeUInt8(jf, index * 8 + 3);
		buffer.writeUInt32LE(k >>> 0, index * 8 + 4);
	});
	return buffer;
}

/** 浅いものから順に並べる。bwrap は後のマウントで前のものを上書きする。 */
function byDepth(paths: string[]): string[] {
	return [...paths].sort((a, b) => a.split("/").length - b.split("/").length || a.localeCompare(b));
}

/**
 * bwrap の引数。最後にコマンド (`shell`, ...`shellArgs`) が続く。
 * seccompFd を渡すと、その fd から seccomp フィルタを読ませる。
 */
export function bwrapArgs(policy: Policy, cwd: string, seccompFd: number | undefined): string[] {
	const args = ["--die-with-parent", "--new-session", "--unshare-pid", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"];
	for (const path of byDepth(policy.writable)) {
		// /dev と /proc は別に用意したものを使う。
		if (path === "/dev" || path.startsWith("/dev/") || path === "/proc" || path.startsWith("/proc/")) continue;
		// まだ無いパスはバインドできない。write ツールで作られた後の起動から入る。
		if (!existsSync(path)) continue;
		args.push("--bind", path, path);
	}
	// 書き込みを許した場所の中にある禁止パスを、読み取り専用で上から被せる。
	// まだ無いパスは被せられない (作られたら実行後の確認で警告する)。
	for (const path of byDepth(policy.denyWrite)) {
		if (existsSync(path)) args.push("--ro-bind", path, path);
	}
	// 読み込みの禁止は、ディレクトリなら空の tmpfs、ファイルなら /dev/null で隠す。
	for (const path of byDepth(policy.denyRead)) {
		if (isDirectory(path)) args.push("--tmpfs", path, "--remount-ro", path);
		else if (existsSync(path)) args.push("--ro-bind", "/dev/null", path);
	}
	if (seccompFd !== undefined) args.push("--seccomp", String(seccompFd));
	args.push("--chdir", cwd, "--");
	return args;
}

function isDirectory(path: string): boolean {
	try {
		return statSync(path).isDirectory();
	} catch {
		return false;
	}
}
