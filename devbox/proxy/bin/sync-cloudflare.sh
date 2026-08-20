#!/usr/bin/env bash
#
# Reconcile Cloudflare with the declaration file: the AAAA records that point
# at this devbox, and the Access applications that guard them.
#
#   CLOUDFLARE_API_TOKEN=... devbox/proxy/bin/sync-cloudflare.sh --dry-run
#   CLOUDFLARE_API_TOKEN=... devbox/proxy/bin/sync-cloudflare.sh
#
# The token needs, on the account holding the zone:
#
#   Zone    / Zone                                                   / Read
#   Zone    / DNS                                                    / Edit
#   Account / Access: Apps and Policies                              / Edit
#   Account / Access: Organizations, Identity Providers, and Groups  / Read
#
# It is read from the environment for the length of one run. docs/adr/0002 has
# the reasoning; the short version is that a resident token with this much
# authority is worth more to an attacker than anything it protects here.
#
# Creating an application yields the audience tag Cloudflare generates, and
# that tag is written back into the declaration file, because the origin has to
# check it (docs/adr/0003). Commit the resulting diff.
#
# By default nothing is deleted. --prune removes AAAA records and Access
# applications for names in this zone that the declaration file no longer
# mentions, and even then only ones of the form <label>.<zone>.

set -euo pipefail

PROXY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Overridable so that the tests can point it at a stand-in.
API=${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}

usage() {
    cat <<EOF
usage: $(basename "$0") [options]

  --config FILE   declaration file (default: the one named after this host)
  --dry-run       print what would change and stop
  --prune         also delete records and applications no longer declared
EOF
}

die() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

step() {
    echo "==> $*"
}

default_config() {
    local named=${PROXY_DIR}/services.$(hostname -s).yaml
    [[ -f ${named} ]] && echo "${named}" || echo "${PROXY_DIR}/services.yaml"
}

config=${DEVBOX_PROXY_CONFIG:-$(default_config)}
dry_run=
prune=

while [[ $# -gt 0 ]]; do
    case $1 in
        --config) config=$2; shift 2 ;;
        --dry-run) dry_run=yes; shift ;;
        --prune) prune=yes; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

for tool in curl jq yq; do
    command -v "${tool}" > /dev/null || die "${tool} is not installed"
done
[[ -f ${config} ]] || die "no declaration file at ${config}"
[[ -n ${CLOUDFLARE_API_TOKEN:-} ]] || die "set CLOUDFLARE_API_TOKEN in the environment"

declaration=$(yq -o=json '.' "${config}")
zone=$(jq -r '.zone // ""' <<< "${declaration}")
origin=$(jq -r '.origin // ""' <<< "${declaration}")
team_domain=$(jq -r '.team_domain // ""' <<< "${declaration}")
[[ -n ${zone} ]] || die "${config} does not name a zone"
[[ -n ${origin} ]] || die "${config} does not name an origin address"

# ---------------------------------------------------------------------------
# Cloudflare plumbing
# ---------------------------------------------------------------------------

# Every call goes through here, so that a Cloudflare-level failure is reported
# once with its errors rather than as an empty jq result three lines later.
api() {
    local method=$1 path=$2 body=${3:-}
    local args=(-sS -X "${method}" "${API}${path}"
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
        -H "Content-Type: application/json")
    [[ -n ${body} ]] && args+=(--data "${body}")

    local response
    response=$(curl "${args[@]}") || die "${method} ${path}: the request failed"
    if [[ $(jq -r '.success' <<< "${response}") != "true" ]]; then
        die "${method} ${path}: $(jq -c '.errors' <<< "${response}")"
    fi
    jq '.result' <<< "${response}"
}

# In a dry run the reads still happen -- knowing what is already there is the
# whole point -- but nothing that changes state does.
mutate() {
    local what=$1
    shift
    if [[ -n ${dry_run} ]]; then
        echo "    would ${what}"
        return 0
    fi
    echo "    ${what}"
    api "$@" > /dev/null
}

