#!/usr/bin/env bash
set -euo pipefail

# Colors & Logging
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${BLUE}  →${NC} $*"; }
success() { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
error()   { echo -e "${RED}  ✗${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}▸ $*${NC}"; }
step()    { echo -e "${DIM}  ├─${NC} $*"; }
substep() { echo -e "${DIM}  │  └─${NC} $*"; }

# Progress spinner
spinner() {
  local pid=$1
  local message=$2
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 10 ))
    printf "\r${BLUE}  ${spin:$i:1}${NC} %s" "$message"
    sleep 0.1
  done

  wait "$pid"
  local exit_code=$?
  printf "\r"
  return $exit_code
}

# Progress bar
progress_bar() {
  local current=$1
  local total=$2
  local width=30
  local percentage=$((current * 100 / total))
  local filled=$((width * current / total))
  local empty=$((width - filled))

  printf "\r${CYAN}  ["
  printf "%${filled}s" | tr ' ' '█'
  printf "%${empty}s" | tr ' ' '░'
  printf "]${NC} %3d%% (%d/%d)" "$percentage" "$current" "$total"
}

print_log_matches() {
  local log_file="$1"
  local mode="${2:-summary}"
  local line

  while IFS= read -r line; do
    case "$mode" in
      summary)
        if [[ "$line" =~ Installing|Using ]]; then
          substep "$line"
        fi
        ;;
      failure)
        printf '  │  %s\n' "$line"
        ;;
    esac
  done < "$log_file"
}

# Global paths
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREWFILE="$DOTFILES_DIR/Brewfile"
BREW_PATH=""
ZSH_PATH=""

