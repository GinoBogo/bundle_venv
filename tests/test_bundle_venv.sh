#!/usr/bin/env bash
# ==============================================================================
# test_bundle_venv.sh – Regression tests for tools/bundle_venv.sh.
#
# Run from anywhere:  tools/tests/test_bundle_venv.sh [-q] [-v] [-h]
#
#   -q   only the failures and the summary
#   -v   show each check as it runs
#   -h   this help
#
# Every check runs against fixture venvs created under a temporary directory, so
# the repository is only ever read. Nothing here writes into it.
#
# Exit status: 0 when every check passes, 1 otherwise.
#
# Author: Gino Bogo
# Date: 2026-10
# Version: 1.6.3
# ==============================================================================

set -uo pipefail

# --- locate the repository from this script, following symlinks --------------

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" == /* ]] || SOURCE="$SOURCE_DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# Locate bundle_venv.sh on our own, regardless of where this test or the
# script live inside the repository layout (root, tools/, ...).
SUT=""
for candidate in "$SCRIPT_DIR/../bundle_venv.sh" "$SCRIPT_DIR/bundle_venv.sh"; do
    if [[ -f "$candidate" ]]; then
        SUT="$(cd -P "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
        break
    fi
done
if [[ -z "$SUT" ]]; then
    d="$SCRIPT_DIR"
    while [[ "$d" != "/" ]]; do
        for candidate in "$d/bundle_venv.sh" "$d/tools/bundle_venv.sh"; do
            if [[ -f "$candidate" ]]; then
                SUT="$(cd -P "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
                break 2
            fi
        done
        d="$(dirname "$d")"
    done
fi

[[ -f "$SUT" ]] || {
    printf 'cannot find bundle_venv.sh (searched from %s)\n' "$SCRIPT_DIR" >&2
    exit 2
}

# Repository root is the SUT directory, or its parent when the SUT lives in tools/.
SUT_DIR="$(dirname "$SUT")"
if [[ "$(basename "$SUT_DIR")" == "tools" ]]; then
    REPO_ROOT="$(cd -P "$SUT_DIR/.." && pwd)"
else
    REPO_ROOT="$SUT_DIR"
fi

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

QUIET=false
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) QUIET=true ;;
        -v) VERBOSE=true ;;
        -h | --help)
            sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'unknown option: %s (try --help)\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

WORKDIR="$(mktemp -d)"
# Invoked only by the trap below; the directive keeps that association visible.
# shellcheck disable=SC2329
cleanup() { rm -rf -- "$WORKDIR"; }
trap cleanup EXIT

FX="$WORKDIR/fx"

# ==============================================================================
# ASSERTIONS
#
# Two shapes only, because the obvious third one lies. Piping a command into
# `grep -q` under `set -o pipefail` reports failure when grep exits early on
# SIGPIPE, and calling a helper inside $( ) loses any global it sets. So every
# check first captures into OUT, then asserts on that string.
# ==============================================================================

PASSED=0
FAILED=0
OUT=""
WHY=""

note() { $QUIET || printf '%s\n' "$*"; }

# capture <command...> -- run it, store stdout+stderr in OUT, keep its status
capture() {
    $VERBOSE && note "    \$ ${*:-}"
    OUT="$("$@" 2>&1)"
}

# ran_ok <name> <command...>   the command must succeed
ran_ok() {
    local name="$1"; shift
    if capture "$@"; then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' $QUIET '' "$name"
        printf '        exit %d: %s\n' "$?" "$OUT"
    fi
}

# ran_no <name> <command...>   the command must be refused
ran_no() {
    local name="$1"; shift
    if capture "$@"; then
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        printf '        it succeeded: %s\n' "${OUT:-(no output)}"
    else
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    fi
}

# says <name> <needle>       OUT (from the last capture) must contain needle
says() {
    if [[ "$OUT" == *"$2"* ]]; then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"
        printf '        wanted %q in: %s\n' "$2" "${OUT:-(no output)}"
    fi
}

