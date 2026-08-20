#!/usr/bin/env bash
#
# Issue the wildcard Cloudflare Origin CA certificate the proxy serves.
#
# Run it by hand, with a token in the environment:
#
#   CLOUDFLARE_API_TOKEN=... devbox/proxy/bin/issue-origin-cert.sh
#
# The token needs Zone / SSL and Certificates / Edit on the zone. It is read
# from the environment and never written anywhere: docs/adr/0002 explains why
# an issuing credential does not get to live on this box.
#
# This is both the first-time setup and the renewal and the recovery. Cloudflare
# shows the private key once and does not keep a copy, so there is no way to
# fetch the current one back -- if it is lost, or about to expire, the answer is
# to run this again. Nothing sends a reminder; `devbox-proxy status` prints the
# expiry date.

set -euo pipefail

PROXY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Overridable so that the tests can point it at a stand-in.
API=${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}

# Cloudflare accepts 7, 30, 90, 365, 730, 1095 or 5475 days. Fifteen years is
# the longest, and since renewal is manual, the longest is the kind one.
VALIDITY_DAYS=5475

usage() {
    cat <<EOF
usage: $(basename "$0") [options]

  --config FILE      declaration file, for the zone name
  --state-dir DIR    where to write the certificate
                     (default: \${DEVBOX_PROXY_STATE:-\$HOME/.config/devbox-proxy})
  --zone ZONE        override the zone from the declaration file
  --force            replace an existing certificate

Environment:
  CLOUDFLARE_API_TOKEN        token with Zone / SSL and Certificates / Edit
  CLOUDFLARE_ORIGIN_CA_KEY    the older Origin CA Key, used if no token is set
EOF
}

die() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

default_config() {
    local named=${PROXY_DIR}/services.$(hostname -s).yaml
    [[ -f ${named} ]] && echo "${named}" || echo "${PROXY_DIR}/services.yaml"
}

config=${DEVBOX_PROXY_CONFIG:-$(default_config)}
state_dir=${DEVBOX_PROXY_STATE:-${HOME}/.config/devbox-proxy}
zone=
force=

while [[ $# -gt 0 ]]; do
    case $1 in
        --config) config=$2; shift 2 ;;
        --state-dir) state_dir=$2; shift 2 ;;
        --zone) zone=$2; shift 2 ;;
        --force) force=yes; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

command -v openssl > /dev/null || die "openssl is not installed"
command -v curl > /dev/null || die "curl is not installed"
command -v jq > /dev/null || die "jq is not installed"

if [[ -z ${zone} ]]; then
    command -v yq > /dev/null || die "yq is not installed"
    [[ -f ${config} ]] || die "no declaration file at ${config}; pass --zone instead"
    zone=$(yq -r '.zone // ""' "${config}")
    [[ -n ${zone} ]] || die "${config} does not name a zone"
fi

certs=${state_dir}/certs
cert_file=${certs}/origin.pem
key_file=${certs}/origin.key

if [[ -e ${key_file} && -z ${force} ]]; then
    echo "$(basename "$0"): ${key_file} already exists." >&2
    openssl x509 -in "${cert_file}" -noout -enddate 2> /dev/null >&2 || true
    die "pass --force to replace it (the current key cannot be recovered afterwards)"
fi

auth=()
if [[ -n ${CLOUDFLARE_API_TOKEN:-} ]]; then
    auth=(-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}")
elif [[ -n ${CLOUDFLARE_ORIGIN_CA_KEY:-} ]]; then
    # The endpoint predates API tokens and still takes the Origin CA Key.
    auth=(-H "X-Auth-User-Service-Key: ${CLOUDFLARE_ORIGIN_CA_KEY}")
else
    die "set CLOUDFLARE_API_TOKEN (Zone / SSL and Certificates / Edit) in the environment"
fi

# The private key is written where only its owner can read it, and it is
# written there directly: a world-readable temporary file that is chmod'ed
# afterwards has already leaked.
umask 077
mkdir -p "${certs}"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

echo "Generating a new key and CSR for *.${zone}"
openssl genrsa -out "${work}/origin.key" 2048 2> /dev/null
openssl req -new -key "${work}/origin.key" -subj "/CN=*.${zone}" -out "${work}/origin.csr"

# `hostnames` is what Cloudflare signs; the CSR subject is not consulted. Both
# the wildcard and the apex go in, because a wildcard covers neither the apex
# nor a second level (docs/adr/0002).
request=$(jq -n \
    --arg wildcard "*.${zone}" \
    --arg apex "${zone}" \
    --arg csr "$(cat "${work}/origin.csr")" \
    --argjson validity "${VALIDITY_DAYS}" \
    '{
        hostnames: [$wildcard, $apex],
        requested_validity: $validity,
        request_type: "origin-rsa",
        csr: $csr
    }')

echo "Asking Cloudflare to sign it"
response=$(curl -sS --fail-with-body -X POST "${API}/certificates" \
    "${auth[@]}" \
    -H "Content-Type: application/json" \
    --data "${request}") || die "the Cloudflare API call failed: ${response}"

if [[ $(jq -r '.success' <<< "${response}") != "true" ]]; then
    die "Cloudflare refused: $(jq -c '.errors' <<< "${response}")"
fi

jq -r '.result.certificate' <<< "${response}" > "${work}/origin.pem"
[[ -s ${work}/origin.pem ]] || die "Cloudflare returned no certificate"

# Move both into place only once both exist, so a failure never leaves a
# certificate next to the wrong key.
mv "${work}/origin.pem" "${cert_file}"
mv "${work}/origin.key" "${key_file}"
chmod 600 "${key_file}"
chmod 644 "${cert_file}"

echo "Wrote ${cert_file} and ${key_file}"
echo "Certificate id: $(jq -r '.result.id' <<< "${response}")"
openssl x509 -in "${cert_file}" -noout -subject -enddate

cat <<EOF

Two things this does not do for you:

  - The zone's SSL mode must be Full (strict). Cloudflare will not verify this
    certificate otherwise, and Full alone would accept a forged one.
  - Nothing will remind you when this expires. \`devbox-proxy status\` prints
    the date; re-run this script to replace it.

Restart the proxy to pick it up:  devbox-proxy reload
EOF
