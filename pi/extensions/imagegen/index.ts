import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { generate } from "./client.ts";

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "pi_imagegen",
		label: "ChatGPT image generation",
		description: "Generate or edit a PNG using pi's ChatGPT login, independently of the current chat model (including Claude). Read the pi-imagegen skill for prompt guidance. Consumes ChatGPT image quota. Reference images are uploaded; provide their local paths in order. Existing output files are never overwritten.",
		parameters: Type.Object({
			prompt: Type.String({ minLength: 1 }),
			output: Type.Optional(Type.String({ description: "New PNG path, relative to the current directory or absolute. Defaults to output/imagegen/<uuid>.png." })),
			referenceImages: Type.Optional(Type.Array(Type.String(), { maxItems: 5, description: "Local PNG/JPEG/WebP paths, in prompt order; providing images uses the editing API." })),
			background: Type.Optional(Type.Union([Type.Literal("auto"), Type.Literal("opaque"), Type.Literal("transparent")])),
			quality: Type.Optional(Type.Union([Type.Literal("auto"), Type.Literal("low"), Type.Literal("medium"), Type.Literal("high")])),
			size: Type.Optional(Type.String({ description: "auto or WIDTHxHEIGHT, subject to the image model's constraints." })),
		}),
		// Direct exposure lets Claude see the returned image and inspect it.
		async execute(_id, params, signal, _onUpdate, ctx) {
			const result = await generate(params, {
				cwd: ctx.cwd, signal,
				// Pi handles storage location, locking and OAuth refresh. Never inspect auth.json ourselves.
				getToken: () => ctx.modelRegistry.getApiKeyForProvider("openai-codex"),
			});
			return {
				content: [
					{ type: "text", text: JSON.stringify({ path: result.path, prompt: result.prompt, provider: "openai-codex", model: "gpt-image-2" }) },
					{ type: "image", data: result.image.toString("base64"), mimeType: "image/png" },
				],
				details: { path: result.path },
			};
		},
	});
}