# says_not <name> <needle>   OUT must NOT contain needle
says_not() {
    if [[ "$OUT" != *"$2"* ]]; then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"
        printf '        did not want %q in: %s\n' "$2" "$OUT"
    fi
}

# cond <name> <test-expression...>  a plain bash test, no command run
cond() {
    local name="$1"; shift
    if "$@"; then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$name"
        [[ -n "$WHY" ]] && printf '        %s\n' "$WHY"
    fi
}

section() {
    note ""
    $QUIET || printf '%b%s%b\n' "$BOLD" "$1" "$RESET"
}

# ==============================================================================
# HELPERS
# ==============================================================================

# venv <args...> -- run the script under test from the repository root
venv() { (cd "$REPO_ROOT" && bash "$SUT" "$@"); }

# mkvenv <dir> -- create a fresh --copies venv at dir
mkvenv() {
    python3 -m venv --copies "$1" >/dev/null 2>&1
}

# run_installer <glob-dir> <name-glob>
#   Runs a built self-extracting installer into a fresh destination. Sets
#   INSTALL_DEST to where it unpacked and INSTALL_OUT to what it printed, and
#   returns the installer's own exit status.
INSTALL_DEST=""
INSTALL_OUT=""
run_installer() {
    local dir="$1" glob="$2" f status=0
    INSTALL_DEST=""
    INSTALL_OUT=""
    for f in "$dir"/$glob; do
        [[ -x "$f" ]] || continue
        INSTALL_DEST="$(mktemp -d "$WORKDIR/install.XXXXXX")"
        INSTALL_OUT="$("$f" "$INSTALL_DEST" 2>&1)"
        status=$?
        return "$status"
    done
    INSTALL_OUT="no installer matching $dir/$glob"
    return 1
}

[ -f "$SUT" ] || {
    printf 'cannot find %s\n' "$SUT" >&2
    exit 2
}

# ==============================================================================
note ""
$QUIET || printf '%b%btest_bundle_venv.sh%b\n' "$BOLD" "$CYAN" "$RESET"
$QUIET || printf '%b%s%b\n' "$CYAN" \
    "----------------------------------------------------------------------" "$RESET"

# ------------------------------------------------------------------------------
section "venv discovery and validation"

ran_no "a non-venv directory is refused" venv -n "$WORKDIR/not-a-venv" "$REPO_ROOT/tools"
ran_no "unknown option refused" venv --nope ./venv
ran_no "no venv given and none beside the script" venv -t

# ------------------------------------------------------------------------------
section "dry run writes nothing"

mkvenv "$FX/src"
capture venv -n "$FX/dst" -t "$FX/src"
ran_ok "the dry run itself succeeds" test -n "$OUT"
cond "dry run does not create the target venv" test ! -e "$FX/dst"

# ------------------------------------------------------------------------------
section "self-extract installer"

mkvenv "$FX/embed_src"

# The output directory must exist for the archive's temp file to be written.
mkdir -p "$WORKDIR/out"
ran_ok "--embed -r builds a self-extracting installer" \
    venv --embed -r -o "$WORKDIR/out/myapp_venv.tgz" "$FX/embed_src" -q
installers=("$WORKDIR/out/"*.run)
cond "exactly one .run file was produced" test "${#installers[@]}" -eq 1
cond "intermediate tarball removed on clean run" \
    test -z "$(ls "$WORKDIR/out/"*.tar.gz 2>/dev/null)"

# --self-extract naming an existing directory is refused (mirrors
# bundle_scripts.sh's guard against mv dropping the installer into a dir).
# An explicit -o is passed so compress does not default to writing a tarball
# into the repository root.
mkdir -p "$WORKDIR/adir"
ran_no "--self-extract naming a directory is refused" \
    venv --embed -r -o "$WORKDIR/adir/.tgz" --self-extract="$WORKDIR/adir" \
    "$FX/embed_src" -q
