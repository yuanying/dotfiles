// macOS のサンドボックス。@anthropic-ai/sandbox-runtime (sandbox-exec) に任せる。
// network.allowedDomains を渡さないので、プロキシは立たずネットワークは素通し。
// devbox のテストでは通らない経路 (docs/adr/0013)。

import type { Policy } from "./policy.ts";

type Manager = {
	initialize(config: unknown): Promise<void>;
	updateConfig(config: unknown): void;
	wrapWithSandbox(command: string): Promise<string>;
	cleanupAfterCommand(): void;
	reset(): Promise<void>;
};

let manager: Manager | undefined;

function runtimeConfig(policy: Policy): unknown {
	return {
		network: { deniedDomains: [], allowAllUnixSockets: policy.allowAllUnixSockets },
		filesystem: { denyRead: policy.denyRead, allowWrite: policy.writable, denyWrite: policy.denyWrite },
	};
}

/** コマンドを sandbox-exec で包んだシェルコマンドにする。 */
export async function wrapForMacos(policy: Policy, command: string): Promise<string> {
	if (!manager) {
		const runtime = (await import("@anthropic-ai/sandbox-runtime")) as unknown as { SandboxManager: Manager };
		await runtime.SandboxManager.initialize(runtimeConfig(policy));
		manager = runtime.SandboxManager;
	} else {
		manager.updateConfig(runtimeConfig(policy));
	}
	return manager.wrapWithSandbox(command);
}

export function cleanupAfterMacosCommand(): void {
	manager?.cleanupAfterCommand();
}

export async function resetMacos(): Promise<void> {
	const current = manager;
	manager = undefined;
	await current?.reset();
}
