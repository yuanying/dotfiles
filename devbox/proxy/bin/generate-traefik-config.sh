#!/usr/bin/env bash
#
# services.yaml -> Traefik's static and dynamic configuration.
#
# A pure function of the declaration file: same input, same bytes out. That is
# what lets the golden tests compare the output directly, and it is why every
# path that ends up in the generated files derives from a single --state-dir.

set -euo pipefail

PROXY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

DEFAULT_FORWARD_AUTH_PORT=9101

usage() {
    cat <<EOF
usage: $(basename "$0") [options]

  --config FILE      declaration file (default: ${PROXY_DIR}/services.yaml)
  --state-dir DIR    where certificates, logs and configuration live
                     (default: \${DEVBOX_PROXY_STATE:-\$HOME/.config/devbox-proxy})
  --write-to DIR     where to write the generated files
                     (default: <state-dir>/traefik)
EOF
}

die() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

config=${DEVBOX_PROXY_CONFIG:-${PROXY_DIR}/services.yaml}
state_dir=${DEVBOX_PROXY_STATE:-${HOME}/.config/devbox-proxy}
write_to=

while [[ $# -gt 0 ]]; do
    case $1 in
        --config) config=$2; shift 2 ;;
        --state-dir) state_dir=$2; shift 2 ;;
        --write-to) write_to=$2; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

write_to=${write_to:-${state_dir}/traefik}

command -v yq > /dev/null || die "yq is not installed"
command -v jq > /dev/null || die "jq is not installed"
[[ -f ${config} ]] || die "no such declaration file: ${config}"

# Read the declaration once, as JSON, and do everything else with jq. yq's own
# expression language would serve, but jq is already how the rest of this
# repository reads structured data.
declaration=$(yq -o=json '.' "${config}") || die "${config} is not valid YAML"

# The default lives in one place; both the validator and the generator ask for
# it through this filter.
readonly AUTH_OF='def auth_of($svc): $svc.auth // ($root.defaults.auth // "required");'

# ---------------------------------------------------------------------------
# Validation
#
# Everything is checked before a single byte is written, so a bad declaration
# leaves the previous configuration in place instead of half-replacing it.
# ---------------------------------------------------------------------------

problems=$(jq -r ". as \$root | ${AUTH_OF}"'
    def is_label: test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$");
    def named($entry): $entry.value.name // "service #\($entry.key + 1)";

    [
        (if (.zone // "") == "" then "zone is required" else empty end),

        ((.services // []) | to_entries[] as $entry
            | ($entry.value.name // "") as $name
            | if $name == "" then
                  "\(named($entry)): name is required"
              elif ($name | test("\\.")) then
                  "\($name): a service name may not contain a dot -- a wildcard Origin CA "
                  + "certificate and free Universal SSL both stop at one level"
              elif ($name | is_label | not) then
                  "\($name): a service name must be a DNS label "
                  + "(lowercase letters, digits and dashes)"
              else empty end),

        ((.services // []) | map(.name) | group_by(.) | map(select(length > 1) | .[0])[]
            | "duplicate service name: \(.)"),

        ((.services // []) | to_entries[] as $entry
            | $entry.value as $svc
            | if ($svc | has("port") | not) then
                  "\(named($entry)): port is required"
              elif ($svc.port | type) != "number" or ($svc.port | floor) != $svc.port then
                  "\(named($entry)): port must be a whole number"
              elif $svc.port < 1 or $svc.port > 65535 then
                  "\(named($entry)): port \($svc.port) is outside 1-65535"
              else empty end),

        ((.services // []) | to_entries[] as $entry
            | $entry.value as $svc
            | auth_of($svc) as $auth
            | if $auth != "required" and $auth != "none" then
                  "\(named($entry)): auth must be `required` or `none`, not `\($auth)`"
              elif $auth == "required" and ($svc.aud // "") == "" then
                  "\(named($entry)): auth is required, so an aud tag is needed -- run "
                  + "sync-cloudflare.sh to create the Access application and fill it in"
              else empty end),

        (if ((.services // []) | any(auth_of(.) == "required"))
              and (.team_domain // "") == ""
         then "team_domain is required when any service uses auth: required"
         else empty end)
    ] | .[]
' <<< "${declaration}") || die "could not read ${config}"

if [[ -n ${problems} ]]; then
    while IFS= read -r problem; do
        echo "$(basename "$0"): ${config}: ${problem}" >&2
    done <<< "${problems}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

zone=$(jq -r '.zone' <<< "${declaration}")
forward_auth_port=$(jq -r --arg d "${DEFAULT_FORWARD_AUTH_PORT}" \
    '.forward_auth_port // $d' <<< "${declaration}")

cert_file=${state_dir}/certs/origin.pem
key_file=${state_dir}/certs/origin.key

header="# Generated by devbox/proxy/bin/generate-traefik-config.sh from services.yaml.
# Do not edit: change the declaration file and run \`devbox-proxy reload\`."

# Emits `  <name>:` followed by the block, or `  <name>: {}` when the block is
# empty -- YAML has no way to spell an empty mapping across two lines.
section() {
    local name=$1 block=$2
    if [[ -z ${block} ]]; then
        printf '  %s: {}\n' "${name}"
    else
        printf '  %s:\n%s\n' "${name}" "${block}"
    fi
}

# Each section is one jq program, so the ordering and the indentation of the
# generated YAML live next to each other rather than being assembled in bash.
render() {
    jq -r ". as \$root | ${AUTH_OF} $1" \
        --arg zone "${zone}" \
        --arg port "${forward_auth_port}" \
        <<< "${declaration}"
}

middlewares=$(render '
    (.services // [])[] | select(auth_of(.) == "required") |
        "    cf-access-\(.name):",
        "      forwardAuth:",
        "        address: \"http://127.0.0.1:\($port)/verify?service=\(.name)&aud=\(.aud)\"",
        "        authResponseHeaders:",
        "          - X-Devbox-Access-Email",
        "          - X-Devbox-Access-Sub"
')

routers=$(render '
    (.services // [])[] |
        "    \(.name):",
        "      rule: \"Host(`\(.name).\($zone)`)\"",
        "      entryPoints:",
        "        - websecure",
        "      service: \(.name)",
        (if auth_of(.) == "required" then
            "      middlewares:", "        - cf-access-\(.name)"
         else empty end),
        "      tls: {}"
')

backends=$(render '
    (.services // [])[] |
        "    \(.name):",
        "      loadBalancer:",
        "        servers:",
        "          - url: \"http://127.0.0.1:\(.port)\""
')

mkdir -p "${write_to}/dynamic"

cat > "${write_to}/traefik.yml" <<EOF
${header}

global:
  checkNewVersion: false
  sendAnonymousUsage: false

log:
  level: INFO
  filePath: ${state_dir}/log/traefik.log

accessLog:
  filePath: ${state_dir}/log/access.log

entryPoints:
  websecure:
    address: ":443"
    transport:
      respondingTimeouts:
        readTimeout: 0s
        writeTimeout: 0s
        idleTimeout: 180s

providers:
  file:
    directory: ${state_dir}/traefik/dynamic
    watch: true
EOF

{
    printf '%s\n\n' "${header}"
    cat <<EOF
tls:
  stores:
    default:
      defaultCertificate:
        certFile: ${cert_file}
        keyFile: ${key_file}
  certificates:
    - certFile: ${cert_file}
      keyFile: ${key_file}

http:
EOF
    section middlewares "${middlewares}"
    section routers "${routers}"
    section services "${backends}"
} > "${write_to}/dynamic/services.yml"