cond "the refused directory is unchanged" test -d "$WORKDIR/adir"

# Running the installer extracts the venv and fixes paths to the destination.
if run_installer "$WORKDIR/out/" "myapp_venv.run"; then
    OUT="$INSTALL_OUT"
    cond "the installer unpacks a venv" test -d "$INSTALL_DEST/embed_src"
    says "installer reports path fixing" "fixing venv paths at"
    # pyvenv.cfg's home= now points at the embedded python.
    OUT="$(sed -n 's|^[[:space:]]*home[[:space:]]*=[[:space:]]*||p' \
        "$INSTALL_DEST/embed_src/pyvenv.cfg" | head -n1)"
    if [[ "$OUT" == *".python/bin" ]]; then
        PASSED=$((PASSED + 1))
        $QUIET || printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "home= points at the embedded python"
    else
        FAILED=$((FAILED + 1))
        printf '  %sFAIL%s %s\n' "$RED" "$RESET" "home= points at the embedded python"
        printf '        got: %s\n' "$OUT"
    fi

    # Running the same installer into a destination that already holds the
    # venv basename must be refused, not silently merged.
    ran_no "the installer refuses an existing destination venv" \
        "${installers[0]}" "$INSTALL_DEST"
else
    OUT="$INSTALL_OUT"
    cond "the installer runs" false
fi

# ------------------------------------------------------------------------------
section "compression without self-extract"

mkvenv "$FX/plain_src"
mkdir -p "$WORKDIR/plain"
ran_ok "--compress creates a tarball" \
    venv -z -o "$WORKDIR/plain/myapp_venv.tgz" "$FX/plain_src" -q
cond "the tarball exists" test -f "$WORKDIR/plain/myapp_venv.tgz"
cond "no .run file is produced without -r" \
    test -z "$(ls "$WORKDIR/plain/"*.run 2>/dev/null)"

# ------------------------------------------------------------------------------
section "stdout and stderr"

capture bash "$SUT" -V
says "-V names the tool" "bundle_venv.sh v"

capture bash -c "bash '$SUT' 2>/dev/null"
says_not "usage on failure stays off stdout" "Usage"

capture bash -c "bash '$SUT' --help 2>/dev/null"
says "--help goes to stdout" "Usage"

capture bash -c "bash '$SUT' -q -n '$FX/dst2' -t '$FX/src' 2>/dev/null"
says     "--quiet keeps the dry-run plan"   "would:"
# The banner is part of print_usage and is gated by --quiet, so -q drops it;
# that is the shared convention of the three bundle tools and is not asserted
# here beyond what the --quiet check above implies.

# ------------------------------------------------------------------------------
section "overwrite safety (--force)"

mkvenv "$FX/force_src"
mkdir -p "$WORKDIR/force"
# Create a dummy archive
dummy="$WORKDIR/force/overwrite.tgz"
printf 'dummy\n' > "$dummy"
ran_no "refuses overwrite without --force" \
    venv -z -o "$dummy" "$FX/force_src" -q
ran_ok "overwrites with --force" \
    venv -z --force -o "$dummy" "$FX/force_src" -q
cond "archive non-empty after --force" test -s "$dummy"

# ------------------------------------------------------------------------------
section "the repository is left alone"

WHY="$(ls -1 "$REPO_ROOT"/*.tar.gz "$REPO_ROOT"/*.run 2>/dev/null)"
cond "no bundle written into the repository" test -z "$WHY"

# ==============================================================================
note ""
$QUIET || printf '%b%s%b\n' "$CYAN" \
    "----------------------------------------------------------------------" "$RESET"

if ((FAILED > 0)); then
    printf '%b  %d passed, %d FAILED%b\n' "$RED" "$PASSED" "$FAILED" "$RESET"
    exit 1
fi
printf '%b  %d passed%b\n' "$GREEN" "$PASSED" "$RESET"
exit 0
