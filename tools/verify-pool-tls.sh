#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

pool_url="${1:-${CMFD_POOL_URL:-}}"

fail() {
  printf 'CMFD_POOL_TLS_ERROR %s\n' "$*" >&2
  exit 1
}

[[ -n "${pool_url}" ]] || fail 'a complete cmfd+tls URL is required'
if [[ ! "${pool_url}" =~ ^cmfd\+tls://(([0-9]{1,3}\.){3}[0-9]{1,3}):([0-9]{1,5})\?pin=([0-9A-Fa-f]{64})$ ]]; then
  fail 'URL must be cmfd+tls://NUMERIC_IP:PORT?pin=64_HEX'
fi

host="${BASH_REMATCH[1]}"
port="${BASH_REMATCH[3]}"
expected_pin="${BASH_REMATCH[4],,}"

IFS=. read -r octet1 octet2 octet3 octet4 <<<"${host}"
for octet in "${octet1}" "${octet2}" "${octet3}" "${octet4}"; do
  ((10#${octet} <= 255)) || fail "invalid IPv4 address: ${host}"
done
((10#${port} >= 1 && 10#${port} <= 65535)) || fail "invalid TCP port: ${port}"

for command_name in mktemp openssl sha256sum timeout; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "required command not found: ${command_name}"
done

temporary_directory="$(mktemp -d -t cmfd-pool-tls.XXXXXX)"
trap 'rm -rf -- "${temporary_directory}"' EXIT
certificate_dump="${temporary_directory}/server-certificate.pem"
handshake_errors="${temporary_directory}/handshake.stderr"

set +e
timeout "${CMFD_TLS_TIMEOUT_SECONDS:-15}s" openssl s_client \
  -connect "${host}:${port}" -tls1_3 -showcerts </dev/null \
  >"${certificate_dump}" 2>"${handshake_errors}"
handshake_status=$?
set -e

if ! grep -q -- '-----BEGIN CERTIFICATE-----' "${certificate_dump}"; then
  sed -n '1,20p' "${handshake_errors}" >&2
  fail "TLS certificate unavailable from ${host}:${port} (openssl status ${handshake_status})"
fi

observed_pin="$(openssl x509 -in "${certificate_dump}" -outform DER | sha256sum | awk '{print tolower($1)}')"
[[ "${observed_pin}" == "${expected_pin}" ]] || fail "certificate pin mismatch expected=${expected_pin} observed=${observed_pin}"

not_before="$(openssl x509 -in "${certificate_dump}" -noout -startdate | cut -d= -f2-)"
not_after="$(openssl x509 -in "${certificate_dump}" -noout -enddate | cut -d= -f2-)"
printf 'CMFD_POOL_TLS_OK host=%s port=%s pin=%s not_before=%q not_after=%q\n' \
  "${host}" "${port}" "${observed_pin}" "${not_before}" "${not_after}"
