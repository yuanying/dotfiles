#!/usr/bin/env bash
#
# Decides the weekly release. The next patch version is released only when
# every commit since the latest vX.Y.Z tag, merge commits aside, is
# Renovate's, and they changed something that goes into a release. Anything
# a person wrote is left to a tag pushed by hand.
#
#   .github/scripts/plan-release.sh [repository]
#
# Prints the reason. When $GITHUB_OUTPUT is set, writes `version` (empty when
# nothing is released) and `message`, the annotation for the tag.
#
# What does not go into a release is matched by RELEASE_IGNORE, an extended
# regular expression over the paths `git diff --name-only` prints. Workflows,
# the Renovate config and documentation change nothing a user runs.

set -euo pipefail

renovate="renovate[bot]"
ignore="${RELEASE_IGNORE:-^(\.github/|renovate\.json$|docs/|.*\.md$)}"

cd "${1:-.}"

output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$@" >> "${GITHUB_OUTPUT}"
  fi
}

no_release() {
  echo "no release: $1"
  output "version="
  exit 0
}

tag="$(git tag --list --merged HEAD 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"
[[ -n "${tag}" ]] || no_release "no vX.Y.Z tag is reachable from HEAD"

authors="$(git log --no-merges --format=%an "${tag}..HEAD" | sort -u)"
[[ -n "${authors}" ]] || no_release "there are no commits since ${tag}"

others="$(grep -vxF "${renovate}" <<< "${authors}" || true)"
if [[ -n "${others}" ]]; then
  no_release "commits since ${tag} by $(paste -sd, - <<< "${others}") are left to a release by hand"
fi

changed="$(git diff --name-only "${tag}" HEAD | grep -vE "${ignore}" || true)"
[[ -n "${changed}" ]] || no_release "${renovate}'s commits since ${tag} change nothing that is released"

IFS=. read -r major minor patch <<< "${tag#v}"
version="v${major}.${minor}.$((patch + 1))"
subjects="$(git log --no-merges --reverse --format='- %s' "${tag}..HEAD")"

echo "release ${version}: ${renovate}'s commits since ${tag} change $(paste -sd, - <<< "${changed}")"
delimiter="EOF-$$-${RANDOM}"
output "version=${version}" \
  "message<<${delimiter}" \
  "${version}: dependency updates by Renovate" \
  "" \
  "${subjects}" \
  "${delimiter}"
