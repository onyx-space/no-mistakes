#!/usr/bin/env bash
#
# fork-sync.sh - sync this no-mistakes fork against upstream, rebuild the local
# runtime, and install it.
#
# Why this exists: the runtime on an endpoint that runs this fork is a LOCAL
# BUILD of this checkout, never an upstream release. `no-mistakes update`
# downloads the latest official release and would silently replace that build,
# so it must not be used to move the runtime forward. This script is the
# supported way: fetch upstream, merge it into the fork's build branch, rebuild
# with the fork's own version stamp, install the result, and verify it.
#
# Failure discipline: a failure at any step leaves the previously installed
# binary in place. The replacement happens only after the build and the fork
# version stamp have both been verified, and any failure after the replacement
# restores the backup taken immediately before it.
#
# The flow is idempotent: a second run on an already-synced fork merges nothing,
# rebuilds the same bytes, installs the same bytes, and does not bounce the
# daemon.
#
# Run it from any directory; the repository is resolved from this file's own
# location unless --repo is given.
#
# Usage: scripts/fork-sync.sh [options]
#   --repo PATH        fork checkout (default: the repository this script lives in)
#   --branch NAME      fork branch to sync and build (default: main)
#   --bin PATH         runtime binary to replace (default: no-mistakes on PATH)
#   --upstream URL     upstream repository (default: the canonical upstream)
#   --no-install       sync and build only; do not replace the binary or touch the daemon
#   --force            restart the daemon even when pipeline runs are active
#   -h, --help         this message

set -euo pipefail

DEFAULT_UPSTREAM="https://github.com/kunchenguid/no-mistakes.git"
BACKUP_DIR="${NO_MISTAKES_FORK_SYNC_BACKUP_DIR:-$HOME/.cache/no-mistakes-backup}"

log() { printf 'fork-sync: %s\n' "$*" >&2; }
die() { printf 'fork-sync: %s\n' "$*" >&2; exit 1; }

REPO=""
BRANCH="main"
BIN=""
UPSTREAM="$DEFAULT_UPSTREAM"
NO_INSTALL=0
FORCE=0

while [ $# -gt 0 ]; do
	case "$1" in
	--repo)    REPO="${2:-}"; shift 2 ;;
	--branch)  BRANCH="${2:-}"; shift 2 ;;
	--bin)     BIN="${2:-}"; shift 2 ;;
	--upstream) UPSTREAM="${2:-}"; shift 2 ;;
	--no-install) NO_INSTALL=1; shift ;;
	--force)   FORCE=1; shift ;;
	-h | --help)
		sed -n '3,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac
done

# ---------------------------------------------------------------------------
# Resolve the repository, the toolchain, and the runtime.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$REPO" ]; then
	REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
	[ -n "$REPO" ] || REPO="${NO_MISTAKES_FORK:-}"
fi
[ -n "$REPO" ] || die "cannot locate the fork checkout; pass --repo PATH"
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || die "$REPO is not a git checkout"

# A non-login shell often misses the Go toolchain (it is not always on the
# default PATH), and the build is the whole point of this script.
if ! command -v go >/dev/null 2>&1; then
	for dir in /usr/local/go/bin "$HOME/go/bin" /opt/homebrew/bin; do
		if [ -x "$dir/go" ]; then
			PATH="$dir:$PATH"
			break
		fi
	done
fi
command -v go >/dev/null 2>&1 || die "the go toolchain is not on PATH"

if [ -z "$BIN" ]; then
	BIN="$(command -v no-mistakes || true)"
fi
if [ "$NO_INSTALL" = 0 ]; then
	[ -n "$BIN" ] || die "cannot locate the installed no-mistakes binary; pass --bin PATH"
	[ -x "$BIN" ] || die "$BIN is not executable"
fi

# ---------------------------------------------------------------------------
# Work inside the target branch: use the checkout itself when it is already on
# that branch, otherwise a throwaway worktree, so a lane's own checkout is
# never switched away from the branch it was told to hold.
# ---------------------------------------------------------------------------

