#!/usr/bin/env bash
set -euo pipefail

# ── Colors & Logging ─────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}  →${NC} $*"; }
success() { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
error()   { echo -e "${RED}  ✗${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREWFILE="$DOTFILES_DIR/Brewfile"

# ── Homebrew ──────────────────────────────────────────────────────────────────
install_homebrew() {
  section "Homebrew"
  if command -v brew &>/dev/null; then
    success "Homebrew already installed — $(brew --version | head -1)"
    return
  fi

  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ -d /opt/homebrew/bin ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -d /usr/local/bin ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  success "Homebrew installed"
}

# ── Brewfile Bundle ───────────────────────────────────────────────────────────
install_packages_via_brewfile() {
  section "Packages via Brewfile"
  if [[ ! -f "$BREWFILE" ]]; then
    error "Cannot find Brewfile at $BREWFILE"
  fi

  info "Installing/Verifying packages..."
  if brew bundle --file="$BREWFILE" --no-lock; then
    success "Brewfile packages are ready."
  else
    error "Failed to install some packages."
  fi
}

# ── Rust / Cargo ──────────────────────────────────────────────────────────────
install_rust() {
  section "Rust & Cargo"
  if command -v cargo &>/dev/null; then
    success "Rust already installed — $(rustc --version)"
    return
  fi

  info "Installing Rust via rustup..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  source "$HOME/.cargo/env"
  success "Rust installed"
}

# ── Git Submodules ────────────────────────────────────────────────────────────
init_submodules() {
  section "Git Submodules"
  info "Initializing submodules..."
  cd "$DOTFILES_DIR"
  git submodule update --init --recursive
  success "Submodules ready"
}

# ── Stow Dotfiles ─────────────────────────────────────────────────────────────
stow_dotfiles() {
  section "Stowing Dotfiles"
  mkdir -p "$HOME/.config"
  cd "$DOTFILES_DIR"
  
  local folders=(git zim nvim lazygit yazi fastfetch)

  for pkg in "${folders[@]}"; do
    if [[ -d "$DOTFILES_DIR/$pkg" ]]; then
      info "Stowing $pkg..."
      stow --restow --target="$HOME" "$pkg" 2>&1 | grep -v "^$" || true
      success "Stowed $pkg"
    else
      warn "Folder '$pkg' not found in dotfiles, skipping"
    fi
  done
}

# ── Local .zshrc Setup ────────────────────────────────────
setup_local_zshrc() {
  section "Configuring ~/.zshrc"
  
  local zshrc="$HOME/.zshrc"
  touch "$zshrc"

  ensure_line() {
    local line="$1"
    grep -qxF "$line" "$zshrc" || echo "$line" >> "$zshrc"
  }

  info "Injecting environment paths..."

  # Homebrew Path
  if [[ -d /opt/homebrew/bin ]]; then
    ensure_line 'eval "$(/opt/homebrew/bin/brew shellenv)"'
  elif [[ -d /usr/local/bin ]]; then
    ensure_line 'eval "$(/usr/local/bin/brew shellenv)"'
  fi

  # Cargo Path
  ensure_line '[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"'

  success "~/.zshrc updated with necessary paths"
}

# ── Zim (Zsh Framework) ───────────────────────────────────────────────────────
install_zim() {
  section "Zim & Plugins"
  export ZIM_HOME="${ZDOTDIR:-$HOME}/.zim"

  if [[ ! -d "$ZIM_HOME" ]]; then
    info "Installing Zimfw..."
    curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | zsh
    success "Zimfw installed"
  else
    success "Zimfw already installed"
  fi

  info "Syncing Zim modules based on .zimrc..."
  zsh -c "source $ZIM_HOME/zimfw.zsh init -q && source $ZIM_HOME/zimfw.zsh install"
  success "Zim modules synced"
}

# ── Setup Default Shell ───────────────────────────────────────────────────────
setup_shell() {
  section "Default Shell"
  local zsh_path
  zsh_path=$(command -v zsh)
  
  if [[ "$SHELL" == "$zsh_path" || "$SHELL" == "/bin/zsh" || "$SHELL" == "/usr/bin/zsh" ]]; then
    success "Default shell is already zsh"
    return
  fi

  info "Changing default shell to zsh ($zsh_path)..."
  if ! grep -Fxq "$zsh_path" /etc/shells; then
    warn "Adding $zsh_path to /etc/shells (requires sudo)..."
    echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
  fi

  if chsh -s "$zsh_path"; then
    success "Default shell changed to zsh"
  else
    warn "Failed. Run manually: chsh -s $zsh_path"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
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
