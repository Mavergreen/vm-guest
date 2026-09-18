#!/usr/bin/env python3
"""Build (and inspect) a macOS flat installer package on Linux.

WHY THIS EXISTS

The first-boot payload belongs in OSInstall.collection, so the installer
installs it as part of the install -- the same thing
timsutton/osx-vm-templates does with create_firstboot_pkg.  Upstream can
call Apple's `pkgbuild`, because upstream runs on a Mac.  We do not, and
this host has neither `xar` nor `mkbom` (and the project rule is to
install nothing).  So the container is written here, from the format,
against a real Apple-signed package as the reference:
`QemuUSBTablet-1.2.pkg`, which `7z` reads and which told us exactly what
the TOC has to look like.

WHAT IT BUILDS: A PAYLOAD-FREE PACKAGE

A flat package is a xar archive.  A *component* package holds

    PackageInfo   XML describing the package
    Bom           a bill of materials, binary, normally made by mkbom
    Payload       gzip-compressed cpio of the files to install
    Scripts       gzip-compressed cpio of preinstall/postinstall/...

We build the payload-free kind: PackageInfo and Scripts only.  That is
what `pkgbuild --nopayload` produces, and it is the variant that needs no
Bom -- which matters a great deal here, because `mkbom` is the one piece
of this whose format we would otherwise have to reimplement blind, with a
16-minute VM boot as the only way to find out whether we got it right.

Everything the payload does is therefore done by the postinstall script,
which the installer runs with the target volume as $3.  That is not a
workaround: the things this payload has to do (create an account, enable
Remote Login, disable sleep) cannot be done by copying files anyway --
they need a booted system, which is why the postinstall script's job is
to leave a LaunchDaemon behind rather than to do the work itself.

DETERMINISM

Byte-identical output for identical inputs, because the build manifest
records this package's checksum and a checksum that changes on its own
says nothing.  So: fixed mtimes (0), fixed uid/gid, entries sorted by
name, gzip with mtime=0, and no creation-time that is actually the clock.
`tests/payload.bats` builds twice and compares.

THE FORMAT, as observed in the reference package

  header   'xar!' | u16 size=28 | u16 version=1 | u64 toc_len_compressed
           | u64 toc_len_uncompressed | u32 cksum_alg (1 = sha1)
  then     the TOC, zlib-compressed
  then     the heap: the TOC's own SHA-1 at offset 0, then each file's
           bytes at the offset its <file> entry names.
"""

import argparse
import gzip
import hashlib
import io
import os
import struct
import sys
import zlib

XAR_MAGIC = b"xar!"
XAR_HEADER_SIZE = 28
XAR_VERSION = 1
XAR_CKSUM_SHA1 = 1

# Fixed epoch for every timestamp we write. See DETERMINISM above.
EPOCH = "1970-01-01T00:00:00Z"


# --------------------------------------------------------------------------
# cpio, "odc" (POSIX.1 ASCII, magic 070707)
#
# This is the format the reference package's Scripts member uses -- checked,
# not assumed: `zcat Scripts | head -c 16` starts "070707".  Written here
# rather than shelled out to cpio(1) so that the output is ours to make
# deterministic, and so the build needs one fewer command present.
# --------------------------------------------------------------------------

# File-type bits. NOT optional, and leaving them out is the single mistake
# that cost this a full 20-minute install:
#
#   PackageKit: Got copier error 21 ... cpio read error: bad file format
#
# The xar container was read fine, PackageInfo was parsed, the package
# identifier was recognised -- and then BOM's cpio reader walked off the end
# of the first entry, because a mode of 000755 tells it the entry has no
# type and therefore, as far as it is concerned, no data to skip past.
# Apple's own packages have 040755 and 100755; ours had 000755. Read the
# reference's bytes rather than trusting the field list.
S_IFDIR = 0o040000
S_IFREG = 0o100000


def _odc_entry(name, mode, data, ino, is_dir=False):
    payload = b"" if is_dir else data
    nul_name = name.encode("utf-8") + b"\0"
    header = "070707"
    header += "%06o" % 0            # dev
    header += "%06o" % (ino & 0o777777)
    header += "%06o" % ((S_IFDIR if is_dir else S_IFREG) | (mode & 0o7777))
    header += "%06o" % 0            # uid  (root)
    header += "%06o" % 0            # gid  (wheel)
    header += "%06o" % 1            # nlink
    header += "%06o" % 0            # rdev
    header += "%011o" % 0           # mtime
    header += "%06o" % len(nul_name)
    header += "%011o" % len(payload)
    return header.encode("ascii") + nul_name + payload


