#!/usr/bin/env bash
#
# Link skills/ into the two directories agents read skills from.
#
#   bin/setup-skills.sh                      # local and listed external skills
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

warn() {
  echo "warning: $*" >&2
}

refresh_external_repo() {
  local repo="$1" clone="$2" ref="$3" dirty branch current original commit
  if ! command -v ghq >/dev/null; then
    warn "ghq is unavailable: cannot refresh ${repo}"
    return
  fi
  if [[ ! -d "${clone}/.git" ]]; then
    if ! GHQ_ROOT="${external_root}" ghq get -u "${repo}"; then
      warn "could not obtain ${repo}"
      return
    fi
    [[ -n "${ref}" ]] || return 0
  fi
  if ! dirty=$(git -C "${clone}" status --porcelain --untracked-files=all) || [[ -n "${dirty}" ]]; then
    warn "cannot refresh ${repo}: checkout is dirty or unreadable; keeping it as is"
    return
  fi

  if [[ -n "${ref}" ]]; then
    if ! git -C "${clone}" fetch --tags --no-recurse-submodules origin ||
       ! commit=$(git -C "${clone}" rev-parse --verify --end-of-options "${ref}^{commit}") ||
       ! git -C "${clone}" switch --detach "${commit}"; then
      warn "could not check out ${repo} at ${ref}; keeping the current checkout"
    fi
    return
  fi

  if ! branch=$(git -C "${clone}" symbolic-ref --short refs/remotes/origin/HEAD); then
    warn "cannot determine the default branch of ${repo}; keeping the current checkout"
    return
  fi
  branch="${branch#origin/}"
  current=$(git -C "${clone}" symbolic-ref --quiet --short HEAD) || current=""
  original=""
  if [[ "${current}" != "${branch}" ]]; then
    # Removing a pin resumes tracking the default branch. Do not move a checkout
    # on another local branch, and restore a detached checkout if the pull fails.
    if [[ -n "${current}" ]] ||
       ! original=$(git -C "${clone}" rev-parse HEAD) ||
       ! git -C "${clone}" switch "${branch}"; then
      warn "cannot switch ${repo} to ${branch}; keeping the current checkout"
      return
    fi
  fi
  if ! git -C "${clone}" pull --ff-only --no-rebase --no-recurse-submodules origin "${branch}"; then
    if [[ -n "${original}" ]] && ! git -C "${clone}" switch --detach "${original}"; then
      warn "could not restore ${repo} to ${original}"
    fi
    warn "could not fast-forward ${repo}; using the existing clone"
  fi
}

add_external_skills() {
  local manifest="${skills_dir}/external.txt"
  local external_root="${XDG_DATA_HOME:-${HOME}/.local/share}/dotfiles/skill-repos"
  local line repo path ref extra i j clone skill_path
  local -a repos=() paths=() refs=() first=()
  [[ -f "${manifest}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    read -r repo path ref extra <<< "${line}"
    [[ -n "${repo}" && "${repo}" != \#* ]] || continue
    if [[ ! "${repo}" =~ ^[[:alnum:]][[:alnum:].-]*/[[:alnum:]][[:alnum:]_.-]*/[[:alnum:]][[:alnum:]_.-]*$ ||
          "${repo}" == *.git || ! "${path}" =~ ^[[:alnum:]_.-]+(/[[:alnum:]_.-]+)*$ ||
          "/${path}/" == *'/../'* || "/${path}/" == *'/./'* || -n "${extra}" ]]; then
      echo "invalid external skill entry in ${manifest}: ${line}" >&2
      return 1
    fi
    i=${#repos[@]}
    for ((j = 0; j < i; j++)); do
      [[ "${repos[j]}" == "${repo}" ]] || continue
      if [[ "${refs[j]}" != "${ref}" ]]; then
        echo "conflicting refs for ${repo} in ${manifest}" >&2
        return 1
      fi
      break
    done
    repos+=("${repo}")
    paths+=("${path}")
    refs+=("${ref}")
    first+=("${j}")
  done < "${manifest}"

  for ((i = 0; i < ${#repos[@]}; i++)); do
    repo="${repos[i]}"
    clone="${external_root}/${repo}"
    if [[ "${first[i]}" == "${i}" ]]; then
      refresh_external_repo "${repo}" "${clone}" "${refs[i]}"
    fi
    skill_path="${clone}/${paths[i]}"
    if [[ ! -d "${clone}/.git" || ! -f "${skill_path}/SKILL.md" ]]; then
      warn "skipping ${repo}/${paths[i]}: SKILL.md not available"
      continue
    fi
    skill_paths+=("${skill_path}")
  done
}

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
  add_external_skills
fi

if [[ ${#skill_paths[@]} -eq 0 ]]; then
  echo "no skills found in ${skills_dir}" >&2
  exit 1
fi

has_conflict=0

# Two sources with the same name would also collide when the targets are empty.
for ((i = 0; i < ${#skill_paths[@]}; i++)); do
  for ((j = 0; j < i; j++)); do
    if [[ "${skill_paths[i]##*/}" == "${skill_paths[j]##*/}" &&
          "${skill_paths[i]}" != "${skill_paths[j]}" ]]; then
      echo "conflict: ${skill_paths[i]} and ${skill_paths[j]} have the same skill name" >&2
      has_conflict=1
    fi
  done
done

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
