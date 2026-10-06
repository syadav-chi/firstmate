#!/usr/bin/env bash
# Behavior tests for bin/fm-upload.sh receive: multi-part reassembly across
# captured results, fingerprint rejection, no-overwrite landing, file-name
# confinement, and the no-upload exit, all through the public command.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPLOAD="$ROOT/bin/fm-upload.sh"
TMP_ROOT=$(fm_test_tmproot fm-upload)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# Emit upload part lines in the page's wire format for <file> named <name>,
# split into <parts> parts, wrapped in poll-output-like quoting.
# Extra args: corrupt (flip one byte of part 1's payload after hashing).
make_parts() {  # <file> <name> <parts> <batch> [corrupt]
  python3 -I - "$@" <<'PY'
import base64, hashlib, sys, urllib.parse
path, name, parts, batch = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
corrupt = len(sys.argv) > 5
data = open(path, 'rb').read()
size = -(-len(data) // parts)
whole = hashlib.sha256(data).hexdigest()
for p in range(parts):
    chunk = data[p * size:(p + 1) * size]
    fields = dict(batch=batch, file=name, index=1, count=1, part=p + 1, parts=parts,
                  bytes=len(data), sha256=whole, psha=hashlib.sha256(chunk).hexdigest())
    if corrupt and p == 0:
        chunk = bytes([chunk[0] ^ 1]) + chunk[1:]
    head = ' '.join(f'{k}={urllib.parse.quote(str(v), safe="")}' for k, v in fields.items())
    print(f'  "{p + 1}","File upload batch {batch}.\\nFMUPLOAD1 {head} ::{base64.b64encode(chunk).decode()}::END",,file-upload,x')
PY
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

test_path_is_home_scoped() {
  local home out
  home=$(new_home path)
  out=$(FM_HOME="$home" "$UPLOAD" path)
  assert_equals "$home/.lavish/upload.html" "$out" "path is the stable page path in this home"
  pass "path is home-scoped"
}

test_parts_across_results_reassemble_byte_for_byte() {
  local home src out rc=0
  home=$(new_home multi)
  src="$TMP_ROOT/blob.bin"
  head -c 5000 /dev/urandom > "$src"
  make_parts "$src" "notes final.ipynb" 3 b1 > "$TMP_ROOT/all"
  head -n 2 "$TMP_ROOT/all" > "$TMP_ROOT/r1"
  tail -n 1 "$TMP_ROOT/all" > "$TMP_ROOT/r2"

  out=$(FM_HOME="$home" "$UPLOAD" receive "$TMP_ROOT/r1") || rc=$?
  expect_code 0 "$rc" "first result"
  assert_contains "$out" "waiting: batch=b1 file=notes final.ipynb have=2/3 missing=3" "first result reports the missing part"
  assert_absent "$home/data/uploads/notes final.ipynb" "an incomplete file is not landed"

  out=$(FM_HOME="$home" "$UPLOAD" receive "$TMP_ROOT/r2") || rc=$?
  expect_code 0 "$rc" "second result"
  assert_contains "$out" "saved: $home/data/uploads/notes final.ipynb bytes=5000" "second result lands the file"
  cmp -s "$src" "$home/data/uploads/notes final.ipynb" || fail "landed file differs from the source"
  assert_absent "$home/state/uploads/b1" "staged parts are removed after landing"
  pass "parts across captured results reassemble byte for byte"
}

test_corrupt_part_is_rejected_and_not_landed() {
  local home src out rc=0
  home=$(new_home corrupt)
  src="$TMP_ROOT/small.txt"
  printf 'hello upload\n' > "$src"
  out=$(make_parts "$src" small.txt 1 b2 corrupt | FM_HOME="$home" "$UPLOAD" receive -) || rc=$?
  expect_code 1 "$rc" "corrupt part"
  assert_contains "$out" "rejected: batch=b2 file=small.txt part=1 reason=part-fingerprint-mismatch" "corrupt part is named"
  assert_absent "$home/data/uploads/small.txt" "a corrupt file is not landed"
  pass "a corrupt part is rejected and nothing is landed"
}

test_never_overwrites_and_recognizes_duplicates() {
  local home dest src out
  home=$(new_home overwrite)
  dest="$TMP_ROOT/dest"
  mkdir -p "$dest"
  printf 'captain original\n' > "$dest/hw.ipynb"
  src="$TMP_ROOT/new.ipynb"
  printf 'new upload\n' > "$src"
  out=$(make_parts "$src" hw.ipynb 1 b3 | FM_HOME="$home" "$UPLOAD" receive - --dest "$dest")
  assert_contains "$out" "saved: $dest/hw-1.ipynb" "a clashing name gets a suffix"
  assert_grep "captain original" "$dest/hw.ipynb" "the existing file is untouched"
  out=$(make_parts "$src" hw.ipynb 1 b4 | FM_HOME="$home" "$UPLOAD" receive - --dest "$dest")
  assert_contains "$out" "already-saved: $dest/hw-1.ipynb" "an identical resend is recognized"
  assert_absent "$dest/hw-2.ipynb" "an identical resend lands no second copy"
  pass "receive never overwrites and recognizes an identical resend"
}

test_file_names_cannot_escape_the_destination() {
  local home src out
  home=$(new_home escape)
  src="$TMP_ROOT/esc.txt"
  printf 'x\n' > "$src"
  out=$(make_parts "$src" "../../etc/.evil" 1 b5 | FM_HOME="$home" "$UPLOAD" receive -)
  assert_contains "$out" "saved: $home/data/uploads/evil" "path components and leading dots are stripped"
  assert_absent "$TMP_ROOT/etc" "nothing lands outside the destination"
  pass "uploaded file names cannot escape the destination"
}

test_cut_off_part_is_reported_and_ignored() {
  local home src out rc=0
  home=$(new_home cut)
  src="$TMP_ROOT/cut.bin"
  head -c 3000 /dev/urandom > "$src"
  make_parts "$src" cut.bin 2 b6 > "$TMP_ROOT/cut-all"
  { head -n 1 "$TMP_ROOT/cut-all"; tail -n 1 "$TMP_ROOT/cut-all" | head -c 300; } > "$TMP_ROOT/cut-r1"
  out=$(FM_HOME="$home" "$UPLOAD" receive "$TMP_ROOT/cut-r1") || rc=$?
  expect_code 0 "$rc" "result with one whole part and one cut-off part"
  assert_contains "$out" "truncated: 1 part(s) cut off before their end marker" "the cut-off part is reported"
  assert_contains "$out" "waiting: batch=b6 file=cut.bin have=1/2 missing=2" "its file stays waiting for a resend"
  pass "a part cut off by the capture bound is reported and ignored"
}

test_result_without_upload_exits_3() {
  local home rc=0
  home=$(new_home none)
  printf 'session:\n  status: feedback\n' | FM_HOME="$home" "$UPLOAD" receive - >/dev/null || rc=$?
  expect_code 3 "$rc" "result without upload parts"
  pass "a result without upload parts exits 3"
}

test_path_is_home_scoped
test_parts_across_results_reassemble_byte_for_byte
test_corrupt_part_is_rejected_and_not_landed
test_never_overwrites_and_recognizes_duplicates
test_file_names_cannot_escape_the_destination
test_cut_off_part_is_reported_and_ignored
test_result_without_upload_exits_3
