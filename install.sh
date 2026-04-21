#!/bin/sh
# pmp installer — curl-pipe-sh friendly, pure POSIX sh
# Usage: sh install.sh
#   PMP_INSTALL_DIR=~/.pmp     override install location
#   PMP_VERSION=v0.2.0         pin to a specific tag
#   PMP_NO_MODIFY_PATH=1       skip shell rc modification

set -u

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
if ! check_cmd find; then
    note "find not found — 'pmp env' header detection will not work."
fi

# --- Install / Update ---

if [ -e "$PMP_INSTALL_DIR/.git" ]; then
    # Existing git checkout (directory or worktree file)
    msg "Updating existing installation at $PMP_INSTALL_DIR"
    # If on detached HEAD (after version pin), return to main/master first
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
fi

# --- Verify installation ---

if [ ! -f "$PMP_INSTALL_DIR/bin/pmp" ]; then
    die "Installation incomplete: bin/pmp not found in $PMP_INSTALL_DIR."
fi

# Ensure bin/pmp is executable
if [ ! -x "$PMP_INSTALL_DIR/bin/pmp" ]; then
    chmod +x "$PMP_INSTALL_DIR/bin/pmp"
fi

# --- Shell rc PATH modification ---

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

if [ "${PMP_NO_MODIFY_PATH:-0}" != "1" ]; then
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
if [ "${PMP_NO_MODIFY_PATH:-0}" != "1" ]; then
    msg "Restart your shell or run: export PATH=\"$PMP_INSTALL_DIR/bin:\$PATH\""
fi
