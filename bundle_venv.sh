#!/usr/bin/env bash
# ==============================================================================
# bundle_venv.sh – Relocate and self-contain a --copies Python venv.
#
# Author: Gino Bogo
# Date: 2026-09-22
# Version: see SCRIPT_VERSION
# ==============================================================================

set -euo pipefail

# ==============================================================================
# GLOBAL CONFIGURATION
# ==============================================================================

SCRIPT_VERSION="1.6.3"

# ANSI colour codes
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# Decoration, not information: silent under --quiet.
SEPARATOR="----------------------------------------------------------------------"

# Script options initialization
DRY_RUN=false
FORCE=false
QUIET=false
KEEP_PYCACHE=false
EMBED_MODE="auto" # auto | force | skip
NO_STDLIB=false
NO_LIBPYTHON=false
NO_PATCHELF=false
COMPRESS=false
COMPRESS_FILE=""
COMPRESS_RESULT=""
INSTALL=false
INSTALL_FILE=""
INSTALLER_RESULT=""
NEW_PATH=""
VENV_ARG=""
BASE_PYTHON_ARG=""
BUNDLE_RUNTIME=false
BUNDLE_EXCLUDE_REGEX='^(libcuda|libnvidia|libamdhip|librocm|libopencl)'
declare -A RUNTIME_DEPS
INCLUDE_LIBS=()       # --bundle-include entries (sonames, globs or absolute paths)
INCLUDE_EXTRA_ELFS=() # libraries resolved from --bundle-include that ldd did not report

# Function: resolve_self_script
# Description: Resolves the absolute, symlink-free path to this script's own
#              source file. Used both to default VENV_DIR to the script's own
#              directory, and to embed a copy of this script into a
#              self-extracting installer (--self-extract).
# Arguments: (none)
resolve_self_script() {
    local sp="${BASH_SOURCE[0]}" t=""
    while [[ -L "$sp" ]]; do
        t=$(readlink "$sp")
        [[ "$t" == /* ]] && sp="$t" || sp="$(dirname "$sp")/$t"
    done
    if [[ -f "$sp" ]]; then
        printf '%s' "$(cd "$(dirname "$sp")" && pwd -P)/$(basename "$sp")"
    else
        printf '%s' "$sp"
    fi
}
SELF_SCRIPT="$(resolve_self_script)"

# ==============================================================================
# USER INTERFACE
# ==============================================================================

# Function: log_info
# Description: Prints an informational message in green.
# Arguments: $* - message string
log_info() { $QUIET || printf '%b[INFO]%b %s\n' "$GREEN" "$RESET" "$*"; }

# Function: log_note
# Description: Prints a note message in cyan.
# Arguments: $* - message string
log_note() { $QUIET || printf '%b[NOTE]%b %s\n' "$CYAN" "$RESET" "$*"; }

# Function: log_test
# Description: Prints a dry-run test message in yellow.
# Arguments: $* - message string
log_test() { printf '%b[TEST]%b %s\n' "$YELLOW" "$RESET" "$*"; }

# Function: log_warn
# Description: Prints a warning message in yellow to stderr and counts it.
# Arguments: $* - message string
log_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*" >&2
}

# Function: log_err
# Description: Prints an error message in red to stderr.
# Arguments: $* - message string
log_err() { printf '%b[FAIL]%b %s\n' "$RED" "$RESET" "$*" >&2; }

# tar is required to create the compressed venv archive; fail fast if missing.
TAR_BIN=""
if command -v gtar > /dev/null 2>&1 && gtar --version 2>/dev/null | grep -q 'GNU tar'; then
    TAR_BIN="gtar"
elif command -v tar > /dev/null 2>&1 && tar --version 2>/dev/null | grep -q 'GNU tar'; then
    TAR_BIN="tar"
else
    log_err "GNU tar required (gtar or GNU tar)."
    exit 3
fi

# Function: print_banner
# Description: Prints the title banner. Decoration, not information: silent
#              under --quiet, and shared by the normal run and --help.
sep()      { $QUIET || printf '\n%b%s%b\n' "$CYAN" "$SEPARATOR" "$RESET"; }
print_banner() {
    $QUIET && return 0
    printf '\n%b%bBundle Python venv v%s%b - by Gino Bogo\n' "$BOLD" "$CYAN" "$SCRIPT_VERSION" "$RESET"
    sep
}

# Function: print_usage
# Description: Displays the help menu.
# Arguments: $1 - exit code (optional, default 0)
print_usage() {
    local script_name
    # Usage printed as part of a failure is part of the error report and belongs
    # on stderr, so it cannot pollute a pipeline's real output; --help asked for
    # on purpose stays on stdout. Redirecting the whole body is safe here because
    # every path through this function ends in exit.
    if ((${1:-1} != 0)); then
        exec 1>&2
    fi
    script_name=$(basename "${BASH_SOURCE[0]:-$0}")
    print_banner
    echo -e "${CYAN}Description:${RESET}"
    echo -e "  Relocate and self-contain a --copies Python venv: embed the base"
    echo -e "  Python, rewrite internal paths, bundle runtime library deps, and"
    echo -e "  optionally produce a tarball or a self-extracting installer."
    echo
    echo -e "${CYAN}Usage:${RESET}"
    echo -e "  $script_name [OPTIONS] [VENV_DIR]"
    echo
    echo -e "${CYAN}Arguments:${RESET}"
    echo -e "  ${GREEN}VENV_DIR${RESET}               Path to the venv (default: the directory"
    echo -e "                      containing this script)"
    echo
    echo -e "${CYAN}Options:${RESET}"
    echo -e "  ${GREEN}-n, --new PATH${RESET}         Final venv path (default: VENV_DIR as given)"
    echo -e "  ${GREEN}-t, --test${RESET}             Dry run – print what would change, modify nothing"
    echo -e "  ${GREEN}-q, --quiet${RESET}            Only warnings/errors and final summary"
    echo -e "  ${GREEN}-k, --keep-pycache${RESET}     Keep __pycache__ directories (on disk and in any archive)"
    echo -e "  ${GREEN}-h, --help${RESET}             This help"
    echo -e "  ${GREEN}-V, --version${RESET}          Show version and exit"
    echo
    echo -e "  ${GREEN}--embed${RESET}                Force embedding of the base Python"
    echo -e "  ${GREEN}--no-embed${RESET}             Skip embedding (just fix paths; run on target)"
    echo -e "  ${GREEN}--base-python DIR${RESET}      Override base Python prefix detection"
    echo -e "  ${GREEN}--no-stdlib${RESET}            Don't copy the stdlib when embedding"
    echo -e "  ${GREEN}--no-libpython${RESET}         Don't copy libpython*.so when embedding"
    echo -e "  ${GREEN}--no-patchelf${RESET}          Don't patch ELF rpath"
    echo
    echo -e "  ${GREEN}--bundle-runtime${RESET}       Bundle all non-system shared library deps (e.g. OpenBLAS)"
    echo -e "  ${GREEN}--no-bundle-runtime${RESET}    Disable runtime bundling"
    echo -e "  ${GREEN}--bundle-exclude REGEX${RESET} Exclude libraries matching regex (default: CUDA/ROCm/OpenCL)"
    echo -e "  ${GREEN}--bundle-include LIST${RESET}  Always bundle these libraries, even system ones (implies"
    echo -e "                         --bundle-runtime). LIST: comma/space/colon-separated sonames,"
    echo -e "                         globs or absolute paths; repeatable; quote globs. Overrides"
    echo -e "                         --bundle-exclude. glibc core (libc, libm, ld-linux...) is never"
    echo -e "                         bundled. ':' is a separator, so paths with ':' need a repeat."
    echo
    echo -e "  ${GREEN}-f, --force${RESET}            Overwrite existing output files"
    echo -e "  ${GREEN}-z, --compress${RESET}         After fixing, create a tarball of the venv"
    echo -e "  ${GREEN}-o, --output FILE${RESET}      Archive output path (implies --compress)"
    echo
    echo -e "  ${GREEN}-r, --self-extract${RESET}     Build a self-extracting .run installer (implies -z)."
    echo -e "                         The intermediate tarball is removed on a clean run."
    echo -e "  ${GREEN}--self-extract=FILE${RESET}    ...with an explicit installer path"
    echo
    echo -e "${CYAN}Examples:${RESET}"
    echo -e "  Dry run:"
    echo -e "    ${GREEN}$script_name -t ./venv${RESET}"
    echo
    echo -e "  Relocate venv:"
    echo -e "    ${GREEN}$script_name -n /opt/myapp/venv ./venv${RESET}"
    echo
    echo -e "  Embed without zip:"
    echo -e "    ${GREEN}$script_name --embed ./venv${RESET}"
    echo
    echo -e "  Build installer:"
    echo -e "    ${GREEN}$script_name --embed -r ./venv${RESET}"
    echo
    echo -e "  Add system libs:"
    echo -e "    ${GREEN}$script_name --embed --bundle-include 'libssl.so.3,libsqlite3.so.0' -r ./venv${RESET}"
    echo
    echo -e "${CYAN}Notes:${RESET}"
    echo -e "  Workflow:"
    echo -e "    1. ${BOLD}Source PC:${RESET} Create venv with ${GREEN}--copies${RESET}"
    echo -e "         python3 -m venv --copies ./venv"
    echo -e "    2. ${BOLD}Source PC:${RESET} Install packages"
    echo -e "         source ./venv/bin/activate && pip install -r requirements.txt"
    echo -e "    3. ${BOLD}Source PC:${RESET} Embed Python and archive (requires ${GREEN}patchelf${RESET})"
    echo -e "         $script_name --embed -o myapp_venv.tgz ./venv"
    echo -e "    4. ${BOLD}Transport:${RESET} Copy the tarball and this script to the target PC"
    echo -e "    5. ${BOLD}Target PC:${RESET} Extract to the final destination"
    echo -e "         tar xzf myapp_venv.tgz -C /opt/myapp"
    echo -e "    6. ${BOLD}Target PC:${RESET} Rewrite internal paths to the new location"
    echo -e "         $script_name /opt/myapp/venv"
    echo
    echo -e "  Alternative to steps 3-6: build a single-file installer that asks for the"
    echo -e "  destination, extracts itself there, and fixes paths automatically:"
    echo -e "     $script_name --embed -r -o myapp_venv.tgz ./venv"
    echo -e "     ./myapp_venv.run /opt/myapp"
    echo
    echo -e "  With ${GREEN}-r${RESET} only the .run file needs transporting; the tarball is embedded"
    echo -e "  and, on a clean run, deleted after the installer is built."
    echo -e "  ${BOLD}libstdc++.so.6${RESET} is treated as a system library and is NOT bundled. Ensure"
    echo -e "  the target's libstdc++ is at least as new as the source's, or add it explicitly"
    echo -e "  with ${GREEN}--bundle-include libstdc++.so.6${RESET} if ABI compatibility with the source"
    echo -e "  machine is required."
    echo
    exit "${1:-1}"
}

# ==============================================================================
# INPUT PROCESSING
# ==============================================================================

FAIL_COUNT=0
CHANGE_COUNT=0
WARN_COUNT=0

# Function: add_bundle_includes
# Description: Splits a --bundle-include LIST (comma, colon or whitespace
#              separated) and appends each entry to INCLUDE_LIBS. Entries are
#              soname globs (matched with [[ == ]]) or absolute file paths.
#              A bare name without ".so" is shorthand: "libssl" -> "libssl.so*".
#              Note: ':' is a separator here, so an absolute path containing
#              a colon cannot be given inside a LIST; pass it as a separate
#              repeated --bundle-include instead.
#              Also turns on runtime bundling, since the option is meaningless
#              without it (a later --no-bundle-runtime still wins).
# Arguments: $1 - the LIST string
add_bundle_includes() {
    local list="$1" item
    local -a parts=()
    list="${list//,/ }"
    list="${list//:/ }"
    read -r -d '' -a parts <<< "$list" || true
    if ((${#parts[@]} == 0)); then
        log_err "--bundle-include: empty list"
        exit 2
    fi
    for item in "${parts[@]}"; do
        if [[ "$item" == /* ]]; then
            : # absolute path
        elif [[ "$item" == */* ]]; then
            log_err "--bundle-include: '$item' must be a soname/glob (no '/') or an absolute path"
            exit 2
        elif [[ "$item" != *.so* ]]; then
            item="${item}.so*"
        fi
        INCLUDE_LIBS+=("$item")
    done
    BUNDLE_RUNTIME=true
}

