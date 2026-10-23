#!/usr/bin/env bash
# Generate or apply UPG-VPP Application ID definitions backed by Hyperscan.
#
# Filter files are tab-separated and are processed in lexical order:
#   app<TAB>NAME<TAB>proxy
#   l7<TAB>APP_NAME<TAB>RULE_ID<TAB>HYPERSCAN_REGEX
#
# APP_NAME may contain letters, numbers, dots, underscores, and dashes.
# RULE_ID must be unique within an application.

set -euo pipefail

FILTER_DIR=/etc/upf/app-id.d
VPP_SOCK=/run/vpp/cli0.sock
OUTPUT_FILE=/etc/upf-app-id0.txt

usage() {
  cat <<'EOF'
Usage: app_id_config.sh [generate|apply] [options]

Options:
  --filter-dir DIR  Directory containing *.tsv filter sets
                    (default: /etc/upf/app-id.d)
  --socket PATH     VPP CLI socket used by apply
  --output PATH     Generated VPP CLI file

Filter set records are tab-separated:
  app<TAB>NAME<TAB>proxy
  l7<TAB>APP_NAME<TAB>RULE_ID<TAB>HYPERSCAN_REGEX
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_name() {
  [[ $1 =~ ^[[:alnum:]_.-]+$ ]] || fail "invalid application name '$1'"
}

require_rule_id() {
  [[ $1 =~ ^[0-9]+$ ]] || fail "invalid rule ID '$1'"
}

MODE=${1:-}
[[ -n $MODE ]] || {
  usage
  exit 2
}
shift

while (($#)); do
  case $1 in
    --filter-dir)
      FILTER_DIR=${2:?--filter-dir requires a value}
      shift 2
      ;;
    --socket)
      VPP_SOCK=${2:?--socket requires a value}
      shift 2
      ;;
    --output)
      OUTPUT_FILE=${2:?--output requires a value}
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

case $MODE in
  generate|apply) ;;
  *)
    usage
    exit 2
    ;;
esac

[[ -d $FILTER_DIR ]] || fail "filter directory '$FILTER_DIR' does not exist"

tmp_file=$(mktemp)
trap 'rm -f "$tmp_file"' EXIT

shopt -s nullglob
filter_files=("$FILTER_DIR"/*.tsv)
shopt -u nullglob

declare -A applications=()
declare -A rules=()

for filter_file in "${filter_files[@]}"; do
  line_number=0
  while IFS=$'\t' read -r record app_name field regex extra || [[ -n ${record}${app_name}${field}${regex}${extra} ]]; do
    ((line_number += 1))
    [[ -z $record || $record == \#* ]] && continue

    case $record in
      app)
        require_name "$app_name"
        [[ -z $regex && -z $extra ]] ||
          fail "$filter_file:$line_number: app records require exactly three fields"
        [[ ! ${applications[$app_name]+present} ]] ||
          fail "$filter_file:$line_number: duplicate application '$app_name'"
        applications[$app_name]=1
        case $field in
          proxy) printf 'create upf application proxy name %s\n' "$app_name" >>"$tmp_file" ;;
          direct) printf 'create upf application name %s\n' "$app_name" >>"$tmp_file" ;;
          *) fail "$filter_file:$line_number: application mode must be proxy or direct" ;;
        esac
        ;;
      l7)
        require_name "$app_name"
        require_rule_id "$field"
        [[ -n $regex && -z $extra ]] ||
          fail "$filter_file:$line_number: l7 records require a non-empty regex as field four"
        [[ ${applications[$app_name]+present} ]] ||
          fail "$filter_file:$line_number: define application '$app_name' before its rules"
        rule_key="$app_name:$field"
        [[ ! ${rules[$rule_key]+present} ]] ||
          fail "$filter_file:$line_number: duplicate rule '$field' for '$app_name'"
        rules[$rule_key]=1
        printf 'upf application %s rule %s add l7 regex %s\n' \
          "$app_name" "$field" "$regex" >>"$tmp_file"
        ;;
      *)
        fail "$filter_file:$line_number: record type must be app or l7"
        ;;
    esac
  done <"$filter_file"
done

if [[ $MODE == generate ]]; then
  install -D -m 0644 "$tmp_file" "$OUTPUT_FILE"
  echo "Generated $OUTPUT_FILE from ${#filter_files[@]} filter set(s)."
  exit 0
fi

[[ -S $VPP_SOCK ]] || fail "VPP CLI socket '$VPP_SOCK' does not exist"
while IFS= read -r command; do
  echo "Applying: $command"
  vppctl -s "$VPP_SOCK" "$command"
done <"$tmp_file"

echo "Applied ${#filter_files[@]} App ID filter set(s) through $VPP_SOCK."
