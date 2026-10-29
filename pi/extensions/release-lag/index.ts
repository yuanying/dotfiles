// release-lag の一覧を読むツール。codemode のスクリプトからだけ呼ぶ (exposure "codemode")。
// 17 件ほどの一覧をそのままモデルに見せるより、スクリプトで絞り込ませたいため。
// API と token の扱いは client.ts。

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { call, readToken, type Report } from "./client.ts";

const NAMESPACE = {
	name: "release_lag",
	aliases: ["release-lag"],
	description: "How far each of yuanying's Renovate-managed GitHub repositories has drifted from its latest release",
	instructions: [
		"The data comes from https://release-lag.fraction.jp (yuanying/release-lag), which re-scans GitHub every hour.",
		"Tracked repositories: owner yuanying, not forks, not archived, with a Renovate config on the default branch.",
		"The latest release is the highest semver tag (with or without a leading v; prereleases are ignored).",
		"commitsSinceRelease counts non-merge commits from that tag to the default branch; nonRenovateCommitsSinceRelease excludes renovate[bot].",
		"A weekly job releases a patch automatically when only Renovate commits are pending, so repositories with nonRenovateCommitsSinceRelease > 0 need a release cut by hand.",
		"Repositories without a tag have released: false and null release fields. A repository whose scan failed has an error field.",
		"Repositories come sorted by time since release, longest first, unreleased ones first.",
	].join("\n"),
};

const REPORT_SCHEMA = Type.Object({
	owner: Type.String(),
	refreshedAt: Type.Union([Type.String({ description: "RFC 3339. When repositories were measured" }), Type.Null()]),
	lastAttemptAt: Type.Union([Type.String({ description: "RFC 3339. When the last scan ended, successful or not" }), Type.Null()]),
	lastSuccess: Type.Boolean({ description: "Whether the last scan measured every repository" }),
	lastError: Type.String({ description: "Why the last scan failed; empty on success" }),
	repositories: Type.Array(
		Type.Object({
			name: Type.String({ description: "Repository name without the owner" }),
			url: Type.String(),
			defaultBranch: Type.String(),
			private: Type.Boolean(),
			released: Type.Boolean({ description: "false when the repository has no release tag" }),
			latestTag: Type.Union([Type.String(), Type.Null()]),
			releasedAt: Type.Union([Type.String({ description: "RFC 3339 date of latestTag" }), Type.Null()]),
			daysSinceRelease: Type.Union([Type.Integer(), Type.Null()]),
			commitsSinceRelease: Type.Union([Type.Integer({ description: "Non-merge commits since latestTag" }), Type.Null()]),
			nonRenovateCommitsSinceRelease: Type.Union([Type.Integer({ description: "Of those, not by renovate[bot]" }), Type.Null()]),
			compareUrl: Type.Union([Type.String({ description: "GitHub compare page from latestTag to the default branch" }), Type.Null()]),
			error: Type.Optional(Type.String({ description: "Why the repository could not be measured" })),
		}),
	),
});

function result(report: Report, ok = true) {
	return {
		content: [{ type: "text" as const, text: JSON.stringify(report) }],
		structuredContent: report,
		details: undefined,
		...(ok ? {} : { isError: true }),
	};
}

export default function (pi: ExtensionAPI) {
	pi.registerTool({
		name: "release_lag_repos",
		label: "release-lag",
		description: "List the release lag of every tracked repository, as of the last scan (refreshedAt).",
		promptGuidelines: ["Filter and summarize the repositories in the script instead of returning the whole list."],
		parameters: Type.Object({}),
		outputSchema: REPORT_SCHEMA,
		exposure: "codemode",
		namespace: NAMESPACE,
		annotations: { readOnlyHint: true, openWorldHint: true },
		async execute(_toolCallId, _params, signal) {
			const { report } = await call("GET", "/api/repos", { token: readToken(), signal });
			return result(report);
		},
	});

	pi.registerTool({
		name: "release_lag_refresh",
		label: "release-lag refresh",
		description:
			"Re-scan GitHub now and return the new list. Takes a while and uses GitHub rate limit; call it only when the user wants fresh data (for example right after cutting a release). On a failed scan the result is an error that still carries the list, with lastError set.",
		parameters: Type.Object({}),
		outputSchema: REPORT_SCHEMA,
		exposure: "codemode",
		namespace: NAMESPACE,
		annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
		async execute(_toolCallId, _params, signal) {
			const { ok, report } = await call("POST", "/api/refresh", { token: readToken(), signal });
			return result(report, ok);
		},
	});
}