# Parse command-line arguments.
while (($#)); do
    case "$1" in
        -n | --new)
            if [[ $# -lt 2 ]]; then
                log_err "missing argument for $1"
                print_usage 2
            fi
            NEW_PATH="$2"
            shift 2
            ;;
        -t | --test)
            DRY_RUN=true
            shift
            ;;
        -f | --force)
            FORCE=true
            shift
            ;;
        -q | --quiet)
            QUIET=true
            shift
            ;;
        -k | --keep-pycache)
            KEEP_PYCACHE=true
            shift
            ;;
        --embed)
            EMBED_MODE="force"
            shift
            ;;
        --no-embed)
            EMBED_MODE="skip"
            shift
            ;;
        --base-python)
            if [[ $# -lt 2 ]]; then
                log_err "missing argument for $1"
                print_usage 2
            fi
            BASE_PYTHON_ARG="$2"
            shift 2
            ;;
        --no-stdlib)
            NO_STDLIB=true
            shift
            ;;
        --no-libpython)
            NO_LIBPYTHON=true
            shift
            ;;
        --no-patchelf)
            NO_PATCHELF=true
            shift
            ;;
        --bundle-runtime)
            BUNDLE_RUNTIME=true
            shift
            ;;
        --no-bundle-runtime)
            BUNDLE_RUNTIME=false
            shift
            ;;
        --bundle-exclude)
            if [[ $# -lt 2 ]]; then
                log_err "missing argument for $1"
                print_usage 2
            fi
            BUNDLE_EXCLUDE_REGEX="$2"
            shift 2
            ;;
        --bundle-exclude=*)
            BUNDLE_EXCLUDE_REGEX="${1#*=}"
            shift
            ;;
        --bundle-include)
            if [[ $# -lt 2 ]]; then
                log_err "missing argument for $1"
                print_usage 2
            fi
            add_bundle_includes "$2"
            shift 2
            ;;
        --bundle-include=*)
            add_bundle_includes "${1#*=}"
            shift
            ;;
        -z | --compress)
            COMPRESS=true
            shift
            ;;
        --compress=*)
            COMPRESS=true
            COMPRESS_FILE="${1#*=}"
            shift
            ;;
        -o | --output)
            if [[ $# -lt 2 ]]; then
                log_err "missing argument for $1"
                print_usage 2
            fi
            COMPRESS=true
            COMPRESS_FILE="$2"
            shift 2
            ;;
        --output=*)
            COMPRESS=true
            COMPRESS_FILE="${1#*=}"
            shift
            ;;
        -r | --self-extract)
            COMPRESS=true
            INSTALL=true
            shift
            ;;
        --self-extract=*)
            COMPRESS=true
            INSTALL=true
            INSTALL_FILE="${1#*=}"
            shift
            ;;
        -h | --help) print_usage 0 ;;
        -V | --version)
            echo "bundle_venv.sh v${SCRIPT_VERSION}"
            exit 0
            ;;
        --)
            shift
            VENV_ARG="${1:-}"
            break
            ;;
        -*)
            log_err "unknown option: $1"
            print_usage 2
            ;;
        *)
            VENV_ARG="$1"
            shift
            ;;
    esac
done