# True when $1 is a single label directly under the zone. Everything else in
# the zone belongs to something other than this devbox and is never touched.
in_namespace() {
    local fqdn=$1 label=${1%".${zone}"}
    [[ ${fqdn} == "${label}.${zone}" && ${label} != *.* ]]
}

step "Looking up ${zone}"
zone_json=$(api GET "/zones?name=${zone}")
zone_id=$(jq -r '.[0].id // ""' <<< "${zone_json}")
account_id=$(jq -r '.[0].account.id // ""' <<< "${zone_json}")
[[ -n ${zone_id} ]] || die "no zone named ${zone} is visible to this token"
echo "    zone ${zone_id}, account ${account_id}"

declared=$(jq -r '(.services // [])[].name' <<< "${declaration}")

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

step "Reconciling AAAA records"
records=$(api GET "/zones/${zone_id}/dns_records?type=AAAA&per_page=1000")

while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    fqdn=${name}.${zone}
    existing=$(jq -r --arg fqdn "${fqdn}" \
        '.[] | select(.name == $fqdn) | .id' <<< "${records}" | head -1)
    body=$(jq -n --arg name "${fqdn}" --arg content "${origin}" \
        '{type: "AAAA", name: $name, content: $content, proxied: true, ttl: 1}')

    if [[ -z ${existing} ]]; then
        mutate "create AAAA ${fqdn} -> ${origin} (proxied)" \
            POST "/zones/${zone_id}/dns_records" "${body}"
    else
        current=$(jq -r --arg fqdn "${fqdn}" \
            '.[] | select(.name == $fqdn) | "\(.content) \(.proxied)"' <<< "${records}" | head -1)
        if [[ ${current} == "${origin} true" ]]; then
            echo "    AAAA ${fqdn} is already correct"
        else
            mutate "update AAAA ${fqdn}: ${current} -> ${origin} true" \
                PUT "/zones/${zone_id}/dns_records/${existing}" "${body}"
        fi
    fi
done <<< "${declared}"

if [[ -n ${prune} ]]; then
    # Proxied records only. This script never creates a grey-cloud record, so
    # it has no business deleting one -- and there is one that matters:
    # anietta.oeilvert.org is the raw address SSH and mosh reach the devbox on,
    # it points at the same origin, and it is a single label under the zone.
    # Without this it would look exactly like an abandoned service.
    while IFS= read -r fqdn; do
        [[ -n ${fqdn} ]] || continue
        in_namespace "${fqdn}" || continue
        grep -qxF "${fqdn%".${zone}"}" <<< "${declared}" && continue
        id=$(jq -r --arg fqdn "${fqdn}" \
            '.[] | select(.name == $fqdn and .proxied == true) | .id' <<< "${records}" | head -1)
        [[ -n ${id} ]] || continue
        mutate "delete AAAA ${fqdn}" DELETE "/zones/${zone_id}/dns_records/${id}"
    done < <(jq -r '.[].name' <<< "${records}")
fi

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

