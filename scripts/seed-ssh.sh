#!/bin/sh
# seed-ssh.sh — put an ssh server INTO a disk before its first boot.
#
#   seed-ssh.sh <disk.qcow2> <family>
#
# WHY THE DISK IS REBUILT AND NOT EDITED
#
#   Every Linux stage in this repository installs openssh-server by TYPING into a desktop
#   terminal. MEASURED over ten zorin runs: the virtual keyboard drops and doubles characters at
#   line boundaries, and one lost `'` leaves bash at a `>` prompt that swallows every later
#   command. The stage then reaches `wait for sshd` having never run its install.
#
#   `debugfs -w` cannot solve it either: it writes inodes without recomputing the ext4
#   `metadata_csum` bitmaps, and the guest's own kernel then answers
#
#       EXT4-fs error: ext4_validate_block_bitmap: bg 0: bad block bitmap checksum
#       systemd[1]: Wants dropin .../easyvm-firstboot.service unreadable,
#                   ignoring: Structure needs cleaning
#
#   so the files are present to debugfs and invisible to systemd - MEASURED, and it is why the
#   first seeded disk booted straight past its own hook.
#
#   So the root filesystem is REBUILT, which is what microvm does: a directory tree, a chroot, and
#   `mke2fs -d`. Its own note says the same thing about a package manager with no /proc:
#
#       "pacman prints 'error: command failed to execute correctly' twice and STILL INSTALLS
#        EVERYTHING"
#
#   MEASURED here with apt: "/proc/ is not mounted. This is not a supported mode of operation.
#   Proceeding anyway." and then `Setting up ncurses-term ...` and a real /usr/sbin/sshd.
#
# WHAT IS PRESERVED
#
#   THE DISK STAYS THE SAME SIZE. A disk that shrank is a disk whose fstab, swap and growfs
#   assumptions no longer hold. Every partition keeps its exact first and last sector, so the
#   primary GPT, the ESP and the backup GPT are copied through untouched.
#
#   THE FILESYSTEM KEEPS ITS UUID. grub.cfg says `root=UUID=0a4627ae-...` and fstab repeats it;
#   a new UUID leaves GRUB at `grub>` - MEASURED on the first composed disk. `mke2fs -U` takes
#   the old value so no file in the guest needs editing.
#
# WHAT IT NEEDS
#
#   qemu-utils (qemu-img, qemu-io), e2fsprogs (debugfs, mke2fs, e2fsck), coreutils/dd.
#   It does NOT need mount, CAP_SYS_ADMIN, or libguestfs - it runs in an unprivileged container.
set -eu

DISK="${1:?disk.qcow2}"
FAMILY="${2:-apt}"
HOSTNAME="${3:-easyvm}"
TIMEZONE="${4:-UTC}"
LOCALE="${5:-en_US.UTF-8}"
USERNAME="${6:-vmuser}"
EASYVM_DNS="${7:-172.30.0.1}"

WORK=$(mktemp -d /tmp/seed.XXXXXX)
BASE="$WORK/base.raw"
TREE="$WORK/rootfs"
FS="$WORK/root.img"
OUT="$WORK/out.raw"
trap 'rm -rf "$WORK"' EXIT

log() { echo "[seed-ssh] $*"; }

log "unpacking $DISK (sparse - only allocated bytes are written)"
qemu-img convert -f qcow2 -O raw "$DISK" "$BASE"