if ((${#INCLUDE_LIBS[@]} > 0)); then
    if ! $BUNDLE_RUNTIME; then
        log_warn "--bundle-include has no effect: runtime bundling was disabled (--no-bundle-runtime)"
    elif [[ "$EMBED_MODE" == "skip" ]]; then
        log_warn "--bundle-include has no effect with --no-embed (bundled libs live in .python/lib)"
    fi
fi

# ==============================================================================
# VENV DISCOVERY
# ==============================================================================

# Locate the virtual environment directory.
if [[ -n "$VENV_ARG" ]]; then
    VENV_PATH="$VENV_ARG"
else
    VENV_PATH="$(dirname "$SELF_SCRIPT")"
fi

[[ -d "$VENV_PATH" ]] || {
    log_err "venv directory not found: $VENV_PATH"
    exit 2
}
VENV_PATH="$(cd "$VENV_PATH" && pwd -P)"

[[ -z "$NEW_PATH" ]] && NEW_PATH="$VENV_PATH"
[[ "$NEW_PATH" == /* ]] || {
    log_err "--new must be an absolute path"
    exit 2
}
[[ -f "$VENV_PATH/pyvenv.cfg" ]] || {
    log_err "not a venv (pyvenv.cfg missing): $VENV_PATH"
    exit 2
}

print_banner

log_info "venv location:   $VENV_PATH"
log_info "target path:     $NEW_PATH"

# Function: detect_original_venv
# Description: Attempts to find the path where the venv was originally created,
#              but only returns it when it differs from the current venv
#              directory (i.e. when there is something to rewrite).
# Arguments: $1 - path to the venv directory.
detect_original_venv() {
    local venv="$1" p="" raw=""

    # Check pyvenv.cfg for the creation command.
    #
    # The command is stored verbatim, so flags such as --copies,
    # --system-site-packages, --prompt X, --clear or --upgrade may sit
    # between "venv" and the env directory. The env directory is always
    # the final whitespace-separated token, so take the last token and
    # reject anything that still looks like an option flag.
    if [[ -f "$venv/pyvenv.cfg" ]]; then
        raw=$(sed -n 's|^[[:space:]]*command[[:space:]]*=[[:space:]]*||p' \
            "$venv/pyvenv.cfg" | tail -n1)
        if [[ -n "$raw" ]]; then
            p="${raw##* }"
            # Strip surrounding quotes if the path was quoted.
            p="${p%\"}"
            p="${p#\"}"
            if [[ -n "$p" && "$p" != -* && "$p" != "$venv" ]]; then
                # On the source machine the path exists; on the target it
                # may not, so accept any path-like token containing a slash.
                if [[ -d "$p" || "$p" == /* || "$p" == ./* || "$p" == ../* || "$p" == */* ]]; then
                    printf '%s' "$p"
                    return 0
                fi
            fi
        fi
    fi

    # Check bin/activate for the VIRTUAL_ENV variable.
    # (No -d requirement: on the target this path will not exist yet, and
    # that is precisely what we want to rewrite.)
    if [[ -f "$venv/bin/activate" ]]; then
        p=$(sed -n 's|^[[:space:]]*VIRTUAL_ENV="\(.*\)"[[:space:]]*$|\1|p' \
            "$venv/bin/activate" | tail -n1)
        if [[ -n "$p" && "$p" != "$venv" ]]; then
            printf '%s' "$p"
            return 0
        fi
    fi

    # Scan shebangs in bin/ for paths that no longer exist.
    if [[ -d "$venv/bin" ]]; then
        local f first
        while IFS= read -r -d '' f; do
            [[ -L "$f" ]] && continue
            IFS= read -r first < "$f" 2> /dev/null || continue
            [[ "$first" == '#!'* ]] || continue
            p="${first#\#!}"
            p="${p%% *}"
            p="${p%/bin/python*}"
            if [[ -n "$p" && "$p" != "$venv" && ! -e "$p" ]]; then
                printf '%s' "$p"
                return 0
            fi
        done < <(find "$venv/bin" -maxdepth 1 -type f -print0)
    fi

    return 1
}

# Function: read_recorded_path
# Description: Reads the venv path as recorded in pyvenv.cfg or bin/activate
#              without filtering out the case where it matches the current
#              venv directory. Used only to distinguish "there was nothing to
#              rewrite" from "no recorded path could be found at all", so the
#              caller can print a clearer message.
# Arguments: $1 - path to the venv directory.
read_recorded_path() {
    local venv="$1" p="" raw=""

    if [[ -f "$venv/pyvenv.cfg" ]]; then
        raw=$(sed -n 's|^[[:space:]]*command[[:space:]]*=[[:space:]]*||p' \
            "$venv/pyvenv.cfg" | tail -n1)
        if [[ -n "$raw" ]]; then
            p="${raw##* }"
            p="${p%\"}"
            p="${p#\"}"
            if [[ -n "$p" && "$p" != -* ]]; then
                printf '%s' "$p"
                return 0
            fi
        fi
    fi

    if [[ -f "$venv/bin/activate" ]]; then
        p=$(sed -n 's|^[[:space:]]*VIRTUAL_ENV="\(.*\)"[[:space:]]*$|\1|p' \
            "$venv/bin/activate" | tail -n1)
        if [[ -n "$p" ]]; then
            printf '%s' "$p"
            return 0
        fi
    fi

    return 1
}

ORIGINAL_PATH=""
if ORIGINAL_PATH=$(detect_original_venv "$VENV_PATH"); then
    log_info "original venv:   $ORIGINAL_PATH"
else
    ORIGINAL_PATH=""
    recorded=""
    recorded=$(read_recorded_path "$VENV_PATH") || recorded=""
    if [[ -n "$recorded" && "$recorded" == "$NEW_PATH" ]]; then
        log_info "venv already at its recorded path; nothing to rewrite"
    else
        log_warn "could not detect original venv path; path rewriting will be skipped"
    fi
fi

[[ -n "$ORIGINAL_PATH" && "$ORIGINAL_PATH" == "$NEW_PATH" ]] && ORIGINAL_PATH=""

# ==============================================================================
# PYTHON ENVIRONMENT ANALYSIS
# ==============================================================================

# Function: detect_base_python
# Description: Locates the base Python installation prefix.
# Arguments: $1 - path to the venv directory.
detect_base_python() {
    local venv="$1" home="" x=""
    if [[ -n "$BASE_PYTHON_ARG" ]]; then
        printf '%s' "$BASE_PYTHON_ARG"
        return 0
    fi
    if [[ -f "$venv/pyvenv.cfg" ]]; then
        home=$(sed -n 's|^[[:space:]]*home[[:space:]]*=[[:space:]]*||p' "$venv/pyvenv.cfg" | head -n1)
    fi
    [[ -z "$home" ]] && return 1
    x="$home"
    [[ "$(basename "$x")" == "bin" ]] && x="$(dirname "$x")"
    printf '%s' "$x"
}

# Detect Python version (X.Y) — needed here so that base-Python validation
# below can look for the matching stdlib directory.
PYVER=""
for cand in "$VENV_PATH"/bin/python3.*; do
    [[ -e "$cand" ]] || continue
    n=$(basename "$cand")
    case "$n" in
        python3.[0-9] | python3.[0-9][0-9])
            PYVER="${n#python3.}"
            PYVER="3.$PYVER"
            break
            ;;
        *) continue ;;
    esac
done

if [[ -z "$PYVER" && -x "$VENV_PATH/bin/python3" ]]; then
    if out=$("$VENV_PATH/bin/python3" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2> /dev/null); then
        PYVER="$out"
    fi
fi

[[ -n "$PYVER" ]] || {
    log_err "could not determine Python version from $VENV_PATH/bin/"
    exit 2
}
log_info "Python version:  $PYVER"

BASE_PYTHON=""
if BASE_PYTHON=$(detect_base_python "$VENV_PATH"); then
    # Require actual stdlib evidence: an existing /usr on the target is
    # not enough (it will be there but have no python$PYVER tree under it).
    if [[ -d "$BASE_PYTHON/lib/python$PYVER" || -d "$BASE_PYTHON/lib64/python$PYVER" ]]; then
        log_info "base Python:     $BASE_PYTHON"
    else
        if [[ -d "$BASE_PYTHON" ]]; then
            log_warn "base Python prefix exists but has no python$PYVER stdlib: $BASE_PYTHON"
        else
            log_warn "base Python prefix does not exist here: $BASE_PYTHON"
        fi
        BASE_PYTHON=""
    fi
else
    log_warn "could not detect base Python prefix"
fi

# ==============================================================================
# BASE PYTHON EMBEDDING
# ==============================================================================

EMBED_DIR="$VENV_PATH/.python"

# Function: should_embed
# Description: Logic to determine if base Python should be bundled.
# Arguments: (none)
should_embed() {
    # Explicit skip.
    [[ "$EMBED_MODE" == "skip" ]] && return 1
    # Already embedded — never re-embed, even in force mode.
    [[ -d "$EMBED_DIR/lib/python$PYVER" ]] && return 1
    # Force: caller has already validated that a usable base Python exists.
    [[ "$EMBED_MODE" == "force" ]] && return 0
    # Auto: embed iff a validated base Python is available.
    [[ -n "$BASE_PYTHON" ]] || return 1
    return 0
}

# Function: copy_stdlib
# Description: Copies the Python standard library to the embedded directory.
# Arguments: (none)
copy_stdlib() {
    local stdlib=""
    for cand in "$BASE_PYTHON/lib/python$PYVER" "$BASE_PYTHON/lib64/python$PYVER"; do
        [[ -d "$cand" ]] && {
            stdlib="$cand"
            break
        }
    done
    if [[ -z "$stdlib" ]]; then
        log_warn "stdlib not found under $BASE_PYTHON"
        return 1
    fi
    log_info "copying stdlib:  $stdlib  ->  $EMBED_DIR/lib/python$PYVER"
    if $DRY_RUN; then
        log_test "would: cp -a $stdlib $EMBED_DIR/lib/"
    else
        mkdir -p "$EMBED_DIR/lib"
        cp -a "$stdlib" "$EMBED_DIR/lib/"
    fi
}