def make_odc_cpio(entries):
    """entries: list of (name, mode, bytes-or-None-for-directory)."""
    out = io.BytesIO()
    ino = 1
    for name, mode, data in entries:
        out.write(_odc_entry(name, mode, data or b"", ino, data is None))
        ino += 1
    out.write(_odc_entry("TRAILER!!!", 0o644, b"", ino))
    return out.getvalue()


def gzip_deterministic(data):
    buf = io.BytesIO()
    # mtime=0: gzip stamps the clock into its header otherwise, and two
    # builds of the same input would differ in four bytes.
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(data)
    return buf.getvalue()


def read_odc_cpio(data):
    """Parse an odc cpio back into [(name, mode, bytes)]. Used by --list-scripts."""
    out = []
    pos = 0
    while pos + 76 <= len(data):
        if data[pos:pos + 6] != b"070707":
            raise ValueError("not an odc cpio header at offset %d" % pos)
        fields = data[pos + 6:pos + 76].decode("ascii")
        mode = int(fields[12:18], 8) & 0o7777
        namesize = int(fields[53:59], 8)
        filesize = int(fields[59:70], 8)
        pos += 76
        name = data[pos:pos + namesize - 1].decode("utf-8")
        pos += namesize
        body = data[pos:pos + filesize]
        pos += filesize
        if name == "TRAILER!!!":
            break
        out.append((name, mode, body))
    return out


# --------------------------------------------------------------------------
# xar
# --------------------------------------------------------------------------

def _xml_escape(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def build_xar(members):
    """members: list of (name, mode, bytes), stored uncompressed in the heap.

    Stored with encoding application/octet-stream -- i.e. raw -- which is
    exactly how the reference package stores its own Scripts member, and
    which keeps the archived and extracted checksums the same value.  The
    members here are already gzip-compressed or a few hundred bytes of XML,
    so a second compression pass would buy nothing and add a way to differ.
    """
    heap = io.BytesIO()
    # Offset 0 of the heap is the TOC's own checksum; everything else starts
    # after it. See the <checksum> element written below.
    cksum_len = hashlib.sha1().digest_size
    heap.write(b"\0" * cksum_len)

    entries = []
    for i, (name, mode, data) in enumerate(sorted(members), start=1):
        offset = heap.tell() - 0
        heap.write(data)
        digest = hashlib.sha1(data).hexdigest()
        entries.append(
            "  <file id=\"%d\">\n"
            "   <data>\n"
            "    <length>%d</length>\n"
            "    <offset>%d</offset>\n"
            "    <size>%d</size>\n"
            "    <encoding style=\"application/octet-stream\"/>\n"
            "    <extracted-checksum style=\"sha1\">%s</extracted-checksum>\n"
            "    <archived-checksum style=\"sha1\">%s</archived-checksum>\n"
            "   </data>\n"
            "   <ctime>%s</ctime>\n"
            "   <mtime>%s</mtime>\n"
            "   <atime>%s</atime>\n"
            "   <group>wheel</group>\n"
            "   <gid>0</gid>\n"
            "   <user>root</user>\n"
            "   <uid>0</uid>\n"
            "   <mode>%04o</mode>\n"
            "   <deviceno>0</deviceno>\n"
            "   <inode>%d</inode>\n"
            "   <type>file</type>\n"
            "   <name>%s</name>\n"
            "  </file>\n"
            % (i, len(data), offset, len(data), digest, digest,
               EPOCH, EPOCH, EPOCH, mode, i, _xml_escape(name))
        )

    toc = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<xar>\n"
        " <toc>\n"
        "  <creation-time>%s</creation-time>\n"
        "  <checksum style=\"sha1\">\n"
        "   <offset>0</offset>\n"
        "   <size>%d</size>\n"
        "  </checksum>\n"
        "%s"
        " </toc>\n"
        "</xar>\n" % (EPOCH.rstrip("Z"), cksum_len, "".join(entries))
    ).encode("utf-8")

    toc_compressed = zlib.compress(toc, 9)
    header = struct.pack(
        ">4sHHQQL", XAR_MAGIC, XAR_HEADER_SIZE, XAR_VERSION,
        len(toc_compressed), len(toc), XAR_CKSUM_SHA1)

    heap_bytes = bytearray(heap.getvalue())
    heap_bytes[0:cksum_len] = hashlib.sha1(toc_compressed).digest()
    return header + toc_compressed + bytes(heap_bytes)


