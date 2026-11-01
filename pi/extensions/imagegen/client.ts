// Codex's Images API, authenticated by pi's provider registry (including OAuth refresh).
// Contract: openai/codex, codex-rs/codex-api/src/{images.rs,endpoint/images.rs}.
import { randomUUID } from "node:crypto";
import { mkdir, open, readFile, stat } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const ENDPOINT = "https://chatgpt.com/backend-api/codex/images/";
const LOGIN = "Run /login openai-codex in pi on this host, then retry. The chat model can stay on Claude.";
const PNG = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

export interface ImageRequest {
	prompt: string;
	output?: string;
	referenceImages?: string[];
	background?: "auto" | "opaque" | "transparent";
	quality?: "auto" | "low" | "medium" | "high";
	size?: string;
}

export interface ImageResult {
	path: string;
	image: Buffer;
	prompt: string;
}

/** Extract only the account claim; never return JWT contents in diagnostics. */
export function accountId(token: string): string {
	try {
		const claims = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
		const id = claims["https://api.openai.com/auth"]?.chatgpt_account_id;
		if (typeof id === "string" && id.length > 0) return id;
	} catch { /* Report a fixed message below. */ }
	throw new Error(`ChatGPT OAuth credentials are required. ${LOGIN}`);
}

async function reference(path: string): Promise<{ image_url: string }> {
	if ((await stat(path)).size > 20 * 1024 * 1024) throw new Error("Reference images must be at most 20 MiB each.");
	const bytes = await readFile(path);
	const mime = bytes.subarray(0, 8).equals(PNG) ? "image/png"
		: bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255 ? "image/jpeg"
			: bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP" ? "image/webp" : undefined;
	if (!mime) throw new Error("Reference images must be PNG, JPEG, or WebP.");
	return { image_url: `data:${mime};base64,${bytes.toString("base64")}` };
}

export async function generate(
	request: ImageRequest,
	options: {
		cwd: string;
		getToken: () => Promise<string | undefined>;
		signal?: AbortSignal;
		fetch?: typeof fetch;
	},
): Promise<ImageResult> {
	if (!request.prompt.trim()) throw new Error("An image prompt is required.");
	const paths = request.referenceImages ?? [];
	if (paths.length > 5) throw new Error("At most 5 reference images are supported.");
	const output = resolve(options.cwd, request.output ?? `output/imagegen/${randomUUID()}.png`);
	if (!output.toLowerCase().endsWith(".png")) throw new Error("The output filename must end in .png.");
	// Refuse existing files before spending generation quota; exclusive creation also prevents races.
	try {
		await stat(output);
		throw new Error(`Output already exists: ${output}. Choose a new filename.`);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
	}
	const images = await Promise.all(paths.map((path) => reference(resolve(options.cwd, path))));
	let token: string | undefined;
	try { token = await options.getToken(); } catch { throw new Error(`Cannot resolve ChatGPT authentication. ${LOGIN}`); }
	if (!token) throw new Error(`ChatGPT is not logged in. ${LOGIN}`);
	const id = accountId(token);
	const body = {
		model: "gpt-image-2", prompt: request.prompt,
		background: request.background ?? "auto", quality: request.quality ?? "auto", size: request.size ?? "auto",
		...(images.length ? { images } : {}),
	};
	const signal = options.signal
		? AbortSignal.any([options.signal, AbortSignal.timeout(300_000)]) : AbortSignal.timeout(300_000);
	let response: Response;
	try {
		response = await (options.fetch ?? fetch)(ENDPOINT + (images.length ? "edits" : "generations"), {
			method: "POST", redirect: "manual", signal,
			headers: {
				Authorization: `Bearer ${token}`, "chatgpt-account-id": id, originator: "pi",
				"Content-Type": "application/json", Accept: "application/json", "x-codex-image-turn-id": randomUUID(),
			},
			body: JSON.stringify(body),
		});
	} catch {
		throw new Error("Image request failed or was cancelled/timed out. It may have consumed quota; no automatic retry was made.");
	}
	if (!response.ok) {
		// Do not expose upstream bodies: they may contain HTML, prompts, or credentials.
		await response.body?.cancel();
		const advice = response.status === 401 ? LOGIN
			: response.status === 429 ? "Image quota or rate limit reached; wait before retrying."
				: response.status === 403 ? "The ChatGPT image endpoint refused access; check account access and network connectivity." : "No automatic retry was made.";
		throw new Error(`Image API returned HTTP ${response.status}. ${advice}`);
	}
	let data: { data?: { b64_json?: string }[] };
	try { data = await response.json(); } catch { throw new Error("Image API returned invalid JSON; no automatic retry was made."); }
	const encoded = data?.data?.[0]?.b64_json;
	if (typeof encoded !== "string" || encoded.length === 0) throw new Error("Image API returned no image data.");
	const image = Buffer.from(encoded, "base64");
	if (!image.subarray(0, 8).equals(PNG)) throw new Error("Image API did not return a PNG image.");
	await mkdir(dirname(output), { recursive: true });
	const file = await open(output, "wx");
	try { await file.writeFile(image); } finally { await file.close(); }
	return { path: output, image, prompt: request.prompt };
}