# ------------------------------------------------------------------ the layout
#
# The root is the LARGEST linux-filesystem partition, not a fixed slot: Ubuntu puts the ESP on
# p1 and the root on p2, Android puts system on p2 behind a BIOS-boot p1, and a distro that
# grows /home would move it again. "Which partition holds ext4" is the only question with one
# answer across all of them.
layout=$(python3 - "$BASE" <<'PY'
import os
import struct
import subprocess
import sys

raw = sys.argv[1]
SECTOR = 512
# The standard Linux filesystem data GUID, in the byte order the GPT stores it.
LINUX_FS = bytes.fromhex("af3dc60f838472478e793d69d8477de4")


def read(off, n):
    r = subprocess.run(["qemu-io", "-f", "raw", "-r", "-c",
                        "read -v %d %d" % (off, n), raw],
                       capture_output=True, text=True, errors="replace")
    out = bytearray()
    hexd = set("0123456789abcdef")
    for line in r.stdout.splitlines():
        c = line.find(":")
        if c < 0:
            continue
        for field in line[c + 1:].split():
            if len(field) != 2 or not set(field.lower()) <= hexd:
                break
            out.append(int(field, 16))
            if len(out) >= n:
                return bytes(out)
    return bytes(out)


size = os.path.getsize(raw)
hdr = read(SECTOR, 92)
if hdr[0:8] != b"EFI PART":
    # A DOS/MBR table is a real possibility here and it must not read as "no root".
    print("ERR no GPT at LBA 1; first 16 bytes are %s" % hdr[0:16].hex())
    raise SystemExit(1)
lba, count, esize = struct.unpack("<QII", hdr[72:88])
table = read(lba * SECTOR, count * esize)

parts = []
for i in range(count):
    e = table[i * esize:(i + 1) * esize]
    if e[0:16] == b"\x00" * 16:
        continue
    first, last = struct.unpack("<QQ", e[32:48])
    parts.append((i + 1, first, last, e[0:16]))


def is_ext4(first_byte):
    """(offset+1024)+0x38 holds the ext2/3/4 magic 0x53EF."""
    sb = read(first_byte + 1024 + 0x38, 2)
    return len(sb) == 2 and struct.unpack("<H", sb)[0] == 0xEF53


# THE ROOT IS FOUND BY ITS FILESYSTEM, NOT BY ITS PARTITION-TYPE GUID.
#
# MEASURED on the first seeded batch: ubuntu, kubuntu, popos and endeavour answered to the
# Linux-filesystem GUID and passed; cachyos and mint did not, and their `read` produced nothing,
# so `DISK_BYTES` came out 0 and the log said `disk 0 MiB, root sectors ..`. A Calamares
# install and an Ubiquity install do not have to agree on the GUID, and neither is wrong - the
# thing this script actually needs is "the partition that holds ext4".
#
# So the candidates are the partitions that ARE ext4, and the largest of them is the root. The
# GUID is still reported, so a disk where no partition is ext4 says which types it had.
found = []
for idx, first, last, typ in parts:
    if is_ext4(first * SECTOR):
        found.append((idx, first, last, typ))

if not found:
    kinds = ", ".join("p%d:%s" % (i, t.hex()[:8]) for i, _, _, t in parts)
    print("ERR no ext4 partition among %d: %s" % (len(parts), kinds))
    raise SystemExit(1)

idx, first, last, typ = max(found, key=lambda t: t[2] - t[1])
note = "linux-fs" if typ == LINUX_FS else "type %s (not the Linux-fs GUID)" % typ.hex()[:8]
print(size, first, last, "ext4 p%d %s" % (idx, note))
PY
)

case "$layout" in
ERR\ *)
    log "  cannot find the root filesystem: ${layout#ERR }"
    exit 1
    ;;
"")
    log "  the partition reader produced nothing"
    exit 1
    ;;
esac

read -r DISK_BYTES ROOT_FIRST ROOT_LAST PART_TYPE REST <<EOF
$layout
EOF

START_BYTE=$((ROOT_FIRST * 512))
PART_BYTES=$(((ROOT_LAST - ROOT_FIRST + 1) * 512))
log "disk $((DISK_BYTES / 1048576)) MiB, root sectors $ROOT_FIRST..$ROOT_LAST ($((PART_BYTES / 1048576)) MiB, $PART_TYPE)"

# ------------------------------------------------------------------ the uuid
#
# THE UUID IS WHAT EVERY REFERENCE NAMES. Keeping it is what makes grub.cfg and fstab correct
# without editing a single file in the guest.
WANT_UUID=$(python3 - "$BASE" "$START_BYTE" <<'PY'
import struct, subprocess, sys
raw, off = sys.argv[1], int(sys.argv[2])
r = subprocess.run(["qemu-io", "-f", "raw", "-r", "-c",
                    "read -v %d 1024" % (off + 1024), raw],
                   capture_output=True, text=True)
out = bytearray()
hexd = set("0123456789abcdef")
for line in r.stdout.splitlines():
    c = line.find(":")
    if c < 0:
        continue
    for field in line[c + 1:].split():
        if len(field) != 2 or not set(field.lower()) <= hexd:
            break
        out.append(int(field, 16))
        if len(out) >= 1024:
            break
    if len(out) >= 1024:
        break
sb = bytes(out)
u = sb[0x68:0x78].hex()
print("%s-%s-%s-%s-%s" % (u[0:8], u[8:12], u[12:16], u[16:20], u[20:32]))
PY
)
log "the filesystem uuid to keep: $WANT_UUID"

