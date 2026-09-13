#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/blue-ci.sh <repo-url> <ref> <workflow-path> [event] [-- act args...]

Example:
  scripts/blue-ci.sh \
    https://github.com/ConexaoAzulDigital/BlueApps19.git \
    19.0 \
    .act/workflows/blue-smart-pricing.yml \
    workflow_dispatch

Private repositories are supported when one of these environment variables is
set: BLUE_CI_GIT_TOKEN, GH_TOKEN, or GITHUB_TOKEN. The token is passed through
GIT_ASKPASS and is not embedded in the clone URL or printed by this script.

The target repository is cloned into a temporary directory and executed with
this fork's act binary. GitHub Actions does not need to be available.
EOF
}

[[ $# -ge 3 ]] || { usage; exit 2; }
REPO_URL="$1"
REF="$2"
WORKFLOW="$3"
EVENT="${4:-workflow_dispatch}"
if [[ $# -ge 4 ]]; then shift 4; else shift 3; fi
[[ "${1:-}" == "--" ]] && shift || true

ACT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACT_BIN="${ACT_BIN:-$ACT_ROOT/dist/blue-act}"
PLATFORM_IMAGE="${ACT_PLATFORM_IMAGE:-catthehacker/ubuntu:act-latest}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$ACT_BIN" ]]; then
  mkdir -p "$(dirname "$ACT_BIN")"
  (cd "$ACT_ROOT" && go build -o "$ACT_BIN" ./cmd/act)
fi

TOKEN="${BLUE_CI_GIT_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
if [[ -n "$TOKEN" ]]; then
  ASKPASS="$TMP/git-askpass.sh"
  cat >"$ASKPASS" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "${BLUE_CI_GIT_TOKEN:?}" ;;
esac
EOF
  chmod 700 "$ASKPASS"
  BLUE_CI_GIT_TOKEN="$TOKEN" \
  GIT_ASKPASS="$ASKPASS" \
  GIT_TERMINAL_PROMPT=0 \
    git clone --depth 1 --branch "$REF" "$REPO_URL" "$TMP/repo"
else
  GIT_TERMINAL_PROMPT=0 \
    git clone --depth 1 --branch "$REF" "$REPO_URL" "$TMP/repo"
fi

exec "$ACT_BIN" \
  --directory "$TMP/repo" \
  --platform "ubuntu-latest=$PLATFORM_IMAGE" \
  --workflows "$TMP/repo/$WORKFLOW" \
  "$EVENT" \
  "$@"
