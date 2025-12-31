#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ENV_FILE="$ROOT_DIR/.prod.env"
RUNTIME_ENV_FILE="$ROOT_DIR/.prod.secrets.env"

usage() {
  cat <<'USAGE'
Usage:
  ./prod.sh init [--force] [--out <file>] [--llm-key <key>]

Creates/updates a runtime env file (default: .prod.secrets.env) based on .prod.env,
generating secure secrets for variables set to CHANGE_ME.

Options:
  --out <file>      Output env file path (default: .prod.secrets.env)
  --llm-key <key>   Set LLM_BINDING_API_KEY to this value
  --force           Overwrite output file if it exists

Run with docker-compose:
  docker compose --env-file .prod.secrets.env -f docker-compose.prod.yaml up -d
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || die "Missing required file: $1"
}

cmd="${1:-}"
shift || true

force="false"
llm_key=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --force)
      force="true"
      shift
      ;;
    --out)
      RUNTIME_ENV_FILE="$ROOT_DIR/${2:?missing value for --out}"
      shift 2
      ;;
    --llm-key)
      llm_key="${2:?missing value for --llm-key}"
      shift 2
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

case "$cmd" in
  init)
    require_file "$TEMPLATE_ENV_FILE"

    if [[ -f "$RUNTIME_ENV_FILE" && "$force" != "true" ]]; then
      die "Refusing to overwrite existing $RUNTIME_ENV_FILE (use --force)"
    fi

    TEMPLATE_ENV_FILE="$TEMPLATE_ENV_FILE" \
    RUNTIME_ENV_FILE="$RUNTIME_ENV_FILE" \
    LLM_KEY="$llm_key" \
    python3 - <<'PY'
import os
import secrets
from pathlib import Path

template_path = Path(os.environ["TEMPLATE_ENV_FILE"])
out_path = Path(os.environ["RUNTIME_ENV_FILE"])

template = template_path.read_text(encoding="utf-8")

def gen_api_key() -> str:
    # URL-safe, no '=' padding, long enough for prod usage.
    return secrets.token_urlsafe(48)

def gen_password() -> str:
    # Strong password-like token.
    return secrets.token_urlsafe(36)

replacements: dict[str, str] = {}

# Generate only for placeholders.
for key, generator in {
    'LIGHTRAG_API_KEY': gen_api_key,
    'TOKEN_SECRET': gen_password,
    'NEO4J_PASSWORD': gen_password,
}.items():
    marker = f"{key}=CHANGE_ME"
    if marker in template:
        replacements[key] = generator()

# Optionally set LLM key if provided.
llm_key = os.environ.get("LLM_KEY", "")
if llm_key:
    replacements['LLM_BINDING_API_KEY'] = llm_key

lines = template.splitlines(True)
out_lines: list[str] = []

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith('#') or '=' not in line:
        out_lines.append(line)
        continue

    k, v = line.split('=', 1)
    key = k.strip()
    if key in replacements:
        out_lines.append(f"{key}={replacements[key]}\n")
    else:
        out_lines.append(line)

out_path.write_text(''.join(out_lines), encoding='utf-8')

print(f"Wrote: {out_path}")
if replacements:
    print("Updated keys:")
    for k in sorted(replacements.keys()):
        if k == 'LLM_BINDING_API_KEY':
            suffix = replacements[k][-4:] if len(replacements[k]) >= 4 else "****"
            print(f"- {k}=(provided)***{suffix}")
        else:
            print(f"- {k}=(generated)")
else:
    print("No CHANGE_ME placeholders found; nothing generated.")
PY

    echo "NOTE: Keep $RUNTIME_ENV_FILE secret (do not commit)." >&2
    ;;
  *)
    usage
    exit 2
    ;;
esac