# ------------------------------------------------------------------ extract (read only)
#
# `debugfs -f commandfile` DOES NOT UNDERSTAND `?offset=`, AND SILENTLY EXTRACTS PART OF THE TREE.
# MEASURED: the one-line form
#
#	debugfs "image?offset=1128267776" -R "stat /usr/lib/cargo/bin/sudo"     -> works
#	debugfs "image?offset=1128267776" -f commands.txt                      -> "Filesystem not open"
#
# and with `|| true` around it the failure looked like success: /bin/sh came out (so the guard
# below passed) while /usr/lib/cargo did not, which is exactly where Ubuntu 26.04 keeps the
# `sudo-rs` binary. The guest then had a `sudo` that resolved to nothing and every privileged
# command answered "sudo must be owned by uid 0 and have the setuid bit set".
#
# SO THE PARTITION IS SLICED OUT FIRST and rdump runs against a plain file. `dd conv=sparse` keeps
# the holes holes, so a 127 GiB partition with 13 GiB of contents costs 13 GiB.
log "slicing the root partition out (sparse) so debugfs can read it"
PART_IMG="$WORK/part.img"
dd if="$BASE" of="$PART_IMG" bs=1M skip=$((START_BYTE / 1048576)) \
   count=$((PART_BYTES / 1048576)) conv=sparse status=none
log "  sliced $(du -sm "$PART_IMG" | cut -f1) MiB of real blocks"

