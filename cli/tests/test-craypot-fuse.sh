#!/bin/bash
# Host-FUSE checks for the craypot patches: uid override, unlink-while-open,
# orphan purge, rename cycle, quotas, d_type, SIGTERM/umount checkpoint.
# Usage: tests/test-craypot-fuse.sh [path/to/agentfs]  (default: cargo build output)
set -euo pipefail

AGENTFS="${1:-${AGENTFS:-$(dirname "$0")/../target/debug/agentfs}}"
AGENTFS="$(realpath "$AGENTFS")"
WORK="$(mktemp -d /tmp/agentfs-craypot-XXXXXX)"
DB="$WORK/fs.db"
MNT="$WORK/mnt"
PID=
mkdir "$MNT"

cleanup() {
    [ -n "$PID" ] && kill -KILL "$PID" 2>/dev/null || true
    fusermount3 -u -z "$MNT" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAILED: $*"; exit 1; }
sql() {
    python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); r = c.execute(sys.argv[2]).fetchone(); c.commit(); print(r[0])' "$DB" "$1"
}

mount_fs() {
    "$AGENTFS" mount "$DB" "$MNT" --foreground "$@" &
    PID=$!
    for _ in $(seq 50); do
        mountpoint -q "$MNT" && return 0
        kill -0 "$PID" 2>/dev/null || fail "mount exited early"
        sleep 0.1
    done
    fail "mount not ready"
}

# SIGTERM must checkpoint and exit 0.
stop_term() {
    kill -TERM "$PID"
    local rc=0
    wait "$PID" || rc=$?
    PID=
    fusermount3 -u -z "$MNT" 2>/dev/null || true
    [ "$rc" = 0 ] || fail "SIGTERM exit status $rc"
    [ ! -s "$DB-wal" ] || fail "SIGTERM left a $(stat -c %s "$DB-wal") byte WAL"
}

# Seed a database whose directory /d is owned by uid 0 (like a Go-sealed DB).
(cd "$WORK" && "$AGENTFS" init seed >/dev/null 2>&1)
mv "$WORK/.agentfs/seed.db" "$DB"
rm -f "$WORK/.agentfs/seed.db-wal"
mount_fs
mkdir "$MNT/d"
stop_term
sql "UPDATE fs_inode SET uid = 0, gid = 0 WHERE ino = (SELECT ino FROM fs_dentry WHERE parent_ino = 1 AND name = 'd') RETURNING uid" >/dev/null

echo -n "TEST uid override... "
mount_fs
if touch "$MNT/d/x" 2>/dev/null; then fail "uid 0 dir writable without --uid"; fi
stop_term
mount_fs --uid "$(id -u)" --gid "$(id -g)" --max-bytes 1048576 --max-inodes 64
touch "$MNT/d/x" || fail "--uid did not make /d writable"
[ "$(stat -c %u:%g "$MNT/d")" = "$(id -u):$(id -g)" ] || fail "owner $(stat -c %u:%g "$MNT/d")"
echo OK

echo -n "TEST unlink while open... "
python3 - "$MNT" <<'EOF' || fail "unlink while open"
import mmap, os, sys
p = os.path.join(sys.argv[1], "tmpfile")
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o600)
os.write(fd, b"still here" * 1000)
os.fsync(fd)
os.unlink(p)
assert not os.path.exists(p)
assert os.pread(fd, 10, 0) == b"still here", os.pread(fd, 10, 0)
assert os.fstat(fd).st_size == 10000 and os.fstat(fd).st_nlink == 0
m = mmap.mmap(fd, 10000, prot=mmap.PROT_READ)
assert m[9990:] == b"still here"
m.close()
# rename over an open file keeps the replaced inode readable too
q = os.path.join(sys.argv[1], "q")
old = os.open(q, os.O_RDWR | os.O_CREAT, 0o600); os.write(old, b"old"); os.fsync(old)
with open(q + ".new", "w") as f: f.write("new")
os.rename(q + ".new", q)
assert os.pread(old, 3, 0) == b"old" and open(q).read() == "new"
os.close(old)
os.close(fd)
EOF
stop_term
[ "$(sql 'SELECT COUNT(*) FROM fs_inode WHERE nlink = 0')" = 0 ] || fail "orphan inode left after close"
echo OK

