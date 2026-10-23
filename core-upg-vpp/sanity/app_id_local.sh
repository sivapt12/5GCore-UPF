#!/usr/bin/env bash
# Local App ID sanity check. This does not use Kubernetes.
#
# It validates the repository filter sets and, with --apply, loads them into
# a running local VPP through its CLI socket.

set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FILTER_DIR=$ROOT/config/app-id.d
OUTPUT_FILE=/tmp/upf-app-id-local.txt
VPP_SOCK=/run/vpp/cli.sock
APPLY=0

usage() {
  cat <<EOF
Usage: $0 [--apply] [--filter-dir DIR] [--output PATH] [--socket PATH]

Validates $ROOT/config/app-id.d and writes VPP CLI commands.
--apply loads those commands into a locally running VPP.
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

while (($#)); do
  case $1 in
    --apply)
      APPLY=1
      shift
      ;;
    --filter-dir)
      FILTER_DIR=${2:?--filter-dir requires a value}
      shift 2
      ;;
    --output)
      OUTPUT_FILE=${2:?--output requires a value}
      shift 2
      ;;
    --socket)
      VPP_SOCK=${2:?--socket requires a value}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option '$1'"
      ;;
  esac
done

GENERATOR=$ROOT/scripts/vpp/app_id_config.sh
[[ -x $GENERATOR ]] || fail "missing generator $GENERATOR"

expected=$(cat <<'EOF'
create upf application proxy name http-health
upf application http-health rule 1000 add l7 regex ^https?://health\.example/healthz
upf application http-health rule 2000 add l7 regex ^https?://api\.example/v1/
EOF
)

"$GENERATOR" generate --filter-dir "$FILTER_DIR" --output "$OUTPUT_FILE"
actual=$(cat "$OUTPUT_FILE")
[[ $actual == "$expected" ]] || fail "generated App ID CLI does not match the local filter sets"

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/missing-app" "$tmp_root/duplicate"
printf 'l7\tmissing-app\t1\t^https?://example\\.test/\n' >"$tmp_root/missing-app/bad.tsv"
printf 'app\tduplicate-app\tproxy\nl7\tduplicate-app\t1\t^https?://one\\.test/\nl7\tduplicate-app\t1\t^https?://two\\.test/\n' >"$tmp_root/duplicate/bad.tsv"

"$GENERATOR" generate --filter-dir "$tmp_root/missing-app" --output "$tmp_root/missing.txt" >/dev/null 2>&1 &&
  fail "undeclared application was accepted"
"$GENERATOR" generate --filter-dir "$tmp_root/duplicate" --output "$tmp_root/duplicate.txt" >/dev/null 2>&1 &&
  fail "duplicate rule was accepted"

echo "Local App ID filter sets are valid: $OUTPUT_FILE"

if ((APPLY == 0)); then
  if [[ ! -S $VPP_SOCK ]]; then
    echo "VPP is not running at $VPP_SOCK; CLI generation check completed."
  fi
  exit 0
fi

[[ -S $VPP_SOCK ]] || fail "local VPP socket $VPP_SOCK does not exist"
command -v vppctl >/dev/null 2>&1 || fail "vppctl is not installed"

"$GENERATOR" apply --filter-dir "$FILTER_DIR" --socket "$VPP_SOCK"
vppctl -s "$VPP_SOCK" show upf applications
echo "Applied local App ID filter sets to $VPP_SOCK."
