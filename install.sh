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

USE_UNICODE=0
SPINNER_FRAMES='-\|/'
BAR_FILLED_CHAR='#'
BAR_EMPTY_CHAR='-'
ICON_INFO='->'
ICON_SUCCESS='OK'
ICON_WARN='!!'
ICON_ERROR='XX'
ICON_SECTION='>'
ICON_STEP='|-'
ICON_SUBSTEP='|  `-'
LOG_PREFIX='|'

init_ui() {
  if [[ "${LC_ALL:-${LANG:-}}" == *UTF-8* || "${LC_ALL:-${LANG:-}}" == *utf8* ]]; then
    USE_UNICODE=1
    SPINNER_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    BAR_FILLED_CHAR='█'
    BAR_EMPTY_CHAR='░'
    ICON_INFO='→'
    ICON_SUCCESS='✓'
    ICON_WARN='⚠'
    ICON_ERROR='✗'
    ICON_SECTION='▸'
    ICON_STEP='├─'
    ICON_SUBSTEP='│  └─'
    LOG_PREFIX='│'
  fi
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  local i

  for ((i = 0; i < count; i++)); do
    out+="$char"
  done

  printf '%s' "$out"
}

clear_line() {
  printf '\r\033[2K'
}

info()    { echo -e "${BLUE}  ${ICON_INFO}${NC} $*"; }
success() { echo -e "${GREEN}  ${ICON_SUCCESS}${NC} $*"; }
warn()    { echo -e "${YELLOW}  ${ICON_WARN}${NC} $*"; }
error()   { echo -e "${RED}  ${ICON_ERROR}${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}${ICON_SECTION} $*${NC}"; }
step()    { echo -e "${DIM}  ${ICON_STEP}${NC} $*"; }
substep() { echo -e "${DIM}  ${ICON_SUBSTEP}${NC} $*"; }

# Progress spinner with timeout
spinner() {
  local pid=$1
  local message=$2
  local timeout=${3:-300}  # Default 5 minutes
  local spin="$SPINNER_FRAMES"
  local i=0
  local elapsed=0
  local frame_count=${#spin}

  while kill -0 "$pid" 2>/dev/null; do
    clear_line
    printf "${BLUE}  %s${NC} %s" "${spin:$i:1}" "$message"
    i=$(( (i + 1) % frame_count ))
    sleep 0.1
    elapsed=$((elapsed + 1))

    if [[ $timeout -gt 0 && $elapsed -ge $((timeout * 10)) ]]; then
      kill "$pid" 2>/dev/null
      clear_line
      return 124  # Timeout exit code
    fi
  done

  local exit_code=0
  wait "$pid" || exit_code=$?
  clear_line
  return $exit_code
}

# Progress bar
progress_bar() {
  local current=$1
  local total=$2
  local message="${3:-}"
  local width=30
  local percentage=$((current * 100 / total))
  local filled=$((width * current / total))
  local empty=$((width - filled))

  clear_line
  printf "${CYAN}  ["
  repeat_char "$BAR_FILLED_CHAR" "$filled"
  repeat_char "$BAR_EMPTY_CHAR" "$empty"
  printf "]${NC} %3d%% (%d/%d)" "$percentage" "$current" "$total"
  [[ -n "$message" ]] && printf "  %s" "$message"
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
        printf '  %s  %s\n' "$LOG_PREFIX" "$line"
        ;;
    esac
  done < "$log_file"
}

show_log_tail() {
  local log_file="$1"
  local lines="${2:-12}"

  [[ -s "$log_file" ]] || return 0
  tail -n "$lines" "$log_file" | print_log_matches /dev/stdin failure
}

# Global paths
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREWFILE="$DOTFILES_DIR/Brewfile"
NPMFILE="$DOTFILES_DIR/Npmfile"
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
    success "Already installed — $("$BREW_PATH" --version | head -1)"
    return
  fi

  step "Downloading installer..."
  command -v curl &>/dev/null || error "curl not found"
  local log_file="/tmp/brew-install.log"
  local pid
  local spinner_exit=0

  (
    export NONINTERACTIVE=1
    curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash
  ) >"$log_file" 2>&1 &
  pid=$!

  spinner "$pid" "Installing Homebrew" || spinner_exit=$?
  if [[ $spinner_exit -ne 0 ]]; then
    warn "Homebrew install failed. Last output:"
    show_log_tail "$log_file"
    error "Homebrew installation failed. See $log_file"
  fi

  # Re-initialize paths after installation
  init_paths
  [[ -n "$BREW_PATH" ]] || error "Homebrew installed, but brew was not found"
  success "Installed successfully — $("$BREW_PATH" --version | head -1)"
}