echo -n "TEST orphan purged at mount... "
mount_fs --uid "$(id -u)" --gid "$(id -g)"
python3 - "$MNT" "$PID" <<'EOF' || fail "orphan setup"
import os, signal, sys
p = os.path.join(sys.argv[1], "orphan")
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o600)
os.write(fd, b"x" * 5000); os.fsync(fd); os.unlink(p)
os.kill(int(sys.argv[2]), signal.SIGKILL)  # daemon dies with the file open
EOF
wait "$PID" 2>/dev/null || true  # killed
PID=
fusermount3 -u -z "$MNT"
mount_fs --uid "$(id -u)" --gid "$(id -g)"
stop_term
[ "$(sql 'SELECT COUNT(*) FROM fs_inode WHERE nlink = 0')" = 0 ] || fail "orphan not purged"
echo OK

echo -n "TEST rename into own subtree... "
mount_fs --uid "$(id -u)" --gid "$(id -g)" --max-bytes 1048576 --max-inodes 64
mkdir -p "$MNT/a/b/c"
if out=$(mv "$MNT/a" "$MNT/a/b/c/x" 2>&1); then fail "rename cycle succeeded"; fi
echo "$out" | grep -q "subdirectory of itself\|Invalid argument" || fail "$out"
[ -d "$MNT/a/b/c" ] || fail "tree damaged"
echo OK

echo -n "TEST quota ENOSPC... "
df -B1 --output=size "$MNT" | tail -1 | grep -q "^ *1048576$" || fail "statfs size $(df -B1 --output=size "$MNT" | tail -1)"
python3 - "$MNT" <<'EOF' || fail "quota"
import errno, os, sys
mnt = sys.argv[1]
fd = os.open(os.path.join(mnt, "big"), os.O_WRONLY | os.O_CREAT, 0o600)
try:
    for _ in range(40):
        os.write(fd, b"\0" * 65536)
    os.fsync(fd)
    raise SystemExit("no ENOSPC for 2.5 MiB with --max-bytes 1 MiB")
except OSError as e:
    assert e.errno == errno.ENOSPC, e
os.close(fd)
os.unlink(os.path.join(mnt, "big"))
# space is back after delete
with open(os.path.join(mnt, "small"), "wb") as f:
    f.write(b"\0" * 500000); f.flush(); os.fsync(f.fileno())
n = 0
try:
    while True:
        open(os.path.join(mnt, f"i{n}"), "w").close(); n += 1
except OSError as e:
    assert e.errno == errno.ENOSPC, e
assert n > 0, n
for i in range(n):
    os.unlink(os.path.join(mnt, f"i{i}"))
EOF
echo OK

echo -n "TEST readdir d_type... "
mkfifo "$MNT/fifo"
[ "$(find "$MNT" -maxdepth 1 -type p)" = "$MNT/fifo" ] || fail "find -type p: $(find "$MNT" -maxdepth 1 -type p)"
find "$MNT" -maxdepth 1 -type f | grep -q fifo && fail "fifo listed as regular file"
echo OK

echo -n "TEST SIGTERM checkpoint... "
stop_term
echo OK

echo -n "TEST umount checkpoint... "
mount_fs --uid "$(id -u)" --gid "$(id -g)"
echo data > "$MNT/after"
fusermount3 -u "$MNT"
rc=0; wait "$PID" || rc=$?; PID=
[ "$rc" = 0 ] || fail "exit status $rc after umount"
[ ! -s "$DB-wal" ] || fail "umount left a $(stat -c %s "$DB-wal") byte WAL"
echo OK