# Function: find_libpython
# Description: Searches for the libpython shared object.
#              Uses find(1) rather than unquoted globs so that base Python
#              prefixes containing spaces are handled correctly.
# Arguments: (none)
find_libpython() {
    local dirs=()
    [[ -d "$BASE_PYTHON/lib" ]] && dirs+=("$BASE_PYTHON/lib")
    [[ -d "$BASE_PYTHON/lib64" ]] && dirs+=("$BASE_PYTHON/lib64")
    ((${#dirs[@]} > 0)) || return 1
    find "${dirs[@]}" -name "libpython$PYVER.so*" -print -quit 2> /dev/null
}

# Function: copy_libpython
# Description: Copies the libpython binary to the embedded directory.
# Arguments: (none)
copy_libpython() {
    local lib="" d=""
    lib=$(find_libpython) || true
    [[ -n "$lib" ]] || {
        log_warn "libpython$PYVER.so not found under $BASE_PYTHON"
        return 1
    }
    d=$(dirname "$lib")
    log_info "copying libpython: $d/libpython$PYVER.so*  ->  $EMBED_DIR/lib/"
    if $DRY_RUN; then
        log_test "would: find $d -maxdepth 1 -name 'libpython$PYVER.so*' \\
                  -exec cp -af {} $EMBED_DIR/lib/ \\;"
    else
        mkdir -p "$EMBED_DIR/lib"
        local matched=false so=""
        while IFS= read -r -d '' so; do
            cp -a "$so" "$EMBED_DIR/lib/"
            matched=true
        done < <(find "$d" -maxdepth 1 -name "libpython$PYVER.so*" -print0 2> /dev/null || true)
        if ! $matched; then
            log_warn "no libpython$PYVER.so* files found under $d"
            return 1
        fi
    fi
}

# System libraries that should NOT be bundled (provided by glibc/system)
SYSTEM_LIBS=(
    # Core glibc - exact matches (ABI-stable since 1997)
    ld-linux-*.so.2
    libatomic.so.1
    libc.so.6
    libcrypt.so.1
    libdl.so.2
    libgcc_s.so.1
    libm.so.6
    libpthread.so.0
    librt.so.1
    libstdc++.so.6
    libutil.so.1
    linux-vdso.so.1

    # Common system libraries - glob patterns for versioned sonames
    libbz2.so.*
    libexpat.so.*
    libffi.so.*
    liblzma.so.*
    libnsl.so.*
    libresolv.so.*
    libz.so.*

    # X11 / graphics stack
    libX11.so.*
    libXau.so.*
    libxcb.so.*
    libXcomposite.so.*
    libXcursor.so.*
    libXdamage.so.*
    libXdmcp.so.*
    libXext.so.*
    libXfixes.so.*
    libXft.so.*
    libXi.so.*
    libXinerama.so.*
    libXrandr.so.*
    libXrender.so.*
    libXss.so.*

    # OpenSSL / crypto
    libcrypto.so.*
    libssl.so.*

    # Tcl/Tk
    libtcl*.so.*
    libtk*.so.*

    # Image / font libraries
    libfontconfig.so.*
    libfreetype.so.*
    libpng*.so.*

    # Database / data
    libdb-*.so.*
    libgdbm.so.*
    libsqlite3.so.*

    # ncurses / readline
    libncurses*.so.*
    libpanelw.so.*
    libreadline.so.*
    libtinfo.so.*

    # Compression / encoding
    libbrotli*.so.*
    libbsd.so.*
    libmd.so.*

    # Compiler runtime family (from system GCC, not bundled .libs/)
    libgfortran.so.*
    libgomp.so.*
    libquadmath.so.*

    # Misc
    libBLT*.so.*
)

# glibc core: must always come from the target's own libc and loader. Mixing a
# bundled copy with the system ld.so is unsafe, so --bundle-include cannot
# override these.
NEVER_BUNDLE_LIBS=(
    ld-linux*.so.*
    ld64.so.*
    libanl.so.1
    libc.so.6
    libdl.so.2
    libm.so.6
    libmvec.so.1
    libnss_*.so.*
    libpthread.so.0
    libresolv.so.2
    librt.so.1
    libthread_db.so.1
    libutil.so.1
    linux-gate.so.*
    linux-vdso.so.*
)

# Function: is_never_bundled
# Description: True for glibc core libraries that must never be bundled.
# Arguments: $1 - soname
is_never_bundled() {
    local soname="$1" lib
    for lib in "${NEVER_BUNDLE_LIBS[@]}"; do
        [[ "$soname" == $lib ]] && return 0
    done
    return 1
}

# Function: is_bundle_included
# Description: True if the soname matches a --bundle-include entry.
# Arguments: $1 - soname
is_bundle_included() {
    local soname="$1" pat
    ((${#INCLUDE_LIBS[@]} > 0)) || return 1
    for pat in "${INCLUDE_LIBS[@]}"; do
        if [[ "$pat" == /* ]]; then
            # Absolute path: match by soname (basename), since the caller
            # only knows sonames. resolve_included_libs handles the file
            # lookup separately.
            [[ "$soname" == "$(basename "$pat")" ]] && return 0
        else
            [[ "$soname" == $pat ]] && return 0
        fi
    done
    return 1
}

# Function: is_system_library
# Description: Checks if a library soname is a system library that should not be bundled.
#              Precedence: glibc core (never bundled) > --bundle-include >
#              built-in SYSTEM_LIBS > --bundle-exclude.
# Arguments: $1 - soname
is_system_library() {
    local soname="$1"
    local lib
    is_never_bundled "$soname" && return 0
    is_bundle_included "$soname" && return 1
    for lib in "${SYSTEM_LIBS[@]}"; do
        [[ "$soname" == $lib ]] && return 0
    done
    [[ -n "$BUNDLE_EXCLUDE_REGEX" && "$soname" =~ $BUNDLE_EXCLUDE_REGEX ]] && return 0
    return 1
}

# Function: get_soname
# Description: Extracts the SONAME from an ELF shared object.
# Arguments: $1 - path to ELF file
get_soname() {
    local file="$1"
    command -v objdump > /dev/null 2>&1 || return 1
    objdump -p "$file" 2> /dev/null | awk '/SONAME/ {print $2; exit}'
}

# Function: compute_rpath
# Description: Computes the relative rpath from an ELF file to the embedded lib directory.
# Arguments: $1 - path to ELF file, $2 - path to embed directory
compute_rpath() {
    local elf="$1" embed_dir="$2"
    local elf_dir
    elf_dir=$(dirname "$(readlink -f "$elf")")
    local rel
    rel=$(realpath --relative-to="$elf_dir" "$embed_dir/lib" 2> /dev/null) || return 1
    printf '$ORIGIN/%s' "$rel"
}

# Function: _patch_single_elf
# Description: Patches a single ELF file's rpath. Existing rpath entries are
#              preserved but de-duplicated, so repeated runs do not grow the
#              rpath string unboundedly.
# Arguments: $1 - ELF file path, $2 - rpath value
_patch_single_elf() {
    local elf="$1" rpath="$2"
    local current_rpath
    current_rpath=$(patchelf --print-rpath "$elf" 2> /dev/null || echo "")
    case ":$current_rpath:" in *":$rpath:"*) return 0 ;; esac

    # Rebuild rpath as: new entry first, then existing entries, dropping any
    # duplicate of the new entry and any empty components. This keeps the
    # string stable across repeated invocations.
    if [[ -n "$current_rpath" ]]; then
        local old_ifs="$IFS" entry
        local -a kept=()
        IFS=':'
        for entry in $current_rpath; do
            [[ -n "$entry" && "$entry" != "$rpath" ]] && kept+=("$entry")
        done
        IFS="$old_ifs"
        if ((${#kept[@]} > 0)); then
            local joined
            joined=$(
                IFS=':'
                printf '%s' "${kept[*]}"
            )
            rpath="$rpath:$joined"
        fi
    fi

    if $DRY_RUN; then
        log_test "would: patchelf --set-rpath '$rpath' $elf"
        CHANGE_COUNT=$((CHANGE_COUNT + 1))
        return 0
    fi

    if patchelf --set-rpath "$rpath" "$elf"; then
        log_info "rpath patched: $elf  ->  $rpath"
        CHANGE_COUNT=$((CHANGE_COUNT + 1))
    else
        log_err "patchelf failed on $elf"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Function: find_all_venv_elfs
# Description: Finds all ELF files in the venv. Used both for rpath patching
#              and as the seed set for runtime-dependency scanning.
# Arguments: (none)
find_all_venv_elfs() {
    local -a elfs=()

    # Python interpreter(s)
    for f in "$VENV_PATH"/bin/python3* "$VENV_PATH"/bin/python3; do
        [[ -f "$f" && ! -L "$f" && -x "$f" ]] && elfs+=("$f")
    done

    # All executable files in the venv (covers .so and other ELF binaries)
    while IFS= read -r -d '' f; do
        [[ -L "$f" ]] && continue
        elfs+=("$f")
    done < <(find "$VENV_PATH" -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) -print0 2> /dev/null)

    # Filter to actual ELF files and deduplicate
    local -a real_elfs=()
    local f magic
    local -A seen=()
    for f in "${elfs[@]}"; do
        [[ -n "${seen[$f]:-}" ]] && continue
        seen[$f]=1
        # Single od invocation reads only the 4-byte magic; faster and
        # consistent with is_elf_file/elf_arch_tag elsewhere in this script.
        magic=$(od -An -tx1 -N4 -- "$f" 2> /dev/null | tr -d ' \n')
        [[ "$magic" == "7f454c46" ]] && real_elfs+=("$f")
    done

    # Emit nothing for an empty result so the caller's mapfile sees an empty
    # array rather than a single blank line.
    ((${#real_elfs[@]} > 0)) && printf '%s\n' "${real_elfs[@]}"
    return 0
}

# Function: collect_runtime_deps
# Description: Recursively collects all non-system shared library dependencies.
# Arguments: $@ - list of ELF files to scan
collect_runtime_deps() {
    local -a queue=("$@")
    local -A visited=()

    while ((${#queue[@]} > 0)); do
        local elf="${queue[0]}"
        queue=("${queue[@]:1}")
        [[ -n "${visited[$elf]:-}" ]] && continue
        visited[$elf]=1

        [[ -f "$elf" && ! -L "$elf" ]] || continue
        local magic
        magic=$(od -An -tx1 -N4 -- "$elf" 2> /dev/null | tr -d ' \n')
        [[ "$magic" == "7f454c46" ]] || continue

        local dep_line soname path
        # ldd -r repeats the same '=>' lines as plain ldd; the visited set
        # above deduplicates them, so scanning both misses nothing.
        # Regex must be in a variable to avoid bash parsing > in [[ =~ ]]
        local ldd_regex='^[[:space:]]*([^[:space:]]+)[[:space:]]+=>[[:space:]]+([^[:space:]]+)[[:space:]]+\(0x'
        while IFS= read -r dep_line; do
            # Parse: "libfoo.so.1 => /path/to/libfoo.so.1 (0x...)"
            [[ "$dep_line" =~ $ldd_regex ]] || continue
            soname="${BASH_REMATCH[1]}"
            path="${BASH_REMATCH[2]}"
            [[ "$path" == "not found" ]] && continue
            is_system_library "$soname" && continue

            local realpath
            realpath=$(readlink -f "$path")
            # Libraries already inside the venv (wheel .libs/ dirs, or a previous
            # bundling pass in .python/lib) are found through their own RUNPATH;
            # copying them again would only duplicate them.
            [[ "$realpath" == "$VENV_PATH"/* ]] && continue
            [[ -z "${RUNTIME_DEPS[$soname]:-}" ]] && RUNTIME_DEPS[$soname]="$realpath"

            queue+=("$realpath")
        done < <(
            ldd "$elf" 2> /dev/null
            ldd -r "$elf" 2> /dev/null
        )
    done
}

# Function: copy_runtime_deps
# Description: Copies collected runtime dependencies to the embedded lib directory.
# Arguments: (none)
copy_runtime_deps() {
    local soname path
    for soname in "${!RUNTIME_DEPS[@]}"; do
        path="${RUNTIME_DEPS[$soname]}"
        [[ -f "$path" ]] || {
            log_warn "dependency not found: $soname ($path)"
            continue
        }

        log_info "bundling runtime dep: $soname  ->  $EMBED_DIR/lib/"
        if $DRY_RUN; then
            log_test "would: cp -af $path $EMBED_DIR/lib/"
        else
            mkdir -p "$EMBED_DIR/lib"
            cp -af "$path" "$EMBED_DIR/lib/"
            # Copy every symlink in the source directory that resolves to the
            # same file. Using -samefile (instead of -lname "$base") catches
            # multi-hop chains such as libfoo.so -> libfoo.so.1 -> libfoo.so.1.2.3
            # whose intermediate links do not point at $base directly.
            local src_dir base
            src_dir=$(dirname "$path")
            base=$(basename "$path")
            find "$src_dir" -maxdepth 1 -type l -samefile "$path" \
                -exec cp -af {} "$EMBED_DIR/lib/" \; 2> /dev/null || true
            # Make sure the name other libraries ask for (the soname) resolves,
            # e.g. when SONAME != file name or the symlink chain has several hops.
            if [[ ! -e "$EMBED_DIR/lib/$soname" ]]; then
                ln -sfn -- "$base" "$EMBED_DIR/lib/$soname"
            fi
        fi
    done
}

# Function: is_elf_file
# Description: True if the argument is a file (or symlink to one) starting
#              with the ELF magic.
# Arguments: $1 - path
is_elf_file() {
    local f="$1" magic
    [[ -f "$f" ]] || return 1
    magic=$(od -An -tx1 -N4 -- "$f" 2> /dev/null | tr -d ' \n')
    [[ "$magic" == "7f454c46" ]]
}

# Function: elf_arch_tag
# Description: Prints "<EI_CLASS>:<e_machine>" so libraries of another word
#              size or architecture (e.g. 32-bit multilib) can be told apart.
# Arguments: $1 - ELF file
elf_arch_tag() {
    local f="$1" cls mach
    [[ -r "$f" ]] || return 1
    cls=$(od -An -tx1 -j4 -N1 -- "$f" 2> /dev/null | tr -d ' \n')
    mach=$(od -An -tx1 -j18 -N2 -- "$f" 2> /dev/null | tr -d ' \n')
    [[ -n "$cls" && -n "$mach" ]] || return 1
    printf '%s:%s' "$cls" "$mach"
}

# Function: register_runtime_dep
# Description: Records a library for copy_runtime_deps (same bookkeeping as the
#              ldd-driven path in collect_runtime_deps).
# Arguments: $1 - soname (name other libraries look it up by), $2 - path
register_runtime_dep() {
    local soname="$1" path="$2" real
    real=$(readlink -f "$path" 2> /dev/null) || return 1
    [[ -f "$real" ]] || return 1
    if [[ -z "${RUNTIME_DEPS[$soname]:-}" ]]; then RUNTIME_DEPS[$soname]="$real"; fi
    return 0
}

# Function: find_system_libs
# Description: Finds shared libraries on this machine whose name matches a glob.
#              Uses the ld.so cache (ldconfig -p) and falls back to scanning the
#              standard library directories. Only libraries with the same ELF
#              class/machine as the venv's Python are returned. Prints one
#              "name<TAB>path" line per distinct name.
# Arguments: $1 - soname glob, $2 - reference arch tag (may be empty)
find_system_libs() {
    local pat="$1" ref_arch="${2:-}"
    local -a hits=()
    local line name path real d cand ldc="" hit
    local -A seen=()
    local ldc_regex='^[[:space:]]*([^[:space:]]+)[[:space:]]+\(.*\)[[:space:]]+=>[[:space:]]+(.+)$'

    ldc=$(command -v ldconfig 2> /dev/null || true)
    if [[ -z "$ldc" && -x /sbin/ldconfig ]]; then ldc=/sbin/ldconfig; fi

    if [[ -n "$ldc" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ $ldc_regex ]]; then
                name="${BASH_REMATCH[1]}"
                path="${BASH_REMATCH[2]}"
                if [[ "$name" == $pat ]]; then hits+=("$name"$'\t'"$path"); fi
            fi
        done < <("$ldc" -p 2> /dev/null || true)
    fi

    if ((${#hits[@]} == 0)); then
        for d in /lib /lib64 /usr/lib /usr/lib64 /usr/local/lib /lib/*-linux-gnu /usr/lib/*-linux-gnu; do
            [[ -d "$d" ]] || continue
            while IFS= read -r -d '' cand; do
                hits+=("$(basename "$cand")"$'\t'"$cand")
            done < <(find "$d" -maxdepth 1 \( -type f -o -type l \) -name "$pat" -print0 2> /dev/null)
        done
    fi

    ((${#hits[@]} > 0)) || return 0
    for hit in "${hits[@]}"; do
        name="${hit%%$'\t'*}"
        path="${hit#*$'\t'}"
        real=$(readlink -f "$path" 2> /dev/null) || continue
        is_elf_file "$real" || continue
        if [[ -n "$ref_arch" && "$(elf_arch_tag "$real")" != "$ref_arch" ]]; then continue; fi
        if [[ -n "${seen[$name]:-}" ]]; then continue; fi
        seen[$name]=1
        printf '%s\t%s\n' "$name" "$path"
    done
}

# Function: resolve_included_libs
# Description: Makes sure every --bundle-include entry ends up in RUNTIME_DEPS.
#              Entries that ldd already reported (the venv links against them)
#              were picked up by collect_runtime_deps, because is_system_library
#              lets them through. Everything else is looked up here: absolute
#              paths are taken as-is, names/globs are resolved on the system.
#              This covers libraries the venv only loads via dlopen()/ctypes.
#              Newly found files are queued in INCLUDE_EXTRA_ELFS so their own
#              dependencies get scanned too.
# Arguments: (none)
resolve_included_libs() {
    local entry key name path real ref_elf ref_arch="" found matched is_glob
    ref_elf=$(readlink -f "$VENV_PATH/bin/python3" 2> /dev/null || true)
    if [[ -n "$ref_elf" ]]; then ref_arch=$(elf_arch_tag "$ref_elf" || true); fi

    for entry in "${INCLUDE_LIBS[@]}"; do
        # --- absolute path -------------------------------------------------
        if [[ "$entry" == /* ]]; then
            if is_elf_file "$entry"; then
                real=$(readlink -f "$entry")
                name=$(get_soname "$real" 2> /dev/null || true)
                [[ -n "$name" ]] || name=$(basename "$entry")
                if is_never_bundled "$name"; then
                    log_warn "--bundle-include: refusing to bundle glibc core library: $entry"
                elif register_runtime_dep "$name" "$real"; then
                    INCLUDE_EXTRA_ELFS+=("$real")
                fi
            else
                log_warn "--bundle-include: not an ELF shared object: $entry"
            fi
            continue
        fi

        # --- soname / glob -------------------------------------------------
        is_glob=false
        case "$entry" in *'*'* | *'?'* | *'['*) is_glob=true ;; esac
        if ! $is_glob && is_never_bundled "$entry"; then
            log_warn "--bundle-include: refusing to bundle glibc core library: $entry"
            continue
        fi

        found=false
        for key in "${!RUNTIME_DEPS[@]}"; do
            if [[ "$key" == $entry ]]; then
                found=true
                break
            fi
        done
        if $found; then continue; fi

        matched=false
        while IFS=$'\t' read -r name path; do
            [[ -n "$name" ]] || continue
            if is_never_bundled "$name"; then continue; fi
            if register_runtime_dep "$name" "$path"; then
                INCLUDE_EXTRA_ELFS+=("$(readlink -f "$path")")
                matched=true
            fi
        done < <(find_system_libs "$entry" "$ref_arch")
        if ! $matched; then
            log_warn "--bundle-include: no library matching '$entry' found on this system"
        fi
    done
}

# Function: bundle_runtime_libs
# Description: Collects the venv's non-system shared-library dependencies plus
#              everything requested with --bundle-include, and copies them into
#              $EMBED_DIR/lib. Safe to run again on an already-embedded venv
#              (libraries already in the venv are skipped).
# Arguments: (none)
bundle_runtime_libs() {
    log_info "collecting runtime dependencies..."
    local -a all_elfs=()
    mapfile -t all_elfs < <(find_all_venv_elfs)
    if ((${#all_elfs[@]} > 0)); then
        collect_runtime_deps "${all_elfs[@]}"
    fi
    if ((${#INCLUDE_LIBS[@]} > 0)); then
        resolve_included_libs
        if ((${#INCLUDE_EXTRA_ELFS[@]} > 0)); then
            collect_runtime_deps "${INCLUDE_EXTRA_ELFS[@]}"
        fi
    fi
    copy_runtime_deps
}

# Function: patch_all_elf_rpath
# Description: Patches the ELF rpath of all ELF files in the venv to use the embedded libs.
# Arguments: (none)
patch_all_elf_rpath() {
    $NO_PATCHELF && {
        log_note "skipping rpath patch (--no-patchelf)"
        return 0
    }
    command -v patchelf > /dev/null 2>&1 || {
        log_warn "patchelf not found; cannot patch ELF rpath."
        return 1
    }

    local elf rpath magic
    # Patch Python binaries with static rpath
    for elf in "$VENV_PATH"/bin/python3.* "$VENV_PATH"/bin/python3; do
        [[ -f "$elf" && ! -L "$elf" && -x "$elf" ]] || continue
        magic=$(od -An -tx1 -N4 -- "$elf" 2> /dev/null | tr -d ' \n')
        [[ "$magic" == "7f454c46" ]] || continue
        rpath='$ORIGIN/../.python/lib'
        _patch_single_elf "$elf" "$rpath"
    done

    # Patch all other ELF files (extension modules, etc.) with dynamic rpath
    # Includes .python/ (stdlib lib-dynload modules and bundled libs) so their
    # own dependencies resolve via $ORIGIN. Skips symlinks and non-ELF files.
    # Files are matched by exec bit OR .so name, since e.g. Debian/Ubuntu ship
    # lib-dynload/*.so as mode 644.
    while IFS= read -r -d '' elf; do
        [[ -L "$elf" ]] && continue
        magic=$(od -An -tx1 -N4 -- "$elf" 2> /dev/null | tr -d ' \n')
        [[ "$magic" == "7f454c46" ]] || continue
        rpath=$(compute_rpath "$elf" "$EMBED_DIR") || continue
        _patch_single_elf "$elf" "$rpath"
    done < <(find "$VENV_PATH" -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) -print0 2> /dev/null)
}

# Function: embed_base_python
# Description: Orchestrates the embedding of the base Python environment.
# Arguments: (none)
embed_base_python() {
    [[ -n "$BASE_PYTHON" ]] || {
        log_warn "no base Python to embed"
        return 1
    }
    log_info "embedding base Python into $EMBED_DIR"
    if ! $DRY_RUN; then
        mkdir -p "$EMBED_DIR/bin" "$EMBED_DIR/lib"
        ln -sfn "../../bin/python3" "$EMBED_DIR/bin/python3" 2> /dev/null || true
    fi
    local embed_failed=false
    if ! $NO_STDLIB && ! copy_stdlib; then embed_failed=true; fi
    if ! $NO_LIBPYTHON && ! copy_libpython; then embed_failed=true; fi

    if $BUNDLE_RUNTIME; then
        bundle_runtime_libs
    fi

    patch_all_elf_rpath || true
    if $embed_failed && [[ "$EMBED_MODE" == "force" ]]; then
        log_err "embedding failed; aborting (--embed was explicit)"
        exit 2
    fi
    return 0
}

# Hard-fail early if --embed was requested but there is nothing usable.
if [[ "$EMBED_MODE" == "force" && -z "$BASE_PYTHON" ]]; then
    log_err "--embed requested but no usable base Python found"
    log_err "Provide --base-python DIR, or run this script on the source machine."
    exit 2
fi

if should_embed; then
    embed_base_python
elif [[ -d "$EMBED_DIR/lib/python$PYVER" ]]; then
    log_note "embedded base Python already present at $EMBED_DIR"
    # Re-run on an already-embedded venv: top up the bundled libraries
    # (e.g. after adding --bundle-include, or after pip-installing more packages).
    if $BUNDLE_RUNTIME && [[ "$EMBED_MODE" != "skip" ]]; then
        log_info "topping up bundled runtime libraries"
        bundle_runtime_libs
        patch_all_elf_rpath || true
    fi
elif [[ -z "$BASE_PYTHON" ]]; then
    log_warn "base Python not available and no embedded copy found."
    log_warn "The venv may not run on a machine without a system Python."
fi

# ==============================================================================
# PATH REWRITING ENGINE
# ==============================================================================

HAVE_PERL=false
command -v perl > /dev/null 2>&1 && HAVE_PERL=true

# Function: rewrite_path
# Description: Replaces occurrences of the old path with the new path in a file.
# Arguments: $1 - file, $2 - old path, $3 - new path
rewrite_path() {
    local file="$1" old="$2" new="$3"
    [[ -f "$file" && -n "$old" && "$old" != "$new" ]] || return 0
    grep -qF -- "$old" "$file" 2> /dev/null || return 0

    if $DRY_RUN; then
        log_test "would rewrite '$old' -> '$new' in: $file"
        CHANGE_COUNT=$((CHANGE_COUNT + 1))
        return 0
    fi

    if $HAVE_PERL; then
        if OLD="$old" NEW="$new" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"; then
            log_info "rewrote path in: $file"
            CHANGE_COUNT=$((CHANGE_COUNT + 1))
        else
            log_err "failed to rewrite: $file"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        # sed fallback. Escape the pattern as a POSIX BRE (metacharacters used
        # by paths are rare, but this keeps the substitution literal), and
        # escape the replacement for '&' and the '|' delimiter.
        local o="${old//\\/\\\\}"
        o="${o//./\\.}"
        o="${o//[/\\[}"
        o="${o//]/\\]}"
        o="${o//^/\\^}"
        o="${o//\$/\\$}"
        o="${o//\*/\\*}"
        o="${o//|/\\|}"
        local n="${new//\\/\\\\}"
        n="${n//&/\\&}"
        n="${n//|/\\|}"
        local tmp
        tmp=$(mktemp "${file}.XXXXXX")
        if sed "s|$o|$n|g" "$file" > "$tmp"; then
            chmod --reference="$file" "$tmp" 2> /dev/null || true
            if mv "$tmp" "$file"; then
                log_info "rewrote path in: $file"
                CHANGE_COUNT=$((CHANGE_COUNT + 1))
            else
                rm -f "$tmp"
                log_err "failed to rewrite: $file"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            rm -f "$tmp"
            log_err "failed to rewrite: $file"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    fi
}

# Function: rewrite_shebang
# Description: Specifically fixes the first line (shebang) of scripts.
# Arguments: $1 - file, $2 - old path, $3 - new path
rewrite_shebang() {
    local file="$1" old="$2" new="$3"
    [[ -f "$file" && ! -L "$file" ]] || return 0
    local first=""
    IFS= read -r first < "$file" 2> /dev/null || return 0
    [[ "$first" == '#!'* ]] || return 0
    [[ -n "$old" && "$first" == *"$old"* ]] || return 0

    local esc_old="${old//\\/\\\\}"
    esc_old="${esc_old//\*/\\*}"
    esc_old="${esc_old//\?/\\?}"
    esc_old="${esc_old//\[/\\[}"
    local nl="${first//$esc_old/$new}"

    if $DRY_RUN; then
        log_test "would rewrite shebang in: $file"
        log_test "    $first  ->  $nl"
        CHANGE_COUNT=$((CHANGE_COUNT + 1))
        return 0
    fi

    local tmp
    tmp=$(mktemp "${file}.XXXXXX")
    {
        printf '%s\n' "$nl"
        tail -n +2 -- "$file"
    } > "$tmp"
    chmod --reference="$file" "$tmp" 2> /dev/null || chmod 0755 "$tmp"
    if mv "$tmp" "$file"; then
        log_info "shebang fixed: $file"
        CHANGE_COUNT=$((CHANGE_COUNT + 1))
    else
        rm -f "$tmp"
        log_err "failed to rewrite shebang: $file"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Execute path rewriting across the venv.
if [[ -n "$ORIGINAL_PATH" ]]; then
    for f in activate activate.csh activate.fish Activate.ps1; do
        rewrite_path "$VENV_PATH/bin/$f" "$ORIGINAL_PATH" "$NEW_PATH"
    done

    while IFS= read -r -d '' f; do
        rewrite_shebang "$f" "$ORIGINAL_PATH" "$NEW_PATH"
    done < <(find "$VENV_PATH/bin" -maxdepth 1 -type f -print0)

    if [[ -f "$VENV_PATH/pyvenv.cfg" ]]; then
        rewrite_path "$VENV_PATH/pyvenv.cfg" "$ORIGINAL_PATH" "$NEW_PATH"
    fi

    if [[ -d "$VENV_PATH/lib" ]]; then
        while IFS= read -r -d '' f; do
            rewrite_path "$f" "$ORIGINAL_PATH" "$NEW_PATH"
        done < <(find "$VENV_PATH/lib" -type f \( -name '*.pth' -o -name 'direct_url.json' \) -print0 2> /dev/null || true)
    fi

    while IFS= read -r -d '' f; do
        [[ -L "$f" ]] || continue
        symlink_target=$(readlink "$f")
        if [[ "$symlink_target" == "$ORIGINAL_PATH" ]]; then
            new_target="$NEW_PATH"
        else
            rest="${symlink_target#"$ORIGINAL_PATH"/}"
            # Prefix NOT removed (rest unchanged) ⇒ symlink is not under the original
            # venv, e.g. a sibling dir like "venv_backup" must not false-match a prefix
            # of "venv". Skip it. ([[ X ]] || continue runs on X == false.)
            [[ "$rest" != "$symlink_target" ]] || continue
            new_target="$NEW_PATH/$rest"
        fi
        # Skip the syscall (and the change counter) when the link is already
        # pointing at the desired target.
        if [[ "$symlink_target" == "$new_target" ]]; then
            continue
        fi
        if $DRY_RUN; then
            log_test "would retarget symlink $f -> $new_target"
            CHANGE_COUNT=$((CHANGE_COUNT + 1))
        else
            if ln -sfn -- "$new_target" "$f"; then
                log_info "symlink retargeted: $f -> $new_target"
                CHANGE_COUNT=$((CHANGE_COUNT + 1))
            else
                log_err "failed to retarget symlink: $f"
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        fi
    done < <(find "$VENV_PATH" -xdev -type l -print0 2> /dev/null || true)
fi

# Repoint pyvenv.cfg's home= to the embedded base if applicable.
if [[ -d "$EMBED_DIR/lib/python$PYVER" ]]; then
    desired_home="$EMBED_DIR/bin"
    current_home=$(sed -n 's|^[[:space:]]*home[[:space:]]*=[[:space:]]*||p' \
        "$VENV_PATH/pyvenv.cfg" | head -n1)
    if [[ "$current_home" != "$desired_home" ]]; then
        if $DRY_RUN; then
            log_test "would set 'home = $desired_home' in pyvenv.cfg (was: $current_home)"
            CHANGE_COUNT=$((CHANGE_COUNT + 1))
        else
            if $HAVE_PERL; then
                OLD="$current_home" NEW="$desired_home" perl -pi -e \
                    's{^(\s*home\s*=\s*).*$}{$1$ENV{NEW}}' "$VENV_PATH/pyvenv.cfg"
            else
                esc_home="${desired_home//\\/\\\\}"
                esc_home="${esc_home//&/\\&}"
                esc_home="${esc_home//|/\\|}"
                tmp=$(mktemp "${VENV_PATH}/pyvenv.cfg.XXXXXX")
                if sed "s|^[[:space:]]*home[[:space:]]*=.*|home = $esc_home|" \
                    "$VENV_PATH/pyvenv.cfg" > "$tmp"; then
                    chmod --reference="$VENV_PATH/pyvenv.cfg" "$tmp" 2> /dev/null || true
                    mv "$tmp" "$VENV_PATH/pyvenv.cfg"
                else
                    rm -f "$tmp"
                    log_err "failed to rewrite pyvenv.cfg"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                fi
            fi
            log_info "pyvenv.cfg: home -> $desired_home"
            CHANGE_COUNT=$((CHANGE_COUNT + 1))
        fi
    fi
fi

# ==============================================================================
# VERIFICATION & CLEANUP
# ==============================================================================

# Remove bytecode to ensure fresh regeneration on the new system.
# The scan covers the whole venv — in particular the embedded stdlib under
# .python/lib/pythonX.Y/, whose __pycache__ directories are copied verbatim
# by copy_stdlib and would otherwise leak into the archive.
if ! $KEEP_PYCACHE; then
    if $DRY_RUN; then
        log_note "would remove __pycache__ directories"
    else
        if find "$VENV_PATH" -type d -name '__pycache__' -prune -exec rm -rf {} + 2> /dev/null; then
            log_note "removed __pycache__ (regenerates on first import)"
        else
            log_warn "some __pycache__ directories could not be removed"
        fi
    fi
fi

# Final verification of venv health.
echo
if [[ -x "$VENV_PATH/bin/python3" ]]; then
    if out=$("$VENV_PATH/bin/python3" -c \
        'import sys; print("%s prefix=%s base=%s" % (sys.version.split()[0], sys.prefix, sys.base_prefix))' 2>&1); then
        log_info "venv python OK: $out"
    else
        log_warn "venv python failed to run:"
        printf '    %s\n' "$out" >&2
    fi

    if command -v ldd > /dev/null 2>&1; then
        if ldd "$VENV_PATH/bin/python3" 2> /dev/null | grep -q 'not found'; then
            log_warn "missing shared libraries for $VENV_PATH/bin/python3:"
            ldd "$VENV_PATH/bin/python3" 2> /dev/null | grep 'not found' >&2 || true
        fi
    fi
fi

if [[ -n "$ORIGINAL_PATH" ]]; then
    leftovers=$(grep -rlF -- "$ORIGINAL_PATH" "$VENV_PATH" 2> /dev/null | head -n20 || true)
    [[ -n "$leftovers" ]] && {
        log_warn "files still containing '$ORIGINAL_PATH':"
        printf '    %s\n' "$leftovers" >&2
    }
fi

# ==============================================================================
# PACKAGING (optional)
# ==============================================================================

# Function: compress_venv
# Description: Creates a gzipped tarball of the venv directory, using the
#              path set by -o/--output, or defaulting to <venv-name>.tar.gz
#              in the current working directory. The archive is written to
#              a temporary file and renamed on success, so a failed run
#              never leaves a partial archive under the final name.
#              When --keep-pycache is not set, __pycache__ directories are
#              excluded from the archive as well, mirroring the on-disk
#              cleanup and guaranteeing a cache-free artifact.
# Arguments: (none)
compress_venv() {
    local archive="" parent="" base="" size="" tmp_archive=""
    local excludes=()

    if [[ -n "$COMPRESS_FILE" ]]; then
        archive="$COMPRESS_FILE"
    else
        archive="$(basename "$VENV_PATH").tar.gz"
    fi

    case "$archive" in
        /*) ;;
        *) archive="$(pwd -P)/$archive" ;;
    esac

    # Refuse to write the archive into an existing directory: tar would fail
    # mid-run with a confusing "Is a directory" error. Mirror the guard in
    # build_installer's self-extract path and bundle_scripts.sh's output path.
    if [[ -d "$archive" ]]; then
        log_err "archive output path is a directory: $archive"
        log_err "Give a file name instead, or pass a non-existent path."
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    if [[ -e "$archive" && "$FORCE" != true ]]; then
        log_err "output already exists: $archive (use --force to overwrite)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    parent="$(dirname "$VENV_PATH")"
    base="$(basename "$VENV_PATH")"

    # Mirror the on-disk __pycache__ policy: by default, exclude them from
    # the archive too; --keep-pycache turns both off together.
    if ! $KEEP_PYCACHE; then
        excludes+=(--exclude='__pycache__')
    fi

    # If the archive would land inside the venv itself, exclude it so we
    # don't try to tar a file we're still writing.
    if [[ "$archive" == "$VENV_PATH"/* ]]; then
        excludes+=(--exclude="${archive#$VENV_PATH/}")
    fi

    if $DRY_RUN; then
        log_test "would create archive: $archive"
        if ((${#excludes[@]} > 0)); then
            log_test "    tar -czf '$archive' ${excludes[*]} -C '$parent' '$base'"
        else
            log_test "    tar -czf '$archive' -C '$parent' '$base'"
        fi
        COMPRESS_RESULT="$archive"
        return 0
    fi

    log_info "creating archive: $archive"
    tmp_archive="${archive}.tmp.$$"

    local tar_ok=false
    if ((${#excludes[@]} > 0)); then
        $TAR_BIN -czf "$tmp_archive" "${excludes[@]}" -C "$parent" "$base" && tar_ok=true
    else
        $TAR_BIN -czf "$tmp_archive" -C "$parent" "$base" && tar_ok=true
    fi

    if $tar_ok; then
        mv -f -- "$tmp_archive" "$archive"
        size="$(du -h "$archive" 2> /dev/null | awk 'NR==1 {print $1}')"
        log_info "archive created: $archive${size:+ ($size)}"
        COMPRESS_RESULT="$archive"
    else
        rm -f -- "$tmp_archive"
        log_err "failed to create archive: $archive"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

if $COMPRESS; then
    compress_venv
fi

# Function: build_installer
# Description: Wraps the archive produced by compress_venv, plus an embedded
#              copy of this script, into a single self-extracting .run file.
#              Running the .run file on the target machine asks for (or
#              accepts as $1) a destination directory, extracts the venv
#              there, then automatically runs the embedded bundle_venv.sh
#              against that destination so paths are rewritten in one step.
# Arguments: $1 - tarball path, $2 - venv basename
build_installer() {
    local tarball="$1" venv_base="$2" out=""

    if [[ -n "$INSTALL_FILE" ]]; then
        out="$INSTALL_FILE"
    else
        case "$tarball" in
            *.tar.gz) out="${tarball%.tar.gz}.run" ;;
            *.tgz) out="${tarball%.tgz}.run" ;;
            *) out="${tarball}.run" ;;
        esac
    fi

    case "$out" in
        /*) ;;
        *) out="$(pwd -P)/$out" ;;
    esac

    # Same trap as bundle_scripts.sh: mv would move the finished installer *into*
    # an existing directory named by --self-extract, leaving a directory where a
    # runnable file was promised. Refuse rather than silently misplace it.
    if [[ -d "$out" ]]; then
        log_err "installer path is a directory: $out"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    if $DRY_RUN; then
        log_test "would build self-extracting installer: $out"
        log_test "    embedding: $tarball + $(basename "$SELF_SCRIPT")"
        INSTALLER_RESULT="$out"
        return 0
    fi

    if [[ ! -f "$SELF_SCRIPT" ]]; then
        log_err "cannot locate this script's own source file; --self-extract needs to embed it"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    command -v base64 > /dev/null 2>&1 || {
        log_err "base64 not found; required to build a --self-extract installer"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    }

    log_info "building self-extracting installer: $out"

    local tmp_stub fixvenv_b64
    tmp_stub=$(mktemp "${out}.XXXXXX")
    fixvenv_b64=$(base64 < "$SELF_SCRIPT")

    {
        cat << STUB
#!/usr/bin/env bash
# Self-extracting venv installer, generated by bundle_venv.sh v${SCRIPT_VERSION}
# Extracts the embedded venv archive to a destination you choose, then
# automatically runs the embedded bundle_venv.sh against it to fix paths.
set -euo pipefail

VENV_BASENAME="${venv_base}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

RED=\$'\033[0;31m'; GREEN=\$'\033[0;32m'; CYAN=\$'\033[0;36m'; BOLD=\$'\033[1m'; RESET=\$'\033[0m'

log_info() { printf '%b[INFO]%b %s\n' "\$GREEN" "\$RESET" "\$*"; }
log_err()  { printf '%b[FAIL]%b %s\n' "\$RED" "\$RESET" "\$*" >&2; }

echo
echo -e "\${BOLD}\${CYAN}Self-extracting venv installer\${RESET} (built \$BUILD_DATE)"
echo -e "\${CYAN}----------------------------------------------------------------------\${RESET}"

if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" ]]; then
    echo "Usage: \$(basename "\$0") [DEST_DIR] [extra bundle_venv.sh options...]"
    echo "  DEST_DIR   Where to extract and fix the venv (prompted for if omitted)"
    exit 0
fi

SELF="\$(cd "\$(dirname "\$0")" && pwd -P)/\$(basename "\$0")"
DEST="\${1:-}"

if [[ -n "\$DEST" && "\$DEST" != -* ]]; then
    shift
else
    read -r -p "Destination directory for the venv: " DEST
fi

[[ -n "\$DEST" ]] || { log_err "no destination given"; exit 2; }
mkdir -p -- "\$DEST"
DEST="\$(cd "\$DEST" && pwd -P)"

if [[ -e "\$DEST/\$VENV_BASENAME" ]]; then
    log_err "destination already exists: \$DEST/\$VENV_BASENAME"
    log_err "remove it first or choose a different destination"
    exit 2
fi

TMPDIR="\$(mktemp -d)"
trap 'rm -rf "\$TMPDIR"' EXIT

PAYLOAD_LINE=\$(grep -an -m1 '^__PAYLOAD_BELOW__[[:space:]]*$' "\$SELF" 2>/dev/null | cut -d: -f1 || true)
[[ -n "\$PAYLOAD_LINE" ]] || { log_err "corrupt installer: payload marker not found"; exit 2; }
tail -n +\$((PAYLOAD_LINE + 1)) "\$SELF" > "\$TMPDIR/venv.tar.gz"

    log_info "extracting venv into: \$DEST"
    if ! tar -xzf "\$TMPDIR/venv.tar.gz" -C "\$DEST"; then
        log_err "extraction failed -- \$DEST may now hold a partial tree."
        log_err "remove \$DEST/\$VENV_BASENAME and run this again."
        exit 2
    fi

if [[ ! -d "\$DEST/\$VENV_BASENAME" ]]; then
    log_err "expected \$DEST/\$VENV_BASENAME after extraction but it is missing"
    exit 2
fi

FIXVENV="\$TMPDIR/bundle_venv.sh"

# Ensure base64 is available on the target machine.
if ! command -v base64 >/dev/null 2>&1; then
    log_err "base64 command not found on this system; cannot extract installer payload"
    exit 2
fi

# GNU base64 decodes with -d; BSD/macOS base64 uses -D instead. Detect which
# this machine has rather than assuming, so the installer works on both.
if printf 'QQ==' | base64 -d >/dev/null 2>&1; then
    B64_DECODE_FLAG="-d"
else
    B64_DECODE_FLAG="-D"
fi

base64 "\$B64_DECODE_FLAG" > "\$FIXVENV" <<'B64EOF'
${fixvenv_b64}
B64EOF

chmod +x "\$FIXVENV"

log_info "fixing venv paths at: \$DEST/\$VENV_BASENAME"
"\$FIXVENV" -n "\$DEST/\$VENV_BASENAME" "\$@" "\$DEST/\$VENV_BASENAME"
exit \$?
__PAYLOAD_BELOW__
STUB
    } > "$tmp_stub"

    cat "$tarball" >> "$tmp_stub"
    chmod 0755 "$tmp_stub"

    if mv -f -- "$tmp_stub" "$out"; then
        INSTALLER_RESULT="$out"
        log_info "installer created: $out"
    else
        rm -f -- "$tmp_stub"
        log_err "failed to write installer: $out"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

if $INSTALL; then
    if [[ -z "$COMPRESS_RESULT" ]]; then
        log_err "--self-extract needs a valid archive but none was produced"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        build_installer "$COMPRESS_RESULT" "$(basename "$VENV_PATH")"
    fi
fi

# Once the self-extracting installer has been built, the tarball it was
# built from is fully embedded inside it and serves no further purpose on
# its own. Remove it automatically, but only on a clean run (no failures
# or warnings anywhere above) so a questionable archive is never thrown
# away silently.
if $INSTALL && [[ -n "$INSTALLER_RESULT" ]]; then
    if $DRY_RUN; then
        log_test "would remove intermediate archive (embedded in installer): $COMPRESS_RESULT"
    elif ((FAIL_COUNT == 0 && WARN_COUNT == 0)); then
        if rm -f -- "$COMPRESS_RESULT"; then
            log_info "removed intermediate archive (embedded in installer): $COMPRESS_RESULT"
            COMPRESS_RESULT=""
        else
            log_warn "failed to remove intermediate archive: $COMPRESS_RESULT"
        fi
    else
        log_note "keeping intermediate archive because of warnings/failures above: $COMPRESS_RESULT"
    fi
fi

# ==============================================================================
# SUMMARY
# ==============================================================================

echo
if $DRY_RUN; then
    printf '%bSummary (dry run):%b %d change(s) would be made, %d warning(s), %d failure(s).\n' \
        "$BOLD" "$RESET" "$CHANGE_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
else
    printf '%bSummary:%b %d change(s), %d warning(s), %d failure(s).\n' \
        "$BOLD" "$RESET" "$CHANGE_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
fi

if [[ -n "$COMPRESS_RESULT" ]]; then
    printf '%bArchive:%b %s\n' "$BOLD" "$RESET" "$COMPRESS_RESULT"
fi

if [[ -n "$INSTALLER_RESULT" ]]; then
    printf '%bInstaller:%b %s\n' "$BOLD" "$RESET" "$INSTALLER_RESULT"
fi

((FAIL_COUNT == 0))