WORKTREE=""
cleanup() {
	if [ -n "$WORKTREE" ]; then
		git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

current_branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
if [ "$current_branch" = "$BRANCH" ]; then
	WORKDIR="$REPO"
else
	git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null ||
		die "branch $BRANCH does not exist in $REPO"
	WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/nm-fork-sync.XXXXXX")"
	rmdir "$WORKTREE"
	git -C "$REPO" worktree add "$WORKTREE" "$BRANCH" >/dev/null ||
		die "cannot check out $BRANCH in a temporary worktree"
	WORKDIR="$WORKTREE"
fi

dirty="$(git -C "$WORKDIR" status --porcelain)"
if [ -n "$dirty" ]; then
	die "$WORKDIR has uncommitted changes; commit or stash them first:
$dirty"
fi

# ---------------------------------------------------------------------------
# 1. Fetch upstream.
# ---------------------------------------------------------------------------

if git -C "$REPO" remote get-url upstream >/dev/null 2>&1; then
	configured="$(git -C "$REPO" remote get-url upstream)"
	if [ "$configured" != "$UPSTREAM" ]; then
		log "note: keeping the existing upstream remote ($configured)"
	fi
else
	git -C "$REPO" remote add upstream "$UPSTREAM"
	log "added remote upstream -> $UPSTREAM"
fi
git -C "$REPO" fetch --prune upstream

# ---------------------------------------------------------------------------
# 2. Preflight the merge so a conflict is reported before anything is written.
# ---------------------------------------------------------------------------

if preflight="$(git -C "$WORKDIR" merge-tree --write-tree HEAD upstream/main 2>&1)"; then
	:
elif printf '%s\n' "$preflight" | grep -q '^CONFLICT'; then
	printf '%s\n' "$preflight" >&2
	die "merging upstream/main into $BRANCH conflicts (see above); resolve it by hand"
else
	log "note: merge preflight unavailable, continuing"
fi

# ---------------------------------------------------------------------------
# 3. Merge upstream main into the fork branch and prove nothing local was lost.
# ---------------------------------------------------------------------------

before_head="$(git -C "$WORKDIR" rev-parse HEAD)"
if ! git -C "$WORKDIR" merge --no-edit upstream/main >&2; then
	git -C "$WORKDIR" merge --abort >/dev/null 2>&1 || true
	die "merge of upstream/main into $BRANCH failed; the branch is unchanged"
fi

behind="$(git -C "$WORKDIR" rev-list --count HEAD..upstream/main)"
[ "$behind" = 0 ] || die "$BRANCH is still $behind commits behind upstream/main after the merge"
[ "$(git -C "$WORKDIR" merge-base --is-ancestor upstream/main HEAD && echo yes)" = yes ] ||
	die "upstream/main is not an ancestor of $BRANCH after the merge"

log "merged; $BRANCH carries these commits on top of upstream/main:"
git -C "$WORKDIR" log --oneline "upstream/main..HEAD" | sed 's/^/  /' >&2

if [ "$(git -C "$WORKDIR" rev-parse HEAD)" = "$before_head" ]; then
	log "already up to date; nothing new from upstream"
fi

# ---------------------------------------------------------------------------
# 4. Rebuild and verify the fork's own version stamp.
# ---------------------------------------------------------------------------

log "building $BRANCH in $WORKDIR"
(cd "$WORKDIR" && make build)

BUILT="$WORKDIR/bin/no-mistakes"
[ -x "$BUILT" ] || die "make build did not produce $BUILT"

described="$(git -C "$WORKDIR" describe --tags --always --dirty)"
built_version="$("$BUILT" --version | awk '{print $3}')"
[ "$built_version" = "$described" ] ||
	die "built binary reports $built_version, but this branch describes itself as $described"
log "built $built_version"

if [ "$NO_INSTALL" = 1 ]; then
	log "--no-install: leaving $BIN untouched"
	log "done (build only)"
	exit 0
fi

# ---------------------------------------------------------------------------
# 5. Replace the runtime, keeping the previous binary for rollback.
# ---------------------------------------------------------------------------

# The daemon and the CLI must not run different builds, which is exactly what
# the lifecycle guard enforces for stop/restart. Check the same state before
# touching the binary, so a refusal does not have to be undone afterwards.
active_runs() {
	command -v python3 >/dev/null 2>&1 || return 1
	python3 - "${NM_HOME:-$HOME/.no-mistakes}/state.sqlite" <<'PY'
import os, sqlite3, sys
path = sys.argv[1]
if not os.path.exists(path):
    raise SystemExit(0)
con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
for run_id, branch, status in con.execute(
    "select id, branch, status from runs where status in "
    "('pending','running') order by created_at desc"
):
    print(f"  {run_id}  {status}  {branch}")
PY
}

if runs="$(active_runs)"; then
	if [ -n "$runs" ] && [ "$FORCE" = 0 ]; then
		printf '%s\n' "$runs" >&2
		die "active pipeline runs are in progress; wait for them or pass --force (the installed binary is unchanged)"
	fi
elif [ -n "$runs" ]; then
	log "note: could not read the pipeline run registry; the daemon restart below still refuses a busy daemon"
fi

old_version="$("$BIN" --version | awk '{print $3}')"
BACKUP="$BACKUP_DIR/no-mistakes.bak-$old_version"
mkdir -p "$BACKUP_DIR"
if [ ! -f "$BACKUP" ]; then
	cp -p "$BIN" "$BACKUP"
	log "backed up $old_version to $BACKUP"
fi

daemon_restart() {
	if [ "$FORCE" = 1 ]; then
		"$BIN" daemon restart --force
	else
		"$BIN" daemon restart
	fi
}

# The daemon must have started after the binary it now runs. daemon.pid records
# the daemon's own start time at whole-second resolution (ps -o lstart=), so
# both sides are compared floored to the second: a start in the same second as
# the install is not read as stale.
# Exit codes: 0 fresh, 1 stale, 2 unverifiable.
daemon_fresh() {
	local pidfile="$1" bin="$2" verdict
	command -v python3 >/dev/null 2>&1 || return 2
	verdict="$(python3 - "$pidfile" "$bin" <<'PY'
import json, math, os, sys
from datetime import datetime
try:
    with open(sys.argv[1]) as fh:
        started = json.load(fh).get("started_at")
    if not started:
        raise ValueError("no started_at")
    started_at = datetime.fromisoformat(started.replace("Z", "+00:00")).timestamp()
    installed_at = os.stat(sys.argv[2]).st_mtime
except Exception:
    print("unknown")
else:
    print("fresh" if math.floor(started_at) >= math.floor(installed_at) else "stale")
PY
)" || return 2
	case "$verdict" in
	fresh) return 0 ;;
	stale) return 1 ;;
	*) return 2 ;;
	esac
}

