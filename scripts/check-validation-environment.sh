#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

missing=()

need_command() {
  local name=$1
  if ! command -v "$name" >/dev/null 2>&1; then
    missing+=("$name")
  fi
}

need_command git
need_command python3
need_command go
need_command gofmt
need_command docker
need_command shellcheck

if command -v python3 >/dev/null 2>&1; then
  if ! python3 - <<'PY' >/dev/null 2>&1
import yaml
PY
  then
    missing+=("python3-yaml")
  fi
fi

if command -v docker >/dev/null 2>&1; then
  if ! docker compose version >/dev/null 2>&1; then
    missing+=("docker compose")
  fi
fi

if ((${#missing[@]})); then
  printf 'validation environment is incomplete\n' >&2
  printf 'missing required tools:\n' >&2
  printf -- '- %s\n' "${missing[@]}" >&2
  exit 1
fi

printf 'validation environment is ready\n'

printf '\nrun full source validation with:\n'
printf '  python3 ./scripts/validate-source.py\n'
printf '\nrun Docker validation with Docker Desktop or Docker Engine available; on Windows, prefer:\n'
printf '  .\\RUN_DOCKER_VALIDATION.cmd\n'
