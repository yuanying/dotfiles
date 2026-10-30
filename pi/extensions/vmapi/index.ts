// vmapi で VM を作る・一覧する・止める・消すツール。codemode のスクリプトからだけ呼ぶ (exposure "codemode")。
// ツールは API の操作と 1 対 1 で、返り値は API の JSON そのもの。後で Penelope の宣言したツールに
// そのまま写せるよう、粒度と instructions は vmapi の契約 (api/openapi.yaml) だけに寄せる。
// 出力スキーマの状態の値は列挙で縛らない。vmapi が値やフィールドを足しても落ちないように (vmapi の ADR 0007)。
// API と token の扱いは client.ts。

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { type TSchema, Type } from "typebox";
import { call, NAME_PATTERN, readToken } from "./client.ts";

const NAMESPACE = {
	name: "vm",
	aliases: ["vmapi"],
	description: "VMs on boucherie's libvirt: create, list, start, stop, delete and snapshot them through vmapi",
	instructions: [
		"The API is https://vm.poissonnerie.dev (yuanying/vmapi), a thin per-VM layer over libvirt on one host. It only knows VMs it created itself.",
		"Every VM has an owner, the user that created it. You see and operate only your own VMs; another user's VM is reported as not found. vm_whoami tells your user name and whether you are an admin, who sees every VM.",
		"VM and snapshot names are DNS labels (lowercase letter first, then lowercase letters, digits and hyphens). A VM name is unique on the whole host, whoever owns it, and is also its hostname.",
		"vm_create is synchronous: it returns once the VM is defined and started, with the IP it was given (the lowest free one unless you pass ip). It does not wait for the guest: check readiness yourself, for example by retrying ssh to that IP until it answers. The first VM from an image also waits for the image download, which can take minutes.",
		"user_data is put into the cloud-init seed exactly as given, usually a document starting with #cloud-config (ssh keys, users, packages). Network and hostname are written by the server. Without user_data the VM gets an empty #cloud-config, so nobody can log in: pass at least an ssh key.",
		"Pick image from vm_images by name; you cannot supply an image of your own.",
		"vm_stop without force only asks the guest to shut down and returns at once: poll vm_get until state is shut_off, and stop with force if it does not stop in the time you allow. vm_start and vm_stop also succeed when the VM is already in that state. vm_delete forces a running VM off and removes its disk and snapshots: it cannot be undone.",
		"A snapshot of a running VM includes memory; vm_snapshot_revert returns the VM to the state it was in then and loses what was written since.",
		"Known state values: running, paused, shutting_down, shut_off, crashed, suspended, unknown. More may be added; treat an unknown one as other.",
		"Errors are thrown with .code (invalid_argument, permission_denied, not_found, already_exists, ip_in_use, ip_exhausted, unavailable, internal; more may be added) and .status. Branch on .code, not on the message. unavailable may succeed later.",
	].join("\n"),
};

const NAME = (description: string) => Type.String({ pattern: NAME_PATTERN, description });
const VM_NAME = NAME("The VM's name");
const SNAPSHOT_NAME = NAME("The snapshot's name");

const STATE = Type.String({
	description: "running, paused, shutting_down, shut_off, crashed, suspended or unknown; more may be added",
});

const VM = Type.Object({
	name: Type.String(),
	owner: Type.String({ description: "The user that created the VM" }),
	image: Type.String(),
	vcpus: Type.Integer(),
	memory_mib: Type.Integer(),
	disk_gib: Type.Integer(),
	ip: Type.String({ description: "IPv4 address, the VM's until it is deleted" }),
	state: STATE,
	created_at: Type.String({ description: "RFC 3339" }),
});

const SNAPSHOT = Type.Object({
	name: Type.String(),
	vm_state: Type.String({ description: "The VM's state when the snapshot was taken; reverting returns it there" }),
	created_at: Type.String({ description: "RFC 3339" }),
});

function result(value: object) {
	return {
		content: [{ type: "text" as const, text: JSON.stringify(value) }],
		structuredContent: value,
		details: undefined,
	};
}

const READ = { readOnlyHint: true, openWorldHint: true };
const CHANGE = { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true };
const DESTROY = { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true };

