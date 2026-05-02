#!/bin/sh
# pmp installer — curl-pipe-sh friendly, pure POSIX sh
# Usage: sh install.sh
#   PMP_INSTALL_DIR=~/.pmp     override install location
#   PMP_VERSION=v0.4.0         pin to a specific tag
#   PMP_MODIFY_PATH=1          opt in to shell rc PATH modification

set -eu

PMP_REPO="https://github.com/TheSmuks/pmp.git"

# --- Helpers ---

msg() { printf "pmp: %s\n" "$1"; }
err() { printf "pmp: error: %s\n" "$1" >&2; }
note() { printf "pmp: note: %s\n" "$1"; }

die() {
    err "$1"
    exit 1
}

# --- Resolve install directory ---

PMP_INSTALL_DIR="${PMP_INSTALL_DIR:-$HOME/.pmp}"

# Make relative paths absolute
case "$PMP_INSTALL_DIR" in
    /*) ;;
    *)  PMP_INSTALL_DIR="$(cd "$PMP_INSTALL_DIR" 2>/dev/null && pwd)" || \
        PMP_INSTALL_DIR="$PWD/$PMP_INSTALL_DIR" ;;
esac

# --- Dependency checks ---

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Required: git
if ! check_cmd git; then
    die "git is required for installation.
  Install: https://git-scm.com/book/en/v2/Getting-Started-Installing-Git
  Or:      apt install git / brew install git"
fi

# Required: pike (pike8.0 variant is acceptable)
_pi_bin=""
if check_cmd pike; then
    _pi_bin=pike
elif check_cmd pike8.0; then
    _pi_bin=pike8.0
else
    die "pike (or pike8.0) is required but not found in PATH.
  Install: https://pike.lysator.liu.se/download/
  Or:      apt install pike8.0"
fi

# Optional: note if missing, but don't fail
if ! check_cmd gunzip; then
    note "gunzip not found — remote .tar.gz extraction will not work."
fi

# --- Install / Update ---

if [ -e "$PMP_INSTALL_DIR/.git" ]; then
    # Existing git checkout (directory or worktree file)
    msg "Updating existing installation at $PMP_INSTALL_DIR"
    # Fetch all tags and branches
    git -C "$PMP_INSTALL_DIR" fetch --all --tags 2>/dev/null || \
        die "git fetch failed. Check your network connection and try again."
    # Return to a branch if on detached HEAD (after previous version pin)
    if ! git -C "$PMP_INSTALL_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
        git -C "$PMP_INSTALL_DIR" checkout main 2>/dev/null || \
            git -C "$PMP_INSTALL_DIR" checkout master 2>/dev/null || true
    fi
    git -C "$PMP_INSTALL_DIR" pull || die "git pull failed. Check your network connection and try again."
elif [ -d "$PMP_INSTALL_DIR" ]; then
    die "$PMP_INSTALL_DIR exists but is not a git repository.
  To proceed, remove it and re-run:
    rm -rf \"$PMP_INSTALL_DIR\"
    sh install.sh"
else
    msg "Cloning pmp into $PMP_INSTALL_DIR"
    git clone "$PMP_REPO" "$PMP_INSTALL_DIR" || die "git clone failed. Check your network connection and try again."
fi

# --- Pin version if requested ---

if [ -n "${PMP_VERSION:-}" ]; then
    msg "Checking out $PMP_VERSION"
    git -C "$PMP_INSTALL_DIR" checkout "tags/$PMP_VERSION" 2>/dev/null || \
        die "tag $PMP_VERSION not found. Run 'git -C \"$PMP_INSTALL_DIR\" tag -l' to see available versions."

    # Verify checkout integrity: compare HEAD with expected tag commit
    _tag_sha=$(git -C "$PMP_INSTALL_DIR" rev-parse "tags/$PMP_VERSION" 2>/dev/null || echo "")
    _head_sha=$(git -C "$PMP_INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$_tag_sha" ] && [ -n "$_head_sha" ] && [ "$_tag_sha" != "$_head_sha" ]; then
        die "checksum mismatch: expected $_tag_sha but got $_head_sha for $PMP_VERSION"
    fi
fi

# --- Verify installation ---

if [ ! -f "$PMP_INSTALL_DIR/bin/pmp" ]; then
    die "Installation incomplete: bin/pmp not found in $PMP_INSTALL_DIR."
fi

# Ensure bin/pmp is executable
if [ ! -x "$PMP_INSTALL_DIR/bin/pmp" ]; then
    chmod +x "$PMP_INSTALL_DIR/bin/pmp"
fi

# Verify pmp actually works
if ! "$PMP_INSTALL_DIR/bin/pmp" version >/dev/null 2>&1; then
    die "Installation verification failed: 'pmp version' returned an error.
  Ensure Pike is correctly installed and PIKE_MODULE_PATH is not set incorrectly."
fi

# --- Shell rc PATH modification (opt-in) ---

modify_rc() {
    _rcfile="$1"
    _line="export PATH=\"$PMP_INSTALL_DIR/bin:\$PATH\""

    # Create rc file if it doesn't exist
    if [ ! -f "$_rcfile" ]; then
        printf "%s\n" "$_line" > "$_rcfile"
        msg "Created $_rcfile with PATH entry."
        return
    fi

    # Dedup: only append if the exact line isn't already there
    if grep -qF "$_line" "$_rcfile" 2>/dev/null; then
        return
    fi

    printf "\n%s\n" "$_line" >> "$_rcfile"
    msg "Added PATH entry to $_rcfile"
}

if [ "${PMP_MODIFY_PATH:-0}" = "1" ]; then
    for _rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        # Only modify .zshrc if zsh is installed, .profile always
        case "$_rc" in
            */.zshrc)  check_cmd zsh  || continue ;;
            */.bashrc) check_cmd bash || continue ;;
        esac
        modify_rc "$_rc"
    done
fi

# --- Success ---

# Try to read installed version
_ver=""
_conf="$PMP_INSTALL_DIR/bin/Pmp.pmod/Config.pmod"
if [ -f "$_conf" ]; then
    _ver=$(sed -n 's/.*PMP_VERSION *= *"\([^"]*\)".*/\1/p' "$_conf" 2>/dev/null)
fi

msg "Installed pmp${_ver:+ v$_ver} to $PMP_INSTALL_DIR"
msg "Run 'pmp --help' to get started."
msg "Add to PATH: export PATH=\"$PMP_INSTALL_DIR/bin:\$PATH\""