def read_xar_member(path, want):
    """Return the raw bytes of one top-level member of a xar archive."""
    with open(path, "rb") as fh:
        blob = fh.read()
    magic, hsize, _ver, tlen_c, _tlen_u, _alg = struct.unpack(
        ">4sHHQQL", blob[:XAR_HEADER_SIZE])
    if magic != XAR_MAGIC:
        raise ValueError("%s is not a xar archive" % path)
    toc = zlib.decompress(blob[hsize:hsize + tlen_c]).decode("utf-8")
    heap = blob[hsize + tlen_c:]
    import re
    for m in re.finditer(r"<file id=\"\d+\">(.*?)</file>", toc, re.S):
        body = m.group(1)
        name = re.search(r"<name>(.*?)</name>", body, re.S)
        off = re.search(r"<offset>(\d+)</offset>", body)
        size = re.search(r"<size>(\d+)</size>", body)
        if name and off and size and name.group(1) == want:
            start = int(off.group(1))
            return heap[start:start + int(size.group(1))]
    raise KeyError("%s has no member named %s" % (path, want))


# --------------------------------------------------------------------------

PACKAGE_INFO = """<?xml version="1.0" encoding="utf-8" standalone="no"?>
<pkg-info format-version="2" identifier="{identifier}" version="{version}" \
install-location="/" auth="root">
    <payload installKBytes="0" numberOfFiles="0"/>
    <scripts>
        <postinstall file="./postinstall"/>
    </scripts>
</pkg-info>
"""


def build_package(scripts_dir, identifier, version, out_path):
    names = sorted(os.listdir(scripts_dir))
    entries = [(".", 0o755, None)]
    for name in names:
        full = os.path.join(scripts_dir, name)
        if not os.path.isfile(full):
            raise SystemExit("mkflatpkg: %s is not a regular file" % full)
        with open(full, "rb") as fh:
            data = fh.read()
        # Anything the installer must be able to run needs the x bit; the
        # rest is data the script reads. Mode comes from the file on disk,
        # so the builder decides, not this.
        mode = 0o755 if os.access(full, os.X_OK) else 0o644
        entries.append(("./" + name, mode, data))

    scripts = gzip_deterministic(make_odc_cpio(entries))
    pkginfo = PACKAGE_INFO.format(
        identifier=identifier, version=version).encode("utf-8")

    blob = build_xar([("PackageInfo", 0o644, pkginfo),
                      ("Scripts", 0o644, scripts)])
    tmp = out_path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(blob)
    os.replace(tmp, out_path)
    return len(blob)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--scripts", help="directory of scripts to package")
    ap.add_argument("--identifier", default="com.mqg.firstboot")
    ap.add_argument("--version", default="1.0")
    ap.add_argument("--out", help="package to write")
    ap.add_argument("--list-scripts", metavar="PKG",
                    help="list the Scripts members of an existing package")
    ap.add_argument("--cat-script", nargs=2, metavar=("PKG", "NAME"),
                    help="print one Scripts member of an existing package")
    args = ap.parse_args(argv)

    if args.list_scripts:
        scripts = gzip.decompress(read_xar_member(args.list_scripts, "Scripts"))
        for name, mode, data in read_odc_cpio(scripts):
            print("%04o %8d %s" % (mode, len(data), name))
        return 0

    if args.cat_script:
        pkg, want = args.cat_script
        scripts = gzip.decompress(read_xar_member(pkg, "Scripts"))
        for name, _mode, data in read_odc_cpio(scripts):
            if name == want:
                sys.stdout.write(data.decode("utf-8"))
                return 0
        print("no such script: %s" % want, file=sys.stderr)
        return 1

    if not args.scripts or not args.out:
        ap.error("--scripts and --out are required unless inspecting")
    size = build_package(args.scripts, args.identifier, args.version, args.out)
    print("%s (%d bytes)" % (args.out, size))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