installed=0
settled=0
restart_attempted=0
on_exit() {
	status=$?
	if [ "$installed" = 1 ] && [ "$settled" = 0 ]; then
		log "rolling back to $old_version"
		install -m 755 "$BACKUP" "$BIN" || log "rollback failed; restore $BACKUP by hand"
		if [ "$restart_attempted" = 1 ]; then
			daemon_restart >/dev/null 2>&1 ||
				log "the daemon still runs the new build; restart it once it is idle"
		fi
	fi
	cleanup
	exit "$status"
}
trap on_exit EXIT

installed=1
install -m 755 "$BUILT" "$BIN"

cmp -s "$BUILT" "$BIN" || die "the installed binary does not match the built one"

# ---------------------------------------------------------------------------
# 6. Point the daemon at the new build and verify the running process is it.
# ---------------------------------------------------------------------------

if [ "$(git -C "$WORKDIR" rev-parse HEAD)" = "$before_head" ] && cmp -s "$BUILT" "$BACKUP" 2>/dev/null; then
	log "the installed binary already is this build; leaving the daemon alone"
else
	restart_attempted=1
	daemon_restart || die "daemon restart failed (the previous binary is restored)"

	fresh_rc=0
	daemon_fresh "${NM_HOME:-$HOME/.no-mistakes}/daemon.pid" "$BIN" || fresh_rc=$?
	if [ "$fresh_rc" = 1 ]; then
		die "the running daemon predates the installed binary (the previous binary is restored)"
	elif [ "$fresh_rc" = 2 ]; then
		log "note: could not verify the running daemon is this build; continuing"
	fi
fi

settled=1
log "runtime is $("$BIN" --version)"
log "rollback: install -m 755 $BACKUP $BIN"
log "done"