export default function (pi: ExtensionAPI) {
	function tool<P extends TSchema>(definition: {
		name: string;
		label: string;
		description: string;
		parameters: P;
		outputSchema: TSchema;
		annotations: object;
		run: (params: any, token: string, signal: AbortSignal | undefined) => Promise<object>;
	}) {
		const { run, ...rest } = definition;
		pi.registerTool({
			...rest,
			exposure: "codemode",
			namespace: NAMESPACE,
			async execute(_toolCallId, params, signal) {
				return result(await run(params, readToken(), signal));
			},
		});
	}

	tool({
		name: "vm_whoami",
		label: "vm whoami",
		description: "Who you are to vmapi: your user name (the owner of the VMs you create) and whether you are an admin.",
		parameters: Type.Object({}),
		outputSchema: Type.Object({ user: Type.String(), admin: Type.Boolean() }),
		annotations: READ,
		run: async (_params, token, signal) => (await call("GET", ["whoami"], { token, signal })) as object,
	});

	tool({
		name: "vm_images",
		label: "vm images",
		description: "The OS images a VM can be created from, by name.",
		parameters: Type.Object({}),
		outputSchema: Type.Object({
			images: Type.Array(Type.Object({ name: Type.String(), description: Type.Optional(Type.String()) })),
		}),
		annotations: READ,
		run: async (_params, token, signal) => (await call("GET", ["images"], { token, signal })) as object,
	});

	tool({
		name: "vm_list",
		label: "vm list",
		description: "List your VMs, ordered by name. An admin gets every VM, or those of one owner.",
		parameters: Type.Object({
			owner: Type.Optional(
				Type.String({ minLength: 1, description: "Only this owner's VMs. Anyone but an admin gets permission_denied for another owner" }),
			),
		}),
		outputSchema: Type.Object({ vms: Type.Array(VM) }),
		annotations: READ,
		run: async (params, token, signal) => (await call("GET", ["vms"], { token, signal, query: { owner: params.owner } })) as object,
	});

	tool({
		name: "vm_get",
		label: "vm get",
		description: "Get one of your VMs, with its IP and current state.",
		parameters: Type.Object({ name: VM_NAME }),
		outputSchema: VM,
		annotations: READ,
		run: async (params, token, signal) => (await call("GET", ["vms", params.name], { token, signal })) as object,
	});

	tool({
		name: "vm_create",
		label: "vm create",
		description:
			"Create and start a VM you own, and return it with the IP it was given. Returns before the guest is ready: wait for ssh yourself.",
		parameters: Type.Object({
			name: NAME("Unique on the whole host; also the hostname"),
			image: NAME("An image name from vm_images"),
			vcpus: Type.Optional(Type.Integer({ minimum: 1, description: "Default 2" })),
			memory_mib: Type.Optional(Type.Integer({ minimum: 256, description: "Default 2048" })),
			disk_gib: Type.Optional(Type.Integer({ minimum: 1, description: "Default 20; not smaller than the image" })),
			ip: Type.Optional(
				Type.String({ description: "An unused IPv4 address inside the server's range. Omit it to get the lowest free one" }),
			),
			user_data: Type.Optional(
				Type.String({ description: "cloud-init user-data, used as it is: usually a #cloud-config document with an ssh key" }),
			),
		}),
		outputSchema: VM,
		annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
		run: async (params, token, signal) => (await call("POST", ["vms"], { token, signal, body: params })) as object,
	});

	tool({
		name: "vm_start",
		label: "vm start",
		description: "Start one of your VMs. Succeeds when it is already running.",
		parameters: Type.Object({ name: VM_NAME }),
		outputSchema: VM,
		annotations: CHANGE,
		run: async (params, token, signal) => (await call("POST", ["vms", params.name, "start"], { token, signal })) as object,
	});

	tool({
		name: "vm_stop",
		label: "vm stop",
		description:
			"Stop one of your VMs. Without force the guest is only asked to shut down and the VM returned may still be running: poll vm_get until shut_off. With force it is turned off at once.",
		parameters: Type.Object({
			name: VM_NAME,
			force: Type.Optional(Type.Boolean({ description: "Turn it off at once instead of asking the guest. Default false" })),
		}),
		outputSchema: VM,
		annotations: CHANGE,
		run: async (params, token, signal) =>
			(await call("POST", ["vms", params.name, "stop"], {
				token,
				signal,
				body: params.force === undefined ? undefined : { force: params.force },
			})) as object,
	});

	tool({
		name: "vm_delete",
		label: "vm delete",
		description: "Delete one of your VMs with its disk and snapshots, forcing it off first. Cannot be undone.",
		parameters: Type.Object({ name: VM_NAME }),
		outputSchema: Type.Object({ name: Type.String(), deleted: Type.Boolean() }),
		annotations: DESTROY,
		run: async (params, token, signal) => {
			await call("DELETE", ["vms", params.name], { token, signal });
			return { name: params.name, deleted: true };
		},
	});

	tool({
		name: "vm_snapshots",
		label: "vm snapshots",
		description: "List the snapshots of one of your VMs, oldest first.",
		parameters: Type.Object({ name: VM_NAME }),
		outputSchema: Type.Object({ snapshots: Type.Array(SNAPSHOT) }),
		annotations: READ,
		run: async (params, token, signal) => (await call("GET", ["vms", params.name, "snapshots"], { token, signal })) as object,
	});

	tool({
		name: "vm_snapshot_create",
		label: "vm snapshot create",
		description: "Take a snapshot of one of your VMs. A running VM is paused while it is taken, and memory is included.",
		parameters: Type.Object({ name: VM_NAME, snapshot: SNAPSHOT_NAME }),
		outputSchema: SNAPSHOT,
		annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
		run: async (params, token, signal) =>
			(await call("POST", ["vms", params.name, "snapshots"], { token, signal, body: { name: params.snapshot } })) as object,
	});

	tool({
		name: "vm_snapshot_delete",
		label: "vm snapshot delete",
		description: "Delete a snapshot of one of your VMs.",
		parameters: Type.Object({ name: VM_NAME, snapshot: SNAPSHOT_NAME }),
		outputSchema: Type.Object({ name: Type.String(), snapshot: Type.String(), deleted: Type.Boolean() }),
		annotations: DESTROY,
		run: async (params, token, signal) => {
			await call("DELETE", ["vms", params.name, "snapshots", params.snapshot], { token, signal });
			return { name: params.name, snapshot: params.snapshot, deleted: true };
		},
	});

	tool({
		name: "vm_snapshot_revert",
		label: "vm snapshot revert",
		description:
			"Return one of your VMs to a snapshot: running or off as it was then. What was written since is lost.",
		parameters: Type.Object({ name: VM_NAME, snapshot: SNAPSHOT_NAME }),
		outputSchema: VM,
		annotations: DESTROY,
		run: async (params, token, signal) =>
			(await call("POST", ["vms", params.name, "snapshots", params.snapshot, "revert"], { token, signal })) as object,
	});
}