authenticated=$(jq -r '
    . as $root
    | (.services // [])[]
    | select((.auth // ($root.defaults.auth // "required")) == "required")
    | .name' <<< "${declaration}")

if [[ -z ${authenticated} && -z ${prune} ]]; then
    step "No service asks for authentication; leaving Access alone"
    exit 0
fi

[[ -n ${account_id} ]] || die "the token cannot see the account behind ${zone}, and Access needs it"

step "Reconciling Access applications"
apps=$(api GET "/accounts/${account_id}/access/apps?per_page=1000")

# A GitHub organisation rule names the identity provider it belongs to, so the
# provider has to be looked up. Only done when something actually asks for one:
# an email-only policy needs neither the provider nor the token permission that
# reads it.
github_idp=
github_idp_for() {
    if [[ -z ${github_idp} ]]; then
        github_idp=$(api GET "/accounts/${account_id}/access/identity_providers" |
            jq -r '[.[] | select(.type == "github")][0].id // ""')
        [[ -n ${github_idp} ]] ||
            die "no GitHub identity provider exists in Zero Trust; add one before using github_orgs"
    fi
    echo "${github_idp}"
}

while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    fqdn=${name}.${zone}

    viewers=$(jq -c --arg name "${name}" \
        '(.services // [])[] | select(.name == $name) | (.viewers // {})' <<< "${declaration}")

    idp=
    if [[ $(jq -r '(.github_orgs // []) | length' <<< "${viewers}") != "0" ]]; then
        idp=$(github_idp_for)
    fi

    include=$(jq -c --arg idp "${idp}" '
        [(.emails // [])[] | {email: {email: .}}]
        + [(.github_orgs // [])[] | {"github-organization": {name: ., identity_provider_id: $idp}}]
    ' <<< "${viewers}")

    if [[ ${include} == "[]" ]]; then
        die "${name}: auth is required but no viewers are listed, and an Access application with no allow rule locks out everyone including you"
    fi

    body=$(jq -n --arg name "devbox ${name}" --arg domain "${fqdn}" --argjson include "${include}" '
        {
            name: $name,
            domain: $domain,
            type: "self_hosted",
            session_duration: "24h",
            policies: [{name: "devbox-proxy", decision: "allow", include: $include}]
        }')

    app=$(jq -c --arg domain "${fqdn}" '[.[] | select(.domain == $domain)][0] // null' <<< "${apps}")
    if [[ ${app} == "null" ]]; then
        if [[ -n ${dry_run} ]]; then
            echo "    would create an Access application for ${fqdn}"
            echo "    would record the aud tag it returns in ${config}"
            continue
        fi
        echo "    create an Access application for ${fqdn}"
        aud=$(api POST "/accounts/${account_id}/access/apps" "${body}" | jq -r '.aud')
    else
        app_id=$(jq -r '.id' <<< "${app}")
        mutate "update the Access application for ${fqdn}" \
            PUT "/accounts/${account_id}/access/apps/${app_id}" "${body}"
        aud=$(jq -r '.aud' <<< "${app}")
    fi

    # The origin checks this tag on every request, so the declaration file has
    # to carry it. It is an identifier, not a credential.
    recorded=$(jq -r --arg name "${name}" \
        '(.services // [])[] | select(.name == $name) | (.aud // "")' <<< "${declaration}")
    if [[ -n ${aud} && ${aud} != "null" && ${aud} != "${recorded}" ]]; then
        if [[ -n ${dry_run} ]]; then
            echo "    would record aud ${aud} for ${name} in ${config}"
        else
            echo "    recording aud ${aud} for ${name} in ${config}"
            yq -i "(.services[] | select(.name == \"${name}\")).aud = \"${aud}\"" "${config}"
        fi
    fi
done <<< "${authenticated}"

if [[ -n ${prune} ]]; then
    # An application whose service went away, or whose service is now public.
    while IFS= read -r entry; do
        [[ -n ${entry} ]] || continue
        domain=${entry%% *}
        app_id=${entry##* }
        in_namespace "${domain}" || continue
        grep -qxF "${domain%".${zone}"}" <<< "${authenticated}" && continue
        mutate "delete the Access application for ${domain}" \
            DELETE "/accounts/${account_id}/access/apps/${app_id}"
    done < <(jq -r '.[] | "\(.domain) \(.id)"' <<< "${apps}")
fi

step "Done"
if [[ -n ${dry_run} ]]; then
    echo "    nothing was changed (--dry-run)"
else
    echo "    commit the aud tags written into ${config}, then: devbox-proxy reload"
    if [[ -z ${team_domain} ]]; then
        echo "    warning: ${config} sets no team_domain, so the origin cannot verify anything" >&2
    fi
fi