# Install packages from Brewfile
install_packages_via_brewfile() {
  section "Packages via Brewfile"
  [[ -f "$BREWFILE" ]] || error "Cannot find Brewfile at $BREWFILE"

  step "Installing packages..."

  local max_retries=3
  local retry=0
  local log_file="/tmp/brew-bundle-$$.log"

  while [[ $retry -lt $max_retries ]]; do
    if "$BREW_PATH" bundle install --file="$BREWFILE" --no-upgrade \
      > >(tee "$log_file" | grep --line-buffered -E '(Installing|Using|Upgrading|Skipping|Fetching)' | while IFS= read -r line; do
        substep "$line"
      done) \
      2>&1; then
      success "All packages ready"
      rm -f "$log_file"
      return 0
    fi

    retry=$((retry + 1))
    if [[ $retry -lt $max_retries ]]; then
      warn "brew bundle failed. Last output:"
      tail -n 20 "$log_file" | print_log_matches /dev/stdin failure
      warn "Some packages failed, retrying ($retry/$max_retries)..."
      sleep 5
    fi
  done

  warn "brew bundle failed. Last output:"
  tail -n 40 "$log_file" | print_log_matches /dev/stdin failure
  error "Failed to install some packages after $max_retries attempts. Full log: $log_file"
}

