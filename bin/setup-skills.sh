#!/usr/bin/env bash
#
# Link skills/ into the two directories agents read skills from.
#
#   bin/setup-skills.sh                      # every skill in skills/
#   bin/setup-skills.sh skills/devbox-publish   # just that one
#
# Same rules as yuanying/skills' install-skills.sh, because a machine usually
# has both trees linked into the same directories: every conflict is found
# before anything is linked, so a clash leaves the whole tree as it was rather
# than half installed; and a link that already points where it should is left
# alone, so this can be run on every setup.
#
# The links matter beyond loading the skill. A skill reached through
# ~/.claude/skills/<name> resolves its own directory to find the rest of this
# repository -- devbox-publish reads devbox/proxy/services.<hostname>.yaml that
# way -- so the link has to point at the working copy, not at a copy of it.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
skills_dir="${repo_root}/skills"

targets=(
  "${HOME}/.agents/skills"
  "${HOME}/.claude/skills"
)

if [[ ! -d "${skills_dir}" ]]; then
  echo "skills directory not found: ${skills_dir}" >&2
  exit 1
fi

skill_paths=()
if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    skill_path="${repo_root}/${arg}"
    if [[ ! -d "${skill_path}" ]]; then
      echo "skill directory not found: ${skill_path}" >&2
      exit 1
    fi
    if [[ ! -f "${skill_path}/SKILL.md" ]]; then
      echo "SKILL.md not found in: ${skill_path}" >&2
      exit 1
    fi
    skill_paths+=("${skill_path}")
  done
else
  for skill_path in "${skills_dir}"/*; do
    [[ -d "${skill_path}" ]] || continue
    [[ -f "${skill_path}/SKILL.md" ]] || continue
    skill_paths+=("${skill_path}")
  done
fi

if [[ ${#skill_paths[@]} -eq 0 ]]; then
  echo "no skills found in ${skills_dir}" >&2
  exit 1
fi

has_conflict=0

for target_dir in "${targets[@]}"; do
  for skill_path in "${skill_paths[@]}"; do
    skill_name="$(basename "${skill_path}")"
    link_path="${target_dir}/${skill_name}"

    if [[ -L "${link_path}" ]]; then
      current_target="$(readlink "${link_path}")"
      if [[ "${current_target}" == "${skill_path}" ]]; then
        continue
      fi
      echo "conflict: ${link_path} is a symlink to ${current_target}" >&2
      has_conflict=1
      continue
    fi

    if [[ -e "${link_path}" ]]; then
      echo "conflict: ${link_path} already exists and is not a symlink" >&2
      has_conflict=1
    fi
  done
done

if [[ ${has_conflict} -ne 0 ]]; then
  echo "aborting without changes because conflicts were found" >&2
  exit 1
fi

for target_dir in "${targets[@]}"; do
  mkdir -p "${target_dir}"

  for skill_path in "${skill_paths[@]}"; do
    skill_name="$(basename "${skill_path}")"
    link_path="${target_dir}/${skill_name}"

    if [[ -L "${link_path}" ]]; then
      echo "exists: ${link_path} -> ${skill_path}"
      continue
    fi

    ln -s "${skill_path}" "${link_path}"
    echo "linked: ${link_path} -> ${skill_path}"
  done
done
