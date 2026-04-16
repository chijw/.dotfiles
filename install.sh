#!/usr/bin/env bash
set -euo pipefail

# Colors & Logging
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}  →${NC} $*"; }
success() { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
error()   { echo -e "${RED}  ✗${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

# Global paths
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREWFILE="$DOTFILES_DIR/Brewfile"
BREW_PATH=""
ZSH_PATH=""

# Initialize brew and zsh paths once
init_paths() {
  # Find brew in PATH or common locations
  BREW_PATH=$(command -v brew 2>/dev/null || \
    find /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew \
    -type f -executable 2>/dev/null | head -1)

  # Load brew environment if found
  [[ -n "$BREW_PATH" ]] && eval "$("$BREW_PATH" shellenv)"

  # Find zsh (prefer brew version, fallback to system)
  if [[ -n "$BREW_PATH" ]]; then
    local brew_prefix="$("$BREW_PATH" --prefix 2>/dev/null || true)"
    [[ -n "$brew_prefix" && -x "$brew_prefix/bin/zsh" ]] && ZSH_PATH="$brew_prefix/bin/zsh"
  fi
  ZSH_PATH="${ZSH_PATH:-$(command -v zsh 2>/dev/null || echo /bin/zsh)}"
}

# Homebrew installation
install_homebrew() {
  section "Homebrew"
  if [[ -n "$BREW_PATH" ]]; then
    success "Homebrew already installed — $(brew --version | head -1)"
    return
  fi

  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Re-initialize paths after installation
  init_paths
  [[ -n "$BREW_PATH" ]] || error "Homebrew installed, but brew was not found"
  success "Homebrew installed"
}

# Install packages from Brewfile
install_packages_via_brewfile() {
  section "Packages via Brewfile"
  [[ -f "$BREWFILE" ]] || error "Cannot find Brewfile at $BREWFILE"

  info "Installing/Verifying packages..."
  brew bundle install --file="$BREWFILE" --no-upgrade || error "Failed to install some packages"
  success "Brewfile packages are ready"
}

# Rust & Cargo installation
install_rust() {
  section "Rust & Cargo"
  if command -v cargo &>/dev/null; then
    success "Rust already installed — $(rustc --version)"
    return
  fi

  info "Installing Rust via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
  success "Rust installed"
}

# Initialize git submodules
init_submodules() {
  section "Git Submodules"
  info "Initializing submodules..."
  cd "$DOTFILES_DIR"
  git submodule update --init --recursive
  success "Submodules ready"
}

# Stow dotfiles to home directory
stow_dotfiles() {
  section "Stowing Dotfiles"
  mkdir -p "$HOME/.config"
  cd "$DOTFILES_DIR"

  local folders=(tmux zim nvim yazi)

  for pkg in "${folders[@]}"; do
    if [[ ! -d "$DOTFILES_DIR/$pkg" ]]; then
      warn "Folder '$pkg' not found, skipping"
      continue
    fi

    info "Stowing $pkg..."
    stow --restow --target="$HOME" "$pkg" || error "Failed to stow '$pkg'"
    success "Stowed $pkg"
  done
}

# Configure ~/.zshrc with necessary paths
setup_local_zshrc() {
  section "Configuring ~/.zshrc"

  local zshrc="$HOME/.zshrc"
  touch "$zshrc"

  info "Injecting environment paths..."

  # Add Homebrew shellenv if not present
  if [[ -n "$BREW_PATH" ]]; then
    grep -qF "eval \"\$($BREW_PATH shellenv)\"" "$zshrc" || \
      echo "eval \"\$($BREW_PATH shellenv)\"" >> "$zshrc"
  fi

  # Add Cargo environment if not present
  grep -qF '.cargo/env' "$zshrc" || \
    echo '[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"' >> "$zshrc"

  success "~/.zshrc updated with necessary paths"
}

# ── Zim (Zsh Framework) ───────────────────────────────────────────────────────
# Install Zim framework and plugins
install_zim() {
  section "Zim & Plugins"
  export ZIM_HOME="${ZDOTDIR:-$HOME}/.zim"
  [[ -z "$ZSH_PATH" ]] && error "zsh is not installed; install it first and rerun the script"

  if [[ ! -d "$ZIM_HOME" ]]; then
    info "Installing Zimfw..."
    curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | "$ZSH_PATH"
    success "Zimfw installed"
  else
    success "Zimfw already installed"
  fi

  info "Syncing Zim modules based on .zimrc..."
  "$ZSH_PATH" -c 'source "$1/zimfw.zsh" init -q && source "$1/zimfw.zsh" install' _ "$ZIM_HOME"
  success "Zim modules synced"
}

# Setup default shell to zsh
setup_shell() {
  section "Default Shell"
  [[ -z "$ZSH_PATH" ]] && error "zsh is not installed; install it first and rerun the script"

  if [[ "$SHELL" == "$ZSH_PATH" || "$SHELL" == "/bin/zsh" || "$SHELL" == "/usr/bin/zsh" ]]; then
    success "Default shell is already zsh"
    return
  fi

  info "Changing default shell to zsh ($ZSH_PATH)..."
  if ! grep -Fxq "$ZSH_PATH" /etc/shells; then
    warn "Adding $ZSH_PATH to /etc/shells (requires sudo)..."
    echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
  fi

  chsh -s "$ZSH_PATH" && success "Default shell changed to zsh" || \
    warn "Failed to change shell. Run manually: chsh -s $ZSH_PATH"
}

# Main installation flow
main() {
  echo -e "\n${BOLD}${BLUE}"
  echo "  ██████╗  ██████╗ ████████╗███████╗██╗██╗     ███████╗███████╗"
  echo "  ██╔══██╗██╔═══██╗╚══██╔══╝██╔════╝██║██║     ██╔════╝██╔════╝"
  echo "  ██║  ██║██║   ██║   ██║   █████╗  ██║██║     █████╗  ███████╗"
  echo "  ██║  ██║██║   ██║   ██║   ██╔══╝  ██║██║     ██╔══╝  ╚════██║"
  echo "  ██████╔╝╚██████╔╝   ██║   ██║     ██║███████╗███████╗███████║"
  echo "  ╚═════╝  ╚═════╝    ╚═╝   ╚═╝     ╚═╝╚══════╝╚══════╝╚══════╝"
  echo -e "${NC}"
  echo -e "  ${BOLD}Setting up your environment...${NC}\n"

  init_paths
  install_homebrew
  install_packages_via_brewfile
  install_rust

  init_submodules

  stow_dotfiles
  setup_local_zshrc
  install_zim
  setup_shell

  echo -e "\n${GREEN}${BOLD}  ✓ All done!${NC}"
  echo -e "  Please restart your terminal to see changes.\n"
}

main "$@"
