#!/usr/bin/env bash
# fm-upload.sh - receive files from the captain through a Lavish upload page.
#
# The captain often works from a phone or over ssh, where handing firstmate a
# file is otherwise awkward. The upload page (the shipped template at
# .agents/skills/upload/assets/upload-template.html) reads files in the
# browser and sends them through ordinary Lavish prompts, split into
# fingerprinted parts small enough that several sends merged into one captured
# poll result still fit the process-event output bound.
#
# Usage:
#   fm-upload.sh open [--purpose <text>]
#   fm-upload.sh receive <result-file | -> [--dest <dir>]
#   fm-upload.sh path
#
# open     Build the page at the stable path, injecting --purpose as the line
#          shown under its heading, establish its Lavish session (reopening
#          one the captain ended, since the captain asked for this page), and
#          arm its listener with bin/fm-procevent-lavish.sh. Prints lavish-axi's
#          session output, which carries the URL to give the captain, then the
#          adapter's arm result.
# receive  Run bin/fm-upload.py on one captured result. Verified files land in
#          --dest (default $FM_HOME/data/uploads), never overwriting; parts of
#          a file still in flight are staged under $FM_HOME/state/uploads until
#          the rest arrive. fm-upload.py's header owns the output lines and
#          exit codes (0 ok, 1 something rejected, 3 no upload in the result).
# path     Print the stable page path for this home.
#
# The page is plain HTML served by Lavish over the plain-http tailnet address,
# so it computes SHA-256 in JavaScript (crypto.subtle needs a secure context)
# and leaves the file input unfiltered (some pickers grey out unknown
# extensions such as .ipynb).
#
# FM_UPLOAD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
TEMPLATE="${FM_UPLOAD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/upload/assets/upload-template.html}"
PLACEHOLDER='"__FM_UPLOAD_PURPOSE__"'

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-upload: %s\n' "$*" >&2
  exit 1
}

page_path() { printf '%s/.lavish/upload.html\n' "$FM_HOME"; }

build_page() {  # <purpose>
  local page tmp
  page=$(page_path)
  [ -f "$TEMPLATE" ] || fail "upload template is missing: $TEMPLATE"
  [ "$(grep -cF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] || fail "upload template does not carry exactly one purpose slot: $TEMPLATE"
  (umask 077; mkdir -p "${page%/*}") || fail "cannot create ${page%/*}"
  tmp=$(umask 077; mktemp "${page%/*}/.upload.XXXXXX") || fail "cannot stage the page"
  # JSON-encode the purpose and make "<" inert so it can never close the script block.
  if ! FM_UPLOAD_PURPOSE="$1" python3 -I -c '
import json, os, sys
purpose = json.dumps(os.environ["FM_UPLOAD_PURPOSE"]).replace("<", "\\u003c")
src = open(sys.argv[1], encoding="utf-8").read()
sys.stdout.write(src.replace(sys.argv[2], purpose, 1))
' "$TEMPLATE" "$PLACEHOLDER" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot build the upload page"
  fi
  mv -f -- "$tmp" "$page"
  printf '%s\n' "$page"
}

command_open() {
  local purpose='' page out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purpose) [ "$#" -ge 2 ] || fail "--purpose needs a value"; purpose=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  page=$(build_page "$purpose")
  out=$(lavish-axi "$page") || fail "cannot open the upload page in Lavish"
  if printf '%s\n' "$out" | grep -q '^[[:space:]]*status:[[:space:]]*"\{0,1\}user-ended'; then
    out=$(lavish-axi "$page" --reopen) || fail "cannot reopen the upload page in Lavish"
  fi
  printf '%s\n' "$out" | sed '/^next_step:/,$d'
  "$SCRIPT_DIR/fm-procevent-lavish.sh" arm "$page"
}

command_receive() {
  local src='' dest="$FM_HOME/data/uploads"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dest) [ "$#" -ge 2 ] || fail "--dest needs a value"; dest=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -) [ -z "$src" ] || { usage >&2; exit 2; }; src=-; shift ;;
      -*) usage >&2; exit 2 ;;
      *) [ -z "$src" ] || { usage >&2; exit 2; }; src=$1; shift ;;
    esac
  done
  [ -n "$src" ] || { usage >&2; exit 2; }
  [ "$src" = - ] || [ -r "$src" ] || fail "cannot read result: $src"
  (umask 077; mkdir -p "$FM_HOME/state/uploads") || fail "cannot create the staging directory"
  python3 -I "$SCRIPT_DIR/fm-upload.py" receive "$FM_HOME/state/uploads" "$dest" "$src"
}

case "${1-}" in
  open) shift; command_open "$@" ;;
  receive) shift; command_receive "$@" ;;
  path) page_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
