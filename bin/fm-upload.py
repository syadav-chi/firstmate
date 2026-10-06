#!/usr/bin/env python3
# fm-upload.py - the receive engine behind bin/fm-upload.sh.
#
#   fm-upload.py receive <staging-dir> <dest-dir> <result-file | ->
#
# Scans one captured Lavish result for upload part lines written by the
# upload page (.agents/skills/upload/assets/upload-template.html):
#
#   FMUPLOAD1 batch=.. file=.. index=.. count=.. part=.. parts=.. bytes=.. sha256=.. psha=.. ::<base64>::END
#
# Values are percent-encoded. The scan matches the marker anywhere in the
# input, so it does not depend on how the poll output quotes the prompt text.
# Each part is verified against its own psha and staged under
# <staging-dir>/<batch>/<index>/<part>, so parts can arrive across several
# captured results. A file whose parts are all staged is reassembled, checked
# against its whole-file sha256 and byte count, and written into <dest-dir>
# without overwriting: an existing name gets a -1, -2, ... suffix, while an
# identical existing file is reported as already saved. Its staged parts are
# then removed.
#
# Output is one line per file seen in this result, then one line per batch
# file still incomplete:
#   saved: <path> bytes=<n> sha256=<hex>
#   already-saved: <path> sha256=<hex>
#   waiting: batch=<b> file=<name> have=<k>/<n> missing=<part list>
#   rejected: batch=<b> file=<name> part=<p> reason=<why>
#   truncated: <n> part(s) cut off before their end marker
# A truncated part is one the capture bound cut short (several sends merged
# into one poll result); it is ignored, so its file stays waiting for a resend.
# The final line is a summary:
# `parts=<n> saved=<n> waiting=<n> rejected=<n> truncated=<n>`.
# Exit 0 when at least one part was found and nothing was rejected, 1 when a
# part or file was rejected, and 3 when the input carries no upload part.
import base64
import binascii
import hashlib
import os
import re
import sys
import urllib.parse

LINE = re.compile(r'FMUPLOAD1 ((?:[a-z0-9]+=[^\s:]*\s?)+)::([A-Za-z0-9+/=]*)::END')
REQUIRED = ('batch', 'file', 'index', 'count', 'part', 'parts', 'bytes', 'sha256', 'psha')
SAFE_ID = re.compile(r'^[A-Za-z0-9_-]{1,64}$')
HEX64 = re.compile(r'^[0-9a-f]{64}$')


def safe_name(name):
    name = name.replace('\\', '/').split('/')[-1]
    name = ''.join(ch for ch in name if ch.isprintable()).strip().lstrip('.')
    return name[:200] or 'upload.bin'


def unique_path(dest, name, digest):
    stem, ext = os.path.splitext(name)
    n = 0
    while True:
        cand = os.path.join(dest, name if n == 0 else f'{stem}-{n}{ext}')
        if not os.path.exists(cand):
            return cand, False
        with open(cand, 'rb') as fh:
            if hashlib.sha256(fh.read()).hexdigest() == digest:
                return cand, True
        n += 1


def write_atomic(path, data):
    tmp = f'{path}.part-{os.getpid()}'
    with open(tmp, 'wb') as fh:
        fh.write(data)
    os.replace(tmp, path)


def receive(staging, dest, text):
    out, rejected, found, files = [], 0, 0, {}
    for m in LINE.finditer(text):
        found += 1
        fields = dict(kv.split('=', 1) for kv in m.group(1).split())
        fields = {k: urllib.parse.unquote(v) for k, v in fields.items()}
        label = f"batch={fields.get('batch', '?')} file={fields.get('file', '?')} part={fields.get('part', '?')}"
        if any(k not in fields for k in REQUIRED) or not SAFE_ID.match(fields['batch']) \
                or not HEX64.match(fields['sha256']) or not HEX64.match(fields['psha']) \
                or not all(fields[k].isdigit() and fields[k].isascii()
                           for k in ('index', 'count', 'part', 'parts', 'bytes')):
            out.append(f'rejected: {label} reason=malformed-header')
            rejected += 1
            continue
        part, parts = int(fields['part']), int(fields['parts'])
        if not 1 <= part <= parts:
            out.append(f'rejected: {label} reason=part-out-of-range')
            rejected += 1
            continue
        try:
            chunk = base64.b64decode(m.group(2), validate=True)
        except binascii.Error:
            out.append(f'rejected: {label} reason=bad-base64')
            rejected += 1
            continue
        if hashlib.sha256(chunk).hexdigest() != fields['psha']:
            out.append(f'rejected: {label} reason=part-fingerprint-mismatch')
            rejected += 1
            continue
        fdir = os.path.join(staging, fields['batch'], fields['index'])
        os.makedirs(fdir, mode=0o700, exist_ok=True)
        write_atomic(os.path.join(fdir, str(part)), chunk)
        meta = {k: fields[k] for k in ('file', 'parts', 'bytes', 'sha256')}
        write_atomic(os.path.join(fdir, 'meta'), '\n'.join(f'{k}={urllib.parse.quote(v)}' for k, v in meta.items()).encode())
        files[fdir] = (fields['batch'], meta)

    saved = waiting = 0
    for fdir, (batch, meta) in files.items():
        parts = int(meta['parts'])
        have = [p for p in range(1, parts + 1) if os.path.exists(os.path.join(fdir, str(p)))]
        if len(have) < parts:
            missing = ','.join(str(p) for p in range(1, parts + 1) if p not in have)
            out.append(f"waiting: batch={batch} file={meta['file']} have={len(have)}/{parts} missing={missing}")
            waiting += 1
            continue
        data = b''.join(open(os.path.join(fdir, str(p)), 'rb').read() for p in range(1, parts + 1))
        digest = hashlib.sha256(data).hexdigest()
        if digest != meta['sha256'] or len(data) != int(meta['bytes']):
            out.append(f"rejected: batch={batch} file={meta['file']} part=all reason=file-fingerprint-mismatch")
            rejected += 1
            continue
        os.makedirs(dest, exist_ok=True)
        path, existed = unique_path(dest, safe_name(meta['file']), digest)
        if existed:
            out.append(f'already-saved: {path} sha256={digest}')
        else:
            write_atomic(path, data)
            out.append(f'saved: {path} bytes={len(data)} sha256={digest}')
        saved += 1
        for name in os.listdir(fdir):
            os.remove(os.path.join(fdir, name))
        os.rmdir(fdir)
        try:
            os.rmdir(os.path.dirname(fdir))
        except OSError:
            pass
    truncated = max(0, text.count('FMUPLOAD1 batch=') - found)
    if truncated:
        out.append(f'truncated: {truncated} part(s) cut off before their end marker')
    out.append(f'parts={found} saved={saved} waiting={waiting} rejected={rejected} truncated={truncated}')
    print('\n'.join(out))
    if not found:
        return 1 if truncated else 3
    return 1 if rejected else 0


def main(argv):
    if len(argv) != 5 or argv[1] != 'receive':
        sys.stderr.write('usage: fm-upload.py receive <staging-dir> <dest-dir> <result-file | ->\n')
        return 2
    src = argv[4]
    text = sys.stdin.read() if src == '-' else open(src, encoding='utf-8', errors='replace').read()
    return receive(argv[2], argv[3], text)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
