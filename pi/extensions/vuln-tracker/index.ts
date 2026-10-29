// vuln-tracker の発見の一覧を読むツール。codemode のスクリプトからだけ呼ぶ (exposure "codemode")。
// 発見は数十件になり PR や workload も入るので、そのままモデルに見せずスクリプトで絞り込ませたい。
// 出力スキーマの状態の値は列挙で縛らない。vuln-tracker が値を足しても読むだけのツールが落ちないように。
// API と token の扱いは client.ts。

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { getFindings, readToken, type Report } from "./client.ts";

const NAMESPACE = {
	name: "vuln_tracker",
	aliases: ["vuln-tracker"],
	description: "Vulnerabilities in the images running on the fraction cluster, and how far each fix has progressed",
	instructions: [
		"The data comes from https://vuln-tracker.fraction.jp (yuanying/vuln-tracker), which scans the images running in production and their candidate versions.",
		"A finding is one vulnerability in one package of one running image version. Only the severities listed in severities are included.",
		"A finding disappears once production no longer has it, so every finding is still unfixed in production.",
		"Whether something is fixed is decided by scanning, never by a pull request: a linked pull request only means someone intends to fix it.",
		"source.state (only for images yuanying builds, selfBuilt: true): unaddressed = not fixed and no open pull request; pr-open = an open pull request in the source repository; merged = gone in the :main image; released = gone in the latest release tag; not-applicable = not a self-built image; unknown = candidates not scanned yet or not scannable.",
		"manifest.state (fleet-infra or k8s-manifests-fraction, named in manifest.repository): no-fix = no fixed version exists yet; unaddressed = a fixed version exists but no open pull request; pr-open = an open pull request bumps it; merged = gone in the version written in git, waiting to be applied to the cluster; unknown = could not be decided.",
		"vex.state is a separate axis from the two above: none = no VEX annotation; otherwise the finding was triaged in VEX (vex.status is the OpenVEX status, vex.reason says why, vex.document links to the statement, vex.reviewBy is when to look again and vex.expired is true once it has passed). vex.pullRequests are linked pull requests that only change VEX.",
		"stage is the single combined stage also used by the metrics (in-git > fixed-in-release / fixed-upstream > fixed-in-main > unfixed / unscannable / pending).",
		"pullRequests[].link says why a pull request is linked: vuln-responder = opened by vuln-responder for this finding; renovate = a Renovate update for the image or package; mentions-id = its title or body names the vulnerability ID.",
		"The same vulnerability can appear in several findings (one per image version); group by vulnerabilityID or image when summarizing.",
	].join("\n"),
};

const PULL_REQUESTS = Type.Array(
	Type.Object({
		url: Type.String(),
		repository: Type.String({ description: "owner/name" }),
		number: Type.Integer(),
		title: Type.String(),
		state: Type.String({ description: "open, merged or closed" }),
		author: Type.String(),
		link: Type.String({
			description: "Why the pull request is linked to the finding: vuln-responder, renovate or mentions-id",
		}),
	}),
);

const NULLABLE_STRING = (description?: string) => Type.Union([Type.String({ description }), Type.Null()]);

const REPORT_SCHEMA = Type.Object({
	generatedAt: Type.String({ description: "RFC 3339. When the findings were computed" }),
	severities: Type.Array(Type.String(), { description: "The severities included, such as CRITICAL and HIGH" }),
	findings: Type.Array(
		Type.Object({
			image: Type.String({ description: "Image repository without the tag" }),
			tag: Type.String(),
			digest: Type.String(),
			vulnerabilityID: Type.String({ description: "CVE-…, GHSA-… and so on" }),
			severity: Type.String(),
			package: Type.String(),
			installedVersion: Type.String(),
			fixedVersion: Type.String({ description: "From Trivy; empty when no fixed version is known" }),
			fixable: Type.Optional(Type.Boolean({ description: "Whether fixedVersion is known" })),
			selfBuilt: Type.Boolean({ description: "Whether yuanying builds this image" }),
			sourceRepository: NULLABLE_STRING("owner/name of the image's source repository"),
			stage: Type.String({ description: "The combined stage, as in the metrics" }),
			source: Type.Object({
				state: Type.String({
					description: "unaddressed, pr-open, merged, released, not-applicable or unknown (see the namespace instructions)",
				}),
				pullRequests: PULL_REQUESTS,
			}),
			manifest: Type.Object({
				state: Type.String({
					description: "no-fix, unaddressed, pr-open, merged or unknown (see the namespace instructions)",
				}),
				repository: NULLABLE_STRING("owner/name of the manifest repository that pins this version"),
				pullRequests: PULL_REQUESTS,
			}),
			vex: Type.Object({
				state: Type.String({ description: "none when there is no VEX annotation" }),
				status: NULLABLE_STRING("OpenVEX status"),
				reviewBy: NULLABLE_STRING("When the VEX statement should be reviewed again"),
				document: NULLABLE_STRING("Link to the VEX document"),
				reason: Type.Optional(NULLABLE_STRING("Why: the impact or action statement")),
				expired: Type.Optional(Type.Boolean({ description: "Whether reviewBy has passed" })),
				pullRequests: Type.Optional(PULL_REQUESTS),
			}),
			workloads: Type.Array(
				Type.Object({ namespace: Type.String(), kind: Type.String(), name: Type.String(), container: Type.String() }),
			),
			firstSeenAt: NULLABLE_STRING("RFC 3339. When the finding was first seen; null if it was there when vuln-tracker was installed"),
		}),
	),
});

function result(report: Report) {
	return {
		content: [{ type: "text" as const, text: JSON.stringify(report) }],
		structuredContent: report,
		details: undefined,
	};
}

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "vuln_tracker_findings",
		label: "vuln-tracker",
		description:
			"List every vulnerability finding in production with its source-side and manifest-side progress, linked pull requests and VEX annotation, as of generatedAt.",
		promptGuidelines: [
			"Filter and summarize the findings in the script (for example by source.state, manifest.state, image or vulnerabilityID) instead of returning the whole list.",
		],
		parameters: Type.Object({}),
		outputSchema: REPORT_SCHEMA,
		exposure: "codemode",
		namespace: NAMESPACE,
		annotations: { readOnlyHint: true, openWorldHint: true },
		async execute(_toolCallId, _params, signal) {
			return result(await getFindings({ token: readToken(), signal }));
		},
	});
}
