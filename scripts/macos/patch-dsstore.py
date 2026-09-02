#!/usr/bin/env python3
"""
patch-dsstore.py — read and repair the Finder window blob inside a .DS_Store.

WHY THIS EXISTS
    Finder's AppleScript dictionary can turn the toolbar, sidebar and status
    bar off, but it has NO property for the tab bar. A Finder window that
    inherits `ShowTabView = True` draws ~40pt of tab-bar chrome on top of the
    28pt title bar — 68pt in all — that the DMG's window bounds never budgeted
    for, which silently clips the bottom of the background image. The only fix
    is to edit the persisted window state.

FILE LAYOUT
    The window state lives in a .DS_Store record introduced by the literal
    bytes `bwspblob` (structure id `bwsp` + type `blob`), followed by a
    big-endian uint32 length and that many bytes of binary plist.

WHY A BYTE FLIP AND NOT A RE-SERIALIZE
    .DS_Store is a B-tree with absolute offsets, so the replacement blob must
    be byte-for-byte the same length. Re-serializing with plistlib does NOT
    qualify: Finder's own writer leaves unreferenced slack objects in the
    table (13 objects where plistlib emits 10), so a round-trip shrinks the
    blob by several bytes and would corrupt the file.

    In a binary plist `false` is the single byte 0x08 and `true` is 0x09, so
    flipping that one byte in place is exactly the same size and leaves every
    offset, the offset table and the trailer untouched. That is what this
    script does, and it re-reads the file afterwards to prove it.

    patch-dsstore.py show   <.DS_Store>
    patch-dsstore.py patch  <.DS_Store>
    patch-dsstore.py verify <.DS_Store> --frame WxH
"""

import argparse
import plistlib
import struct
import sys

MARKER = b"bwspblob"
BPLIST_FALSE = 0x08
BPLIST_TRUE = 0x09


def die(msg):
    sys.stderr.write("patch-dsstore: ERROR: %s\n" % msg)
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# .DS_Store record
# ---------------------------------------------------------------------------

def read_blob(path):
    """Return (whole file bytes, offset of the plist, its length, parsed plist)."""
    with open(path, "rb") as fh:
        data = fh.read()
    i = data.find(MARKER)
    if i < 0:
        die("no 'bwspblob' record in %s — the Finder window state did not persist" % path)
    start = i + len(MARKER)
    (length,) = struct.unpack_from(">I", data, start)
    start += 4
    blob = data[start:start + length]
    if len(blob) != length:
        die("bwspblob claims %d bytes but only %d are present" % (length, len(blob)))
    try:
        plist = plistlib.loads(blob)
    except Exception as exc:  # noqa: BLE001 — surface whatever plistlib says
        die("bwspblob is not a readable binary plist: %s" % exc)
    return data, start, length, plist


# ---------------------------------------------------------------------------
# Minimal binary-plist walker — just enough to locate one top-level value byte
# ---------------------------------------------------------------------------

def _object_offsets(blob):
    """Parse the trailer and return the object offset table."""
    if len(blob) < 40 or not blob.startswith(b"bplist00"):
        die("bwspblob is not a bplist00 binary plist")
    _, off_size, ref_size, count, top, table_off = struct.unpack(">5xBBBQQQ", blob[-32:])
    if off_size not in (1, 2, 4, 8) or ref_size not in (1, 2, 4, 8):
        die("unsupported bplist trailer (offset size %d, ref size %d)" % (off_size, ref_size))
    offsets = []
    for n in range(count):
        raw = blob[table_off + n * off_size: table_off + (n + 1) * off_size]
        offsets.append(int.from_bytes(raw, "big"))
    return offsets, ref_size, top


def _marker_count(blob, pos):
    """Read a marker byte's low-nibble count, following the 0xF escape.

    Returns (count, position just past the count).
    """
    count = blob[pos] & 0x0F
    pos += 1
    if count == 0x0F:
        int_marker = blob[pos]
        if int_marker & 0xF0 != 0x10:
            die("malformed bplist: expected an int length marker at offset %d" % pos)
        width = 1 << (int_marker & 0x0F)
        pos += 1
        count = int.from_bytes(blob[pos:pos + width], "big")
        pos += width
    return count, pos


def _read_string(blob, offset):
    marker = blob[offset] & 0xF0
    count, pos = _marker_count(blob, offset)
    if marker == 0x50:                      # ASCII
        return blob[pos:pos + count].decode("ascii", "replace")
    if marker == 0x60:                      # UTF-16BE, count is in code units
        return blob[pos:pos + count * 2].decode("utf-16-be", "replace")
    return None