find_first_executable() {
  local candidate
  for candidate in "$@"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# Initialize brew and zsh paths once
init_paths() {
  # Find brew in PATH or common locations
  BREW_PATH="$(command -v brew 2>/dev/null || true)"
  if [[ -z "$BREW_PATH" ]]; then
    BREW_PATH="$(find_first_executable \
      /opt/homebrew/bin/brew \
      /usr/local/bin/brew \
      /home/linuxbrew/.linuxbrew/bin/brew 2>/dev/null || true)"
  fi

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
    success "Already installed — $(brew --version | head -1)"
    return
  fi

  step "Downloading installer..."
  (
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" &>/tmp/brew-install.log
  ) &
  spinner $! "Installing Homebrew"

  # Re-initialize paths after installation
  init_paths
  [[ -n "$BREW_PATH" ]] || error "Homebrew installed, but brew was not found"
  success "Installed successfully — $(brew --version | head -1)"
}

# Install packages from Brewfile
install_packages_via_brewfile() {
  section "Packages via Brewfile"
  [[ -f "$BREWFILE" ]] || error "Cannot find Brewfile at $BREWFILE"

  step "Counting packages..."
  local total_packages=$(grep -E '^\s*(brew|cask)\s+"' "$BREWFILE" | wc -l | tr -d ' ')

  step "Installing packages..."

  local max_retries=3
  local retry=0
  local log_file="/tmp/brew-bundle-$$.log"

  while [[ $retry -lt $max_retries ]]; do
    # Run brew bundle with output to both terminal and log
    if brew bundle install --file="$BREWFILE" --no-upgrade 2>&1 | tee "$log_file" | \
       grep --line-buffered -E '(Installing|Using|Upgrading|Skipping|Fetching)' | \
       while IFS= read -r line; do
         substep "$line"
       done; then

      local exit_code=${PIPESTATUS[0]}

      if [[ $exit_code -eq 0 ]]; then
        success "All packages ready"
        rm -f "$log_file"
        return 0
      fi
    fi

    retry=$((retry + 1))
    if [[ $retry -lt $max_retries ]]; then
      warn "Some packages failed, retrying ($retry/$max_retries)..."
      sleep 5
    fi
  done

  warn "Installation failed. Log saved to: $log_file"
  error "Failed to install some packages after $max_retries attempts"
}

# Rust & Cargo installation
install_rust() {
  section "Rust & Cargo"

  # Check if cargo exists (rustup installs both rustc and cargo by default)
  if command -v cargo &>/dev/null; then
    local rust_version=$(rustc --version 2>/dev/null || echo "unknown")
    success "Already installed — $rust_version"
    return
  fi

  step "Downloading rustup installer..."

  # Try with SSL verification first, fallback to insecure if it fails
  local curl_opts="--proto =https --tlsv1.2 -sSf"
  local install_script

  if install_script=$(curl $curl_opts https://sh.rustup.rs 2>/dev/null); then
    echo "$install_script" | sh -s -- -y --no-modify-path &>/tmp/rust-install.log &
    spinner $! "Installing Rust toolchain (stable)"
  else
    warn "SSL verification failed, retrying without verification..."
    curl $curl_opts --insecure https://sh.rustup.rs 2>/dev/null | sh -s -- -y --no-modify-path &>/tmp/rust-install.log &
    spinner $! "Installing Rust toolchain (stable)"
  fi

  # Source cargo env to make it available in current shell
  if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
  else
    error "Rust installation completed but cargo env not found"
  fi

  # Verify installation
  if command -v cargo &>/dev/null; then
    success "Installed successfully — $(rustc --version)"
  else
    error "Rust installation failed"
  fi
}

# Node.js via fnm
install_node() {
  section "Node.js via fnm"

  if ! command -v fnm &>/dev/null; then
    error "fnm is not installed (should be installed via Brewfile)"
  fi

  # Initialize fnm in current shell
  eval "$(fnm env --use-on-cd)"

  step "Installing LTS version..."
  (
    fnm install --lts &>/tmp/fnm-install.log
    fnm use lts-latest &>/dev/null
  ) &
  spinner $! "Downloading Node.js"

  success "Installed successfully — $(node --version)"
}


# Initialize git submodules
init_submodules() {
  section "Git Submodules"
  step "Initializing..."
  cd "$DOTFILES_DIR"
  (
    git submodule update --init --recursive &>/tmp/submodule-init.log
  ) &
  spinner $! "Updating submodules"
  success "All submodules ready"
}

# Stow dotfiles to home directory
stow_dotfiles() {
  section "Stowing Dotfiles"
  mkdir -p "$HOME/.config"
  cd "$DOTFILES_DIR"

  local folders=(tmux zim nvim yazi)
  local total=${#folders[@]}
  local current=0

  for pkg in "${folders[@]}"; do
    current=$((current + 1))

    if [[ ! -d "$DOTFILES_DIR/$pkg" ]]; then
      warn "Folder '$pkg' not found, skipping"
      continue
    fi

    step "Stowing $pkg..."
    stow \
      --restow \
      --target="$HOME" \
      --ignore='(^|/)\.git$' \
      --ignore='(^|/)\.DS_Store$' \
      --ignore='(^|/)\.nvimlog$' \
      "$pkg" &>/tmp/stow-$pkg.log || error "Failed to stow '$pkg'"
    progress_bar "$current" "$total"
  done

  echo ""
  success "All dotfiles linked"
}

# Configure ~/.zshrc with necessary paths
setup_local_zshrc() {
  section "Configuring ~/.zshrc"

  local zshrc="$HOME/.zshrc"
  touch "$zshrc"

  local changes=0

  # Add Homebrew shellenv if not present
  if [[ -n "$BREW_PATH" ]]; then
    if ! grep -qF "eval \"\$($BREW_PATH shellenv)\"" "$zshrc"; then
      echo "eval \"\$($BREW_PATH shellenv)\"" >> "$zshrc"
      step "Added Homebrew environment"
      changes=$((changes + 1))
    fi
  fi

  # Add Cargo environment if not present
  if ! grep -qF '.cargo/env' "$zshrc"; then
    echo '[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"' >> "$zshrc"
    step "Added Cargo environment"
    changes=$((changes + 1))
  fi

  # Add fnm initialization if not present
  if ! grep -qF 'fnm env' "$zshrc"; then
    echo 'eval "$(fnm env --use-on-cd)"' >> "$zshrc"
    step "Added fnm initialization"
    changes=$((changes + 1))
  fi

  if [[ $changes -eq 0 ]]; then
    success "Already configured"
  else
    success "Added $changes environment paths"
  fi
}

# Install Zim framework and plugins
install_zim() {
  section "Zim & Plugins"
  export ZIM_HOME="${ZDOTDIR:-$HOME}/.zim"
  [[ -z "$ZSH_PATH" ]] && error "zsh is not installed; install it first and rerun the script"

  if [[ ! -d "$ZIM_HOME" ]]; then
    step "Installing Zimfw..."
    (
      curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | "$ZSH_PATH" &>/tmp/zim-install.log
    ) &
    spinner $! "Downloading Zim framework"
    success "Zimfw installed"
  else
    success "Zimfw already installed"
  fi

  step "Syncing modules..."
  (
    "$ZSH_PATH" -c 'source "$1/zimfw.zsh" init -q && source "$1/zimfw.zsh" install' _ "$ZIM_HOME" &>/tmp/zim-sync.log
  ) &
  spinner $! "Installing Zim plugins"
  success "All modules synced"
}

# Setup default shell to zsh
setup_shell() {
  section "Default Shell"
  [[ -z "$ZSH_PATH" ]] && error "zsh is not installed; install it first and rerun the script"

  if [[ "$SHELL" == "$ZSH_PATH" || "$SHELL" == "/bin/zsh" || "$SHELL" == "/usr/bin/zsh" ]]; then
    success "Already set to zsh"
    return
  fi

  step "Changing default shell to zsh..."
  if ! grep -Fxq "$ZSH_PATH" /etc/shells; then
    warn "Adding $ZSH_PATH to /etc/shells (requires sudo)..."
    echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
  fi

  chsh -s "$ZSH_PATH" && success "Default shell changed to zsh" || \
    warn "Failed to change shell. Run manually: chsh -s $ZSH_PATH"
}

# Main installation flow
main() {
  echo -e "\n${BOLD}${CYAN}Dotfiles Setup${NC}"
  echo -e "${DIM}Setting up your development environment...${NC}\n"

  init_paths
  install_homebrew
  install_packages_via_brewfile
  install_rust
  install_node

  init_submodules

  stow_dotfiles
  setup_local_zshrc
  install_zim
  setup_shell

  echo -e "\n${GREEN}${BOLD}✓ Setup complete!${NC}"
  echo -e "${DIM}To apply all changes, run:${NC}"
  echo -e "  ${CYAN}source ~/.zshrc${NC}"
  echo -e "${DIM}Or restart your terminal.${NC}\n"
}

main "$@"