# Rust & Cargo installation
install_rust() {
  section "Rust & Cargo"

  if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
  elif [[ -d "$HOME/.cargo/bin" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  fi

  # Check if cargo exists (rustup installs both rustc and cargo by default)
  if command -v cargo &>/dev/null; then
    local rust_version=$(rustc --version 2>/dev/null || echo "unknown")
    success "Already installed — $rust_version"
    return
  fi

  step "Installing via rustup..."

  local log_file="/tmp/rust-install.log"
  local pid
  local spinner_exit=0

  command -v curl &>/dev/null || error "curl not found"

  (
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  ) >"$log_file" 2>&1 &
  pid=$!

  spinner "$pid" "Installing Rust toolchain (stable)" 300 || spinner_exit=$?
  if [[ $spinner_exit -ne 0 ]]; then
    if [[ $spinner_exit -eq 124 ]]; then
      error "Rust installation timed out. See $log_file"
    fi
    error "Rust installation failed. See $log_file"
  fi

  # Source cargo env to make it available in current shell
  if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
  elif [[ -d "$HOME/.cargo/bin" ]]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  else
    error "Rust installation completed but neither ~/.cargo/env nor ~/.cargo/bin was found"
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
  eval "$("$BREW_PATH" shellenv)"

  if ! command -v fnm &>/dev/null; then
    error "fnm is not installed (should be installed via Brewfile)"
  fi

  # Initialize fnm in current shell
  eval "$(fnm env --use-on-cd)"

  step "Installing LTS version..."
  local log_file="/tmp/fnm-install.log"
  local pid
  local spinner_exit=0

  (
    fnm install --lts
    fnm use lts-latest
  ) >"$log_file" 2>&1 &
  pid=$!

  spinner "$pid" "Downloading Node.js" || spinner_exit=$?
  if [[ $spinner_exit -ne 0 ]]; then
    warn "Node.js install failed. Last output:"
    show_log_tail "$log_file"
    error "Node.js installation failed. See $log_file"
  fi

  success "Installed successfully — $(node --version)"
}

# Global npm CLI packages
install_node_packages() {
  section "Global npm Packages"
  eval "$("$BREW_PATH" shellenv)"

  # Ensure the fnm-managed Node is active so npm is on PATH (no sudo needed)
  if command -v fnm &>/dev/null; then
    eval "$(fnm env --use-on-cd)"
    fnm use lts-latest &>/dev/null || true
  fi

  if ! command -v npm &>/dev/null; then
    warn "npm not found; skipping npm packages"
    return
  fi

  if [[ ! -f "$NPMFILE" ]]; then
    warn "No Npmfile at $NPMFILE; skipping npm packages"
    return
  fi

  # Read packages from Npmfile (one per line; ignore blanks and #-comments)
  local packages=()
  local line pkg
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"        # strip inline/full-line comments
    read -r pkg _ <<<"$line"  # take first token, whitespace-trimmed
    [[ -n "$pkg" ]] && packages+=("$pkg")
  done < "$NPMFILE"

  if [[ ${#packages[@]} -eq 0 ]]; then
    success "No npm packages listed"
    return
  fi

  local total=${#packages[@]}
  local current=0
  local failed=0

  step "Installing CLI packages..."

  for pkg in "${packages[@]}"; do
    current=$((current + 1))
    local log_file="/tmp/npm-install-$$-$current.log"
    local pid
    local spinner_exit=0

    (
      npm install -g "$pkg"
    ) >"$log_file" 2>&1 &
    pid=$!

    spinner "$pid" "Installing $pkg ($current/$total)" || spinner_exit=$?
    if [[ $spinner_exit -ne 0 ]]; then
      warn "Failed to install $pkg. Last output:"
      show_log_tail "$log_file"
      failed=$((failed + 1))
    else
      substep "$pkg ready"
    fi
    rm -f "$log_file"
  done

  if [[ $failed -gt 0 ]]; then
    warn "$failed of $total npm package(s) failed to install"
  else
    success "All npm packages ready"
  fi
}


# Mihomo (Clash.Meta kernel) — Linux only
install_mihomo() {
  # Only install on Linux. Skip silently on macOS and anything else.
  if [[ "$(uname -s)" != "Linux" ]]; then
    return
  fi

  section "Mihomo (Clash kernel)"

  if command -v mihomo &>/dev/null; then
    success "Already installed — $(mihomo -v 2>/dev/null | head -1)"
    return
  fi

  command -v curl &>/dev/null || error "curl not found"

  # Map machine architecture to mihomo's release asset naming.
  local arch
  case "$(uname -m)" in
    x86_64 | amd64)  arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    armv7l)          arch="armv7" ;;
    i386 | i686)     arch="386" ;;
    *)
      warn "Unsupported architecture '$(uname -m)'; skipping mihomo"
      return
      ;;
  esac

  step "Resolving latest release..."
  local api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
  # Match only the plain linux-<arch>-vX.Y.Z.gz binary. Requiring a full
  # three-part version right after the arch skips the microarch ('-v1/-v2/-v3'),
  # '-go12x' and '-compatible' variants, which share the 'mihomo-linux-<arch>'
  # prefix but never have 'vX.Y.Z.gz' immediately after it.
  local url
  url="$(curl -fsSL "$api" \
    | grep -oE "https://[^\"]*/mihomo-linux-${arch}-v[0-9]+\.[0-9]+\.[0-9]+\.gz" \
    | head -1)"

  if [[ -z "$url" ]]; then
    warn "Could not resolve mihomo download URL for linux-${arch}; skipping"
    return
  fi

  local install_dir="$HOME/.local/bin"
  mkdir -p "$install_dir"

  step "Downloading $(basename "$url")..."
  local tmp_gz="/tmp/mihomo-$$.gz"
  local log_file="/tmp/mihomo-install.log"
  local pid
  local dl_exit=0

  (
    curl -fsSL -o "$tmp_gz" "$url"
  ) >"$log_file" 2>&1 &
  pid=$!

  spinner "$pid" "Downloading mihomo" || dl_exit=$?
  if [[ $dl_exit -ne 0 ]]; then
    warn "mihomo download failed. Last output:"
    show_log_tail "$log_file"
    rm -f "$tmp_gz"
    warn "Skipping mihomo install"
    return
  fi

  if ! gunzip -c "$tmp_gz" >"$install_dir/mihomo" 2>>"$log_file"; then
    warn "Failed to extract mihomo binary; skipping"
    rm -f "$tmp_gz" "$install_dir/mihomo"
    return
  fi
  rm -f "$tmp_gz"
  chmod +x "$install_dir/mihomo"

  if "$install_dir/mihomo" -v &>/dev/null; then
    success "Installed successfully — $("$install_dir/mihomo" -v 2>/dev/null | head -1)"
  else
    success "Installed to $install_dir/mihomo"
  fi
}

# Initialize git submodules
init_submodules() {
  section "Git Submodules"
  step "Initializing..."
  cd "$DOTFILES_DIR"
  local log_file="/tmp/submodule-init.log"
  local pid
  local spinner_exit=0

  (
    git submodule update --init --recursive
  ) >"$log_file" 2>&1 &
  pid=$!

  spinner "$pid" "Updating submodules" || spinner_exit=$?
  if [[ $spinner_exit -ne 0 ]]; then
    warn "Submodule init failed. Last output:"
    show_log_tail "$log_file"
    error "Failed to initialize submodules. See $log_file"
  fi

  success "All submodules ready"
}

# Stow dotfiles to home directory
stow_dotfiles() {
  section "Stowing Dotfiles"
  eval "$("$BREW_PATH" shellenv)"
  mkdir -p "$HOME/.config"
  cd "$DOTFILES_DIR"

  local folders=(tmux zim nvim yazi pip wezterm zsh)
  local total=${#folders[@]}
  local current=0

  step "Linking packages..."

  for pkg in "${folders[@]}"; do
    current=$((current + 1))

    if [[ ! -d "$DOTFILES_DIR/$pkg" ]]; then
      progress_bar "$current" "$total" "Skipping $pkg"
      echo ""
      warn "Folder '$pkg' not found, skipping"
      continue
    fi

    progress_bar "$((current - 1))" "$total" "Stowing $pkg..."
    stow \
      --restow \
      --target="$HOME" \
      --ignore='(^|/)\.git$' \
      --ignore='(^|/)\.DS_Store$' \
      --ignore='(^|/)\.nvimlog$' \
      "$pkg" &>/tmp/stow-$pkg.log || {
        echo ""
        error "Failed to stow '$pkg'"
      }
    progress_bar "$current" "$total" "Stowed $pkg"
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

  # Source personal config (stowed from zsh/.zshrc.local) if not already wired.
  # Appended after the Zim bootstrap block so zle/bindkey customizations apply
  # after Zim init. The guard keeps this safe if ~/.zshrc.local is missing.
  if ! grep -qF '.zshrc.local' "$zshrc"; then
    echo '[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"' >> "$zshrc"
    step "Added ~/.zshrc.local source"
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
    command -v curl &>/dev/null || error "curl not found"
    local install_log="/tmp/zim-install.log"
    local install_pid
    local install_exit=0

    (
      curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | "$ZSH_PATH"
    ) >"$install_log" 2>&1 &
    install_pid=$!

    spinner "$install_pid" "Downloading Zim framework" || install_exit=$?
    if [[ $install_exit -ne 0 ]]; then
      warn "Zimfw install failed. Last output:"
      show_log_tail "$install_log"
      error "Zimfw installation failed. See $install_log"
    fi

    success "Zimfw installed"
  else
    success "Zimfw already installed"
  fi

  step "Syncing modules..."
  local sync_log="/tmp/zim-sync.log"
  local sync_pid
  local sync_exit=0

  (
    "$ZSH_PATH" -c 'source "$1/zimfw.zsh" init -q && source "$1/zimfw.zsh" install' _ "$ZIM_HOME"
  ) >"$sync_log" 2>&1 &
  sync_pid=$!

  spinner "$sync_pid" "Installing Zim plugins" || sync_exit=$?
  if [[ $sync_exit -ne 0 ]]; then
    warn "Zim module sync failed. Last output:"
    show_log_tail "$sync_log"
    error "Failed to sync Zim modules. See $sync_log"
  fi

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
  init_ui
  echo -e "\n${BOLD}${CYAN}Dotfiles Setup${NC}"
  echo -e "${DIM}Setting up your development environment...${NC}\n"

  init_paths
  install_homebrew
  install_packages_via_brewfile
  install_rust
  install_node
  install_node_packages
  install_mihomo

  init_submodules

  stow_dotfiles
  install_zim
  setup_local_zshrc
  setup_shell

  echo -e "\n${GREEN}${BOLD}✓ Setup complete!${NC}"
  echo -e "${DIM}Start a fresh zsh session:${NC}"
  echo -e "  ${CYAN}exec zsh -l${NC}"
  echo -e "${DIM}Or reopen your terminal.${NC}\n"
}

main "$@"