def find_bool_value_offset(blob, key):
    """Byte offset of the value of top-level dict `key`, or None."""
    offsets, ref_size, top = _object_offsets(blob)
    root = offsets[top]
    if blob[root] & 0xF0 != 0xD0:
        die("bwspblob's root object is not a dictionary")
    count, pos = _marker_count(blob, root)
    keys = blob[pos: pos + count * ref_size]
    values = blob[pos + count * ref_size: pos + 2 * count * ref_size]
    for n in range(count):
        key_ref = int.from_bytes(keys[n * ref_size:(n + 1) * ref_size], "big")
        if _read_string(blob, offsets[key_ref]) != key:
            continue
        value_ref = int.from_bytes(values[n * ref_size:(n + 1) * ref_size], "big")
        return offsets[value_ref]
    return None


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

INTERESTING = (
    "WindowBounds",
    "ShowToolbar",
    "ShowSidebar",
    "ContainerShowSidebar",
    "ShowStatusBar",
    "ShowTabView",
    "ShowPathbar",
)


def describe(plist):
    for key in INTERESTING:
        if key in plist:
            print("    %-21s = %s" % (key, plist[key]))


def frame_size(plist):
    """Parse WindowBounds '{{x, y}, {w, h}}' into (w, h)."""
    bounds = plist.get("WindowBounds")
    if not isinstance(bounds, str):
        die("WindowBounds is missing or not a string: %r" % (bounds,))
    nums = bounds.replace("{", " ").replace("}", " ").replace(",", " ").split()
    if len(nums) != 4:
        die("cannot parse WindowBounds: %s" % bounds)
    return int(nums[2]), int(nums[3])


def cmd_show(path):
    _, _, _, plist = read_blob(path)
    describe(plist)
    return 0


def cmd_patch(path):
    data, start, length, plist = read_blob(path)
    print("    before:")
    describe(plist)

    if plist.get("ShowTabView") is False:
        print("    ShowTabView is already False — no change needed")
        return 0
    if "ShowTabView" not in plist:
        die("bwspblob has no ShowTabView key — cannot force the tab bar off")

    blob = data[start:start + length]
    value_offset = find_bool_value_offset(blob, "ShowTabView")
    if value_offset is None:
        die("could not locate the ShowTabView value in the bplist object table")
    if blob[value_offset] != BPLIST_TRUE:
        die("ShowTabView object at bplist offset %d is 0x%02x, expected 0x%02x (true)"
            % (value_offset, blob[value_offset], BPLIST_TRUE))

    with open(path, "r+b") as fh:
        fh.seek(start + value_offset)
        fh.write(bytes([BPLIST_FALSE]))
        fh.flush()

    # Re-read from disk; do not trust the in-memory object.
    data_after, _, length_after, plist_after = read_blob(path)
    if length_after != length:
        die("blob length changed from %d to %d — the .DS_Store B-tree is now corrupt"
            % (length, length_after))
    if len(data_after) != len(data):
        die("file size changed from %d to %d bytes" % (len(data), len(data_after)))
    if plist_after.get("ShowTabView") is not False:
        die("wrote the patch but ShowTabView re-reads as %r" % (plist_after.get("ShowTabView"),))

    print("    after:  ShowTabView -> False (flipped 1 byte at blob offset %d; "
          "blob still %d bytes)" % (value_offset, length))
    return 0


def cmd_verify(path, frame):
    want_w, want_h = (int(n) for n in frame.lower().split("x"))
    _, _, _, plist = read_blob(path)
    describe(plist)

    failures = []
    for key in ("ShowToolbar", "ShowSidebar", "ShowTabView"):
        if plist.get(key) is not False:
            failures.append("%s is %r, expected False" % (key, plist.get(key)))

    got = frame_size(plist)
    if got != (want_w, want_h):
        failures.append("WindowBounds frame is %dx%d, expected %dx%d"
                        % (got[0], got[1], want_w, want_h))

    for f in failures:
        sys.stderr.write("patch-dsstore: ERROR: %s\n" % f)
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description="Inspect or repair a .DS_Store Finder window blob.")
    ap.add_argument("command", choices=("show", "patch", "verify"))
    ap.add_argument("path")
    ap.add_argument("--frame", help="expected window frame as WxH (verify only)")
    args = ap.parse_args()

    if args.command == "show":
        return cmd_show(args.path)
    if args.command == "patch":
        return cmd_patch(args.path)
    if not args.frame:
        ap.error("verify requires --frame WxH")
    return cmd_verify(args.path, args.frame)


if __name__ == "__main__":
    sys.exit(main())
