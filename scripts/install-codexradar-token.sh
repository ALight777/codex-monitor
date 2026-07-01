#!/usr/bin/env bash
set -euo pipefail

token="${CODEXRADAR_API_TOKEN:-}"
if [[ -z "${token}" ]]; then
  if [[ -t 0 ]]; then
    printf "Paste CodexRadar API token: " >&2
  fi
  IFS= read -r -s token
  printf '\n' >&2
fi

token="$(printf '%s' "${token}" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "${token}" ]]; then
  echo "No token provided" >&2
  exit 1
fi

base_dir="${HOME}/Library/Application Support/CodexNotch/CodexRadar"
token_file="${base_dir}/token"

/bin/mkdir -p "${base_dir}"
/bin/chmod 700 "${base_dir}"
/usr/bin/printf '%s\n' "${token}" > "${token_file}"
/bin/chmod 600 "${token_file}"

echo "CodexRadar API token installed at ${token_file}"