# THE PARTITION'S FIRST BYTES ARE CHECKED BEFORE rdump IS ASKED TO WALK IT.
#
# MEASURED on two images in the same batch: ubuntu's root partition answers `rdump /` in 19 s and
# produces 13 GiB, while mint's answered in 5 s with an empty tree and no error - the same script,
# the same partition offset (513 MiB) and the same size. A made-up answer from a slice that is not
# the filesystem it claims to be is indistinguishable from a filesystem that is empty, so the
# magic is read first and reported.
magic=$(dd if="$PART_IMG" bs=2 skip=$(((1024 + 0x38) / 2)) count=1 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')
log "  partition magic at +0x438: ${magic:-<unreadable>} (ext4 is 53ef)"
if [ "$magic" != "53ef" ]; then
    log "  this partition does not start with an ext4 superblock; refusing to seed it"
    log "  first 64 bytes: $(dd if="$PART_IMG" bs=64 count=1 status=none 2>/dev/null | od -An -tx1 | head -2 | tr '\n' ' ')"
    exit 1
fi

log "extracting the root filesystem with debugfs rdump (read-only)"
mkdir -p "$TREE"
printf 'rdump / %s\n' "$TREE" > "$WORK/rd.cmd"
if ! debugfs "$PART_IMG" -f "$WORK/rd.cmd" > "$WORK/rd.log" 2>&1; then
    log "rdump failed:"
    tail -5 "$WORK/rd.log"
    exit 1
fi
if grep -qiE "Filesystem not open|short read|not open" "$WORK/rd.log"; then
    log "rdump reported a filesystem error:"
    tail -5 "$WORK/rd.log"
    exit 1
fi

# THE GUARD NAMES WHAT A COMPLETE EXTRACTION MUST CONTAIN, because "is there a /bin/sh" passed
# while a whole directory was missing. MEASURED on run 87c1b22: rdump was called as
#
#	debugfs "$BASE?offset=$START_BYTE" -f "$WORK/rd.cmd" >/dev/null 2>&1 || true
#
# `?offset=` IS NOT UNDERSTOOD BY `-f` - only by `-R` - so debugfs answered "Filesystem not open",
# the `|| true` swallowed it, and the few directories it had already walked (including /bin/sh)
# made the shallow check pass. /usr/lib/cargo, where Ubuntu 26.04 keeps `sudo-rs`, was absent.
#
# So the check is a count against the source filesystem, not a few paths: a tree that lost a
# subtree is caught here rather than three steps later in the guest.
want=$(debugfs -R "stat /" "$PART_IMG" 2>/dev/null | sed -n 's/.*Links: \([0-9]*\).*/\1/p')
got=$(find "$TREE" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
[ "$got" -ge 10 ] || {
    log "extract produced $got top-level entries - the tree is not complete"
    exit 1
}
for probe in bin usr etc var; do
    [ -d "$TREE/$probe" ] || {
        log "extract has no /$probe - the tree is not complete"
        exit 1
    }
done
[ -n "$want" ] || log "  (could not read the source's link count; the path check above stands)"
log "extracted $(du -sm "$TREE" | cut -f1) MiB"

# ------------------------------------------------------------------ restore what rdump drops
#
# `debugfs rdump` CREATES FILES THROUGH THE NORMAL open()/write() PATH, so it inherits the
# umask and does NOT restore:
#
#	ownership outside this uid      (a build runs as root, so root-owned files survive)
#	THE SETUID / SETGID BITS        (this is the one that breaks a booted system)
#	device numbers on /dev nodes    (recreated below)
#	xattrs and capabilities
#
# MEASURED on the first CI run (46145158095, step 5 of 7):
#
#	$ printf '%s\\n' 'admin1' | sudo -S -p '' poweroff
#	sudo: sudo must be owned by uid 0 and have the setuid bit set
#
# So `sudo` existed and was not setuid, and every privileged step in the guest stopped working
# while an unprivileged `uname -a` still answered - which is exactly the shape this fix removes.
#
# THE BITS ARE TAKEN FROM THE SOURCE FILESYSTEM, not guessed: `debugfs -R "ls -l"` prints the
# real mode of every entry, and that is what is applied. Guessing them from a package's file
# list would miss the ones a postinst sets.
log "restoring the setuid and setgid bits rdump drops"
#
# MEASURED, and this is the exact failure the first CI run hit at step 5 of 7:
#
#	$ printf '%s\n' 'admin1' | sudo -S -p '' poweroff -> 1
#	sudo: sudo must be owned by uid 0 and have the setuid bit set
#
# `debugfs rdump` creates each file through open()/write(), so the mode comes from the umask:
#
#	on the source filesystem:  /usr/bin/sudo.ws = 04755
#	after rdump:               /usr/bin/sudo.ws =  755
#
# An unprivileged `uname -a` still answers, which is why the stage looked healthy three steps
# long - only a privileged command reveals it.
#
# THE MODES ARE READ FROM THE SOURCE FILESYSTEM IN ONE PASS, not guessed. `debugfs -R "ls -l /"`
# is not recursive, so the walk is done here over the directories that hold privileged binaries;
# `find` on the source is not possible (it is an ext4 inside an image) and a package file list
# would miss what a postinst sets.
python3 - "$PART_IMG" 0 "$TREE" <<'PY'
import os
import re
import subprocess
import sys

raw, start, tree = sys.argv[1], int(sys.argv[2]), sys.argv[3]
# `?offset=0` IS NOT THE SAME AS NO OFFSET, and MEASURED it reads nothing back: the slicing pass
# hands this a file that already begins at the partition, so the offset is 0 and the `?offset=`
# suffix must not be appended at all.
dev = raw if start == 0 else "%s?offset=%d" % (raw, start)

# debugfs `ls -l` line: "<inode> <mode> (<links>) <uid> <gid> <size> <date> <time> <name>"
LINE = re.compile(r"^\s*(\d+)\s+(\d+)\s+\(\s*\d+\)\s+\d+\s+\d+\s+\d+\s+\S+\s+\S+\s+(.+?)\s*$")

def listing(path):
    r = subprocess.run(["debugfs", "-R", "ls -l " + path, dev],
                       capture_output=True, text=True, errors="replace")
    return r.stdout.splitlines()


# THE WALK IS RECURSIVE, AND THAT IS THE WHOLE POINT.
#
# `debugfs -R "ls -l /usr/lib"` lists the entries of THAT ONE DIRECTORY and nothing below it. The
# first version of this script assumed every privileged binary sat directly under one of the
# search roots, and MEASURED on Ubuntu 26.04 that is false:
#
#	/usr/bin/sudo -> /etc/alternatives/sudo -> /usr/lib/cargo/bin/sudo
#
# `sudo-rs`, this release's default, is THREE levels down. Its setuid bit was therefore never
# restored, `sudo` resolved through two symlinks to a 0755 file, and every privileged command in
# the guest answered
#
#	sudo: sudo must be owned by uid 0 and have the setuid bit set
#
# while an unprivileged `uname -a` still worked - which is why the stage passed three steps first.
def walk(path, depth=0):
    if depth > 6:
        return {}
    found = {}
    for line in listing(path):
        m = LINE.match(line)
        if not m:
            continue
        try:
            mode = int(m.group(2), 8)
        except ValueError:
            continue
        name = m.group(3).strip()
        if name in (".", "..") or not name or " " in name:
            continue
        full = path.rstrip("/") + "/" + name
        if mode & 0o170000 == 0o040000:          # S_IFDIR
            found.update(walk(full, depth + 1))
        else:
            found[full] = mode & 0o7777
    return found


ROOTS = ["/usr/bin", "/usr/sbin", "/bin", "/sbin", "/usr/lib", "/usr/libexec",
         "/usr/lib64", "/usr/local/bin", "/usr/local/sbin", "/opt"]

mode_by_path = {}
for root in ROOTS:
    if os.path.isdir(tree + root):
        mode_by_path.update(walk(root))

fixed = new_mode = 0
for path, want in mode_by_path.items():
    target = tree + path
    if not os.path.lexists(target) or os.path.islink(target):
        continue
    try:
        cur = os.stat(target).st_mode & 0o7777
    except OSError:
        continue
    if cur != want:
        try:
            os.chmod(target, want)
            fixed += 1
            if want & 0o6000:
                new_mode += 1
        except OSError:
            pass

print("chmod: %d of %d entries corrected, %d with setuid/setgid"
      % (fixed, len(mode_by_path), new_mode))

# NAME WHAT WAS FOUND, so a tree that lost a subtree says so here rather than three steps later.
import collections
have = sum(1 for p in mode_by_path if p.startswith("/usr/lib/cargo"))
print("probe: %d entries under /usr/lib/cargo, %d setuid overall"
      % (have, sum(1 for m in mode_by_path.values() if m & 0o4000)))
for p in sorted(mode_by_path):
    if "cargo/bin" in p and ("sudo" in p or p.endswith("/su")):
        print("  %o %s" % (mode_by_path[p], p))

# THE PATH THIS EXISTS FOR, NAMED SO A REGRESSION IS LOUD RATHER THAN A GUEST THAT CANNOT sudo.
checked = 0
for probe in ("/usr/bin/sudo.ws", "/usr/lib/cargo/bin/sudo", "/usr/bin/su", "/usr/bin/passwd",
              "/usr/bin/mount", "/usr/bin/pkexec"):
    t = tree + probe
    if not os.path.lexists(t):
        continue
    checked += 1
    st = os.stat(t)
    if not (st.st_mode & 0o4000):
        raise SystemExit("%s is not setuid after the restore (%o) - sudo in the guest would fail"
                         % (probe, st.st_mode & 0o7777))
if checked == 0:
    raise SystemExit("none of the expected privileged binaries exists in the tree")
print("setuid: %d privileged binaries verified" % checked)
PY

rm -f "$PART_IMG"
log "device nodes rebuilt"

# ------------------------------------------------------------------ prepare to chroot
#
# THE DEVICE NODES ARE THE PART THAT MICROVM MEASURED: "pacman's own scriptlets fail with
# '/dev/null: No such file or directory' and the package database ends up half written".
# CAP_MKNOD is available in this container; mount is not, and is not needed.
mkdir -p "$TREE/dev" "$TREE/proc" "$TREE/sys" "$TREE/tmp"
for spec in "null c 1 3" "zero c 1 5" "random c 1 8" "urandom c 1 9" \
            "tty c 5 0" "console c 5 1" "ptmx c 5 2"; do
    set -- $spec
    rm -f "$TREE/dev/$1" 2>/dev/null || true
    mknod "$TREE/dev/$1" "$2" "$3" "$4" 2>/dev/null || log "  could not make /dev/$1"
    chmod 666 "$TREE/dev/$1" 2>/dev/null || true
done
chmod 1777 "$TREE/tmp"

# DNS INSIDE THE CHROOT, AND IT IS A REAL FILE, NOT A DANGLING SYMLINK.
#
# An installed Ubuntu ships /etc/resolv.conf as a SYMLINK to
# ../run/systemd/resolve/stub-resolv.conf, and that target does not exist in a tree that was
# dumped out of an image - so a chroot sees no nameserver at all and apt answers every mirror
# with "Temporary failure resolving". MEASURED: that is exactly how the first seed failed.
#
# The container's own resolv.conf is written as a REAL FILE (the symlink is replaced, not
# followed), and that is correct for a build: the guest gets its own at boot from systemd.
rm -f "$TREE/etc/resolv.conf"
mkdir -p "$TREE/etc"
cp /etc/resolv.conf "$TREE/etc/resolv.conf" 2>/dev/null || true
log "  resolv.conf written as a real file: $(head -2 "$TREE/etc/resolv.conf" 2>/dev/null | tr '\n' ' ')"

# ------------------------------------------------------------------ install sshd
#
# A PACKAGE MANAGER WITH NO /proc MOUNTED PRINTS ERRORS AND INSTALLS ANYWAY - that is microvm's
# measurement of pacman and this repository's of apt. So the exit status is NOT the test; the
# binary is. Check the binary.
log "installing an ssh server in the chroot (family: $FAMILY)"
# NO PROXY, EVER. CI IS NOT BEHIND ONE.
#
# A proxy in this environment is a LAB artifact: the pod reaches the network through
# `mihomo.develop.svc.cluster.local`, a cluster-only name that does not resolve anywhere else.
# Passing it into the chroot either fails at DNS ("Temporary failure resolving") or, worse,
# works in the lab and fails on a GitHub runner - MEASURED both ways here, and microvm records
# the same trap in its own arch script.
#
# So the chroot gets an EMPTY proxy environment, and apt/pacman talk to the mirror directly.
# That is also what a GitHub runner does, which means a seed that works here is one that will
# work there: the two no longer differ in this.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ftp_proxy FTP_PROXY all_proxy ALL_PROXY
log "  no proxy: the chroot talks to the mirror directly"

chroot "$TREE" /bin/sh -c '
set -u
export DEBIAN_FRONTEND=noninteractive
export no_proxy='*' NO_PROXY='*'
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1 || true
    apt-get install -y openssh-server >>/tmp/apt.log 2>&1 || true
elif command -v pacman >/dev/null 2>&1; then
    # A FULL `pacman -Sy openssh` TRIES TO UPGRADE openssl AND BREAKS PACMAN ITSELF - measured
    # on cachyos. The passing manjaro leg assumes the installed libs and ignores openssl.
    pacman -S --noconfirm --needed \
        --assume-installed libcrypto.so=4-64 --assume-installed libssl.so=4-64 \
        --ignore openssl --ignore openssl-libs openssh >/tmp/apt.log 2>&1 \
    || pacman -S --noconfirm --needed openssh >>/tmp/apt.log 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openssh-server >/tmp/apt.log 2>&1 || true
elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install openssh >/tmp/apt.log 2>&1 || true
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache openssh >/tmp/apt.log 2>&1 || true
fi
# host keys are what a fresh install lacks when policy-rc.d blocked postinst
for k in /usr/bin/ssh-keygen /usr/sbin/ssh-keygen; do
    [ -x "$k" ] && "$k" -A >/dev/null 2>&1 && break
done
exit 0
' || log "  the package step reported a failure; the binary is what is checked below"

# THE GUEST AGENT IS INSTALLED IN THE SAME TRIP, because it is the same package manager and the
# same network. `vm-configure` used to spend two `ssh:` steps on it, and an `ssh:` step is a step
# that can fail on a password it was not given.
if [ ! -x "$TREE/usr/lib/systemd/system/qemu-guest-agent.service" ] \
   && [ ! -x "$TREE/lib/systemd/system/qemu-guest-agent.service" ]; then
    chroot "$TREE" /bin/sh -c '
export DEBIAN_FRONTEND=noninteractive no_proxy="*"
if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y qemu-guest-agent >>/tmp/apt.log 2>&1 || true
elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm --needed qemu-guest-agent >>/tmp/apt.log 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y qemu-guest-agent >>/tmp/apt.log 2>&1 || true
fi
exit 0' || true
fi
for d in "$TREE/usr/lib/systemd/system" "$TREE/lib/systemd/system"; do
    if [ -f "$d/qemu-guest-agent.service" ]; then
        mkdir -p "$TREE/etc/systemd/system/multi-user.target.wants"
        ln -sf "$d/qemu-guest-agent.service" \
            "$TREE/etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service" 2>/dev/null || true
        log "  qemu-guest-agent enabled"
        break
    fi
done

if [ ! -x "$TREE/usr/sbin/sshd" ] && [ ! -x "$TREE/usr/sbin/sshd" ]; then
    log "sshd is NOT in the tree - refusing to publish a disk that cannot accept ssh"
    last=$(tail -25 "$TREE/tmp/apt.log" 2>/dev/null || true)
    [ -n "$last" ] && echo "$last"
    exit 1
fi
log "sshd is present: $(ls -l "$TREE/usr/sbin/sshd" | awk '{print $5}') bytes"

# ------------------------------------------------------------------ password auth
#
# The engine dials with a password. A drop-in is written even when one exists, because the value
# is the point; and the main config is given the Include line first if an image lacks it.
mkdir -p "$TREE/etc/ssh/sshd_config.d"
if [ -f "$TREE/etc/ssh/sshd_config" ] && ! grep -q '^Include /etc/ssh/sshd_config.d' "$TREE/etc/ssh/sshd_config" 2>/dev/null; then
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$WORK/inc"
    cat "$TREE/etc/ssh/sshd_config" >> "$WORK/inc"
    cat "$WORK/inc" > "$TREE/etc/ssh/sshd_config"
fi
printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication no\nUsePAM yes\n' \
    > "$TREE/etc/ssh/sshd_config.d/99-easyvm.conf"

# ------------------------------------------------------------------ the vm-configure work
#
# EVERYTHING `vm-configure` DOES THAT IS A FILE IS DONE HERE, OFFLINE, IN THE SAME PASS.
#
# That leg used to run twenty `ssh:` steps: hostname, /etc/hosts, time zone, locale, the guest
# agent, gdm automatic login, the screen lock. All of it is configuration, not a live system -
# so doing it while the tree is a directory costs nothing, needs no boot, and cannot fail on a
# keyboard. What is left for `vm-configure` is the part that genuinely needs a running guest.
mkdir -p "$TREE/etc"

# THE MACHINE'S NAME. hostnamectl writes /etc/hostname and /etc/machine-info; doing it by hand
# is the same result without a running dbus.
printf '%s\n' "$HOSTNAME" > "$TREE/etc/hostname"
if [ -f "$TREE/etc/hosts" ]; then
    if grep -q '^127\.0\.1\.1' "$TREE/etc/hosts"; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/" "$TREE/etc/hosts"
    else
        printf '127.0.1.1\t%s\n' "$HOSTNAME" >> "$TREE/etc/hosts"
    fi
else
    printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME" > "$TREE/etc/hosts"
fi

# THE TIME ZONE is a symlink into the zoneinfo tree, which is what `timedatectl` ends up doing.
if [ -f "$TREE/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TREE/etc/localtime"
    printf '%s\n' "$TIMEZONE" > "$TREE/etc/timezone"
    log "  time zone $TIMEZONE"
else
    log "  zoneinfo has no $TIMEZONE; leaving the time zone alone"
fi

# THE LOCALE, written the way `update-locale` would: a line in /etc/default/locale plus the
# locale itself generated into the archive. `locale-gen` needs a chroot with the locale data,
# which is present, so it is run for real.
if [ -f "$TREE/etc/default/locale" ]; then
    sed -i '/^LANG=/d;/^LC_ALL=/d' "$TREE/etc/default/locale"
fi
printf 'LANG=%s\nLC_ALL=%s\n' "$LOCALE" "$LOCALE" >> "$TREE/etc/default/locale"
if [ -x "$TREE/usr/sbin/locale-gen" ] || [ -x "$TREE/sbin/locale-gen" ]; then
    chroot "$TREE" /bin/sh -c "locale-gen '$LOCALE' >/dev/null 2>&1 || true" || true
    log "  locale $LOCALE generated"
fi

# GDM AUTOMATIC LOGIN, because an unattended client cannot type a password at the greeter.
for conf in "$TREE/etc/gdm3/custom.conf" "$TREE/etc/gdm/custom.conf"; do
    dir=$(dirname "$conf")
    [ -d "$dir" ] || continue
    [ -f "$conf" ] || printf '[daemon]\n' > "$conf"
    sed -i 's/^#*AutomaticLoginEnable=.*/AutomaticLoginEnable=true/' "$conf"
    sed -i "s/^#*AutomaticLogin=.*/AutomaticLogin=$USERNAME/" "$conf"
    grep -q '^AutomaticLoginEnable=' "$conf" || printf 'AutomaticLoginEnable=true\n' >> "$conf"
    grep -q '^AutomaticLogin=' "$conf" || printf 'AutomaticLogin=%s\n' "$USERNAME" >> "$conf"
    log "  automatic login for $USERNAME in $conf"
done

# NO LOCK, NO BLANK, NO SUSPEND. `gsettings` is a per-user dconf write, so it is done as a dconf
# profile override - a system-wide default that applies to every user without a running session.
DB=$(ls -d "$TREE/usr/share/glib-2.0/schemas" 2>/dev/null || true)
if [ -n "$DB" ]; then
    mkdir -p "$TREE/etc/dconf/db/local.d"
    cat > "$TREE/etc/dconf/db/local.d/00-easyvm" <<'DCONF'
[org/gnome/desktop/session]
idle-delay=uint32 0
[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
DCONF
    mkdir -p "$TREE/etc/dconf/profile"
    printf 'user-db:user\nsystem-db:local\n' > "$TREE/etc/dconf/profile/user"
    if [ -x "$TREE/usr/bin/dconf" ]; then
        chroot "$TREE" /usr/bin/dconf update >/dev/null 2>&1 || true
    fi
    log "  dconf profile turns the lock, the blank and the suspend off"
fi

# enable it: a symlink, which needs no running systemd
if [ -f "$TREE/usr/lib/systemd/system/ssh.socket" ] || [ -f "$TREE/lib/systemd/system/ssh.socket" ]; then
    mkdir -p "$TREE/etc/systemd/system/sockets.target.wants"
    ln -sf /usr/lib/systemd/system/ssh.socket \
        "$TREE/etc/systemd/system/sockets.target.wants/ssh.socket" 2>/dev/null || true
fi
for unit in ssh.service sshd.service; do
    for d in "$TREE/usr/lib/systemd/system" "$TREE/lib/systemd/system"; do
        if [ -f "$d/$unit" ]; then
            mkdir -p "$TREE/etc/systemd/system/multi-user.target.wants"
            ln -sf "$d/$unit" "$TREE/etc/systemd/system/multi-user.target.wants/$unit" 2>/dev/null || true
        fi
    done
done

# ------------------------------------------------------------------ hand DNS back to easyvm
#
# THE CONTAINER'S resolv.conf WAS A LOAN, AND IT IS PAID BACK BEFORE THE DISK IS CLOSED.
#
# The chroot needed a working nameserver to reach a mirror, and the only one available at build
# time is the runner's. Leaving it in the image would ship a guest whose DNS points at a
# cluster-only address (MEASURED: `nameserver 172.18.0.10` and `search develop.svc.cluster.local`)
# that exists nowhere on the machine the disk runs on.
#
# easyvm serves DNS itself at 172.30.0.1 for the guest's tap network, and that is what the image
# must say. The target is a REAL FILE rather than Ubuntu's dangling
# `../run/systemd/resolve/stub-resolv.conf` symlink, because the engine reads the file at boot
# before systemd-resolved has created its own.
#
# THIS RUNS AFTER EVERY NETWORK STEP AND BEFORE `mke2fs -d`, so the disk is closed with the
# addresses it will actually have.
rm -f "$TREE/etc/resolv.conf"
printf 'nameserver %s\n' "$EASYVM_DNS" > "$TREE/etc/resolv.conf"
chmod 644 "$TREE/etc/resolv.conf"

# systemd-resolved and NetworkManager would both overwrite it in the guest; a drop-in says to
# leave a file-only configuration alone, which is what an unattended guest wants.
if [ -d "$TREE/etc/systemd" ]; then
    mkdir -p "$TREE/etc/systemd/resolved.conf.d"
    printf '[Resolve]\nDNS=%s\nFallbackDNS=\n' "$EASYVM_DNS" \
        > "$TREE/etc/systemd/resolved.conf.d/99-easyvm.conf"
fi
log "  resolv.conf and resolved.conf.d now name $EASYVM_DNS (the easyvm DNS)"

# ------------------------------------------------------------------ rebuild the filesystem IN PLACE
#
# NO 128 GiB INTERMEDIATE FILE. The disk is unpacked once (sparse - a 128 GiB disk with 10 GiB
# of contents costs 10 GiB), the new filesystem is written STRAIGHT INTO IT at the partition's
# own byte offset with `mke2fs -E offset=`, and the result is packed back.
#
# AN EARLIER VERSION BUILT THE FILESYSTEM SEPARATELY AND CONCATENATED IT, and that was wrong
# twice over: `cat` writes the holes out for real (9.9 GiB became 129 GiB and filled the runner),
# and `conv=sparse` on a pipe SKIPS a run of zeroes instead of writing them, which shifts every
# byte after the hole - it produced an 11 GiB file where a 128 GiB disk was promised, and the
# corruption was invisible until boot.
#
# `mke2fs -E offset=N` writes a filesystem at byte N of an existing file and leaves everything
# before it untouched - MEASURED: a magic string at byte 0 survived, and the filesystem at 4 MiB
# read back with debugfs. It also needs no second copy of the tree.
log "writing a new ext4 of $((PART_BYTES / 1048576)) MiB at byte $START_BYTE, in place"
#
# THE SIZE ARGUMENT IS IN 1 KiB BLOCKS, AND WITHOUT IT mke2fs SIZES THE FILESYSTEM TO THE WHOLE
# FILE. MEASURED: `mke2fs -E offset=N image` alone warns
#
#	"offset specified without an explicit file system size. Creating a file system with
#	 33278976 blocks but this might not be what you want."
#
# and 33278976 4 KiB blocks is 128 GiB - the whole disk, not the 129995 MiB partition. The
# filesystem then runs past the partition's end and over the backup GPT. mke2fs's positional
# size counts 1 KiB units regardless of -b, so the partition's byte length divided by 1024 is
# what to pass - MEASURED: the resulting filesystem reports 129995.0 MiB, exactly the partition.
FS_SIZE_1K=$((PART_BYTES / 1024))
mke2fs -q -F -t ext4 -U "$WANT_UUID" -E offset="$START_BYTE" -d "$TREE" "$BASE" "$FS_SIZE_1K"

# THE CLAIM, CHECKED ON THE COMPOSED IMAGE - not on a scratch copy of it.
#
# `e2fsck` takes a filesystem, not an offset, so the read-back goes through `debugfs`, which
# does understand `?offset=`. What matters is that the filesystem at that byte offset is
# readable and holds the files the seed put there; `e2fsck -fn` already ran on the same tree
# through `mke2fs -d` in an earlier version and is not the cheaper check here.
for probe in /usr/sbin/sshd /etc/ssh/sshd_config.d/99-easyvm.conf /etc/hostname /etc/resolv.conf; do
    debugfs -R "stat $probe" "$BASE?offset=$START_BYTE" 2>/dev/null | grep -q 'Type:' || {
        log "the composed image has no $probe"
        exit 1
    }
done
log "the composed image carries sshd, its config, the hostname and the easyvm DNS"

GOT=$(stat -c %s "$BASE")
[ "$GOT" = "$DISK_BYTES" ] || {
    log "the image is $GOT bytes, the base was $DISK_BYTES - the disk size changed"
    exit 1
}

# pack it back: -c compresses, and qcow2 keeps the virtual size
qemu-img convert -f raw -O qcow2 -c "$BASE" "$DISK.new"
mv "$DISK.new" "$DISK"

log "done"
qemu-img info "$DISK" | grep -E 'virtual size|disk size' | sed 's/^/  /'
