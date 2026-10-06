#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREW_PATH=""
ZSH_PATH=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

section() { echo -e "\n${CYAN}${BOLD}▸ $*${NC}"; }
step()    { echo -e "${DIM}  →${NC} $*"; }
success() { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
error()   { echo -e "${RED}  ✗${NC} $*"; exit 1; }

# Run a command quietly behind a spinner. On failure, show the end of its output
# and return non-zero, which aborts the script unless the caller handles it.
run() {
  local msg="$1" frames='|/-\' log pid i=0
  shift
  log="$(mktemp)"
  "$@" >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[2K  %s %s' "${frames:i++%4:1}" "$msg"
    sleep 0.1
  done
  printf '\r\033[2K'
  if wait "$pid"; then
    rm -f "$log"
    return
  fi
  warn "$msg failed. Full log: $log"
  tail -n 12 "$log" | sed 's/^/    /'
  return 1
}

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

usage() {
  cat <<'EOF'
Usage:
  bash install.sh                  Install for the current non-root user
  bash install.sh root [username]  Bootstrap Linux from root (default: chijw)
  bash install.sh --help           Show this help

Root mode (apt-get, dnf or yum) creates or reuses a regular user, hands it
/home/linuxbrew/.linuxbrew and a copy of this checkout, then runs the installer
as that user. No password or sudo grant is needed.
EOF
}

install_system_dependencies() {
  section "System Dependencies"
  if command -v apt-get &>/dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential procps curl file git ca-certificates zsh \
      unzip tar gzip passwd util-linux
  elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    "$(command -v dnf || command -v yum)" install -y gcc gcc-c++ make procps-ng \
      curl file git ca-certificates zsh unzip tar gzip shadow-utils util-linux
  else
    error "Root mode requires apt-get, dnf or yum (Alpine/musl is not supported)."
  fi
}

bootstrap_root() {
  local username="$1" brew_prefix=/home/linuxbrew/.linuxbrew
  [[ "$(uname -s)" == Linux ]] || error "Root mode is only supported on Linux."
  [[ "$EUID" -eq 0 ]] || error "Run root mode as root: sudo bash install.sh root $username"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$username" != root ]] || \
    error "Invalid username '$username'."

  install_system_dependencies

  section "User: $username"
  if id "$username" &>/dev/null; then
    [[ "$(id -u "$username")" -ge 1000 && "$(id -u "$username")" -ne 65534 ]] || \
      error "Refusing to use root or a system account: $username"
    success "Reusing existing user"
  else
    useradd --create-home --user-group --shell /bin/bash "$username"
    success "Created user (password login remains locked)"
  fi
  local home group
  home="$(getent passwd "$username" | cut -d: -f6)"
  group="$(id -gn "$username")"
  mkdir -p "$home"
  chown "$username:$group" "$home"

  section "Linuxbrew Directory"
  if [[ -d "$brew_prefix" ]]; then
    local owner
    owner="$(stat -c %u "$brew_prefix")"
    [[ "$owner" == 0 || "$owner" == "$(id -u "$username")" ]] || \
      error "$brew_prefix belongs to another user; rerun root mode with that username."
  fi
  mkdir -p "$brew_prefix"
  # Homebrew refuses to run as root; this also repairs a root-owned installation.
  chown -hR "$username:$group" "$brew_prefix"
  success "$brew_prefix is ready for $username"

  section "User Dotfiles Checkout"
  local target="$home/.dotfiles"
  if [[ -e "$target" ]]; then
    step "Reusing $target; existing files will not be overwritten."
  else
    cp -a "$DOTFILES_DIR" "$target"
    success "Copied checkout to $target"
  fi
  chown -hR "$username:$group" "$target"

  # Start from a clean environment: nothing from root's PATH, Cargo/fnm/XDG
  # directories or shell startup files, only the proxy and mirror settings.
  local name user_env=(
    "HOME=$home" "USER=$username" "LOGNAME=$username" "SHELL=/bin/bash"
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    "TERM=${TERM:-xterm-256color}" "LANG=${LANG:-C.UTF-8}"
    "HOMEBREW_NO_SUDO=1" "DOTFILES_ROOT_SETUP=1"
  )
  for name in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
    HOMEBREW_API_DOMAIN HOMEBREW_BOTTLE_DOMAIN HOMEBREW_BREW_GIT_REMOTE HOMEBREW_CORE_GIT_REMOTE; do
    [[ -z "${!name:-}" ]] || user_env+=("$name=${!name}")
  done
  step "Continuing installation as $username..."
  # Leave /root before dropping privileges: the user cannot traverse it.
  (
    cd "$home"
    runuser -u "$username" -- env -i "${user_env[@]}" /bin/bash "$target/install.sh"
  )

  section "Default Shell"
  local zsh
  zsh="$(find_first_executable "$brew_prefix/bin/zsh" /usr/bin/zsh /bin/zsh)"
  grep -Fxq "$zsh" /etc/shells || echo "$zsh" >> /etc/shells
  usermod --shell "$zsh" "$username"
  success "Setup complete for $username. Switch to the new environment:"
  echo "  su - $username"
}

# Locate brew, and zsh (brew's if present, else the system one).
init_paths() {
  BREW_PATH="$(command -v brew || find_first_executable \
    /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew || true)"
  ZSH_PATH="$(find_first_executable "${BREW_PATH%/*}/zsh" || command -v zsh || echo /bin/zsh)"
}

install_homebrew() {
  section "Homebrew"
  if [[ -z "$BREW_PATH" ]]; then
    run "Installing Homebrew" /bin/bash -o pipefail -c \
      'curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | NONINTERACTIVE=1 /bin/bash'
    init_paths
    [[ -n "$BREW_PATH" ]] || error "Homebrew installed, but brew was not found"
  fi
  success "$("$BREW_PATH" --version | head -1)"
}

install_packages() {
  section "Packages via Brewfile"
  local try=1
  until "$BREW_PATH" bundle install --file="$DOTFILES_DIR/Brewfile" --no-upgrade; do
    (( try++ < 3 )) || error "brew bundle failed after 3 attempts"
    warn "brew bundle failed, retrying ($try/3)..."
    sleep 5
  done
  success "All packages ready"
}

install_rust() {
  section "Rust & Cargo"
  [[ ! -f "$HOME/.cargo/env" ]] || source "$HOME/.cargo/env"
  if ! command -v cargo &>/dev/null; then
    run "Installing Rust toolchain (stable)" /bin/bash -o pipefail -c \
      "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path"
    source "$HOME/.cargo/env"
  fi
  success "$(rustc --version)"
}

install_node() {
  section "Node.js via fnm"
  eval "$("$BREW_PATH" shellenv)"
  command -v fnm &>/dev/null || error "fnm is not installed (it should come from the Brewfile)"
  eval "$(fnm env --shell bash)"
  run "Installing Node.js LTS" fnm install --lts
  fnm default lts-latest
  fnm use lts-latest
  success "$(node --version)"
}

install_node_packages() {
  section "Global npm Packages"
  local pkg
  while read -r pkg _ || [[ -n "$pkg" ]]; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    if run "Installing $pkg" npm install -g "$pkg"; then
      success "$pkg"
    fi
  done < "$DOTFILES_DIR/Npmfile"
}

# Mihomo (Clash.Meta kernel), Linux only. Failures here are not fatal.
install_mihomo() {
  [[ "$(uname -s)" == Linux ]] || return 0
  section "Mihomo (Clash kernel)"
  if command -v mihomo &>/dev/null; then
    success "Already installed — $(mihomo -v 2>/dev/null | head -1)"
    return
  fi

  local arch url bin="$HOME/.local/bin/mihomo"
  case "$(uname -m)" in
    x86_64 | amd64)  arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7l)          arch=armv7 ;;
    i386 | i686)     arch=386 ;;
    *) warn "Unsupported architecture '$(uname -m)'; skipping mihomo"; return ;;
  esac

  # Requiring vX.Y.Z right after the arch selects the plain build and skips the
  # '-v1/-v2/-v3', '-go12x' and '-compatible' variants.
  url="$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
    | grep -oE "https://[^\"]*/mihomo-linux-${arch}-v[0-9]+\.[0-9]+\.[0-9]+\.gz" \
    | head -1 || true)"
  if [[ -z "$url" ]]; then
    warn "Could not resolve mihomo download URL for linux-${arch}; skipping"
    return
  fi

  mkdir -p "${bin%/*}"
  if run "Downloading ${url##*/}" /bin/bash -o pipefail -c 'curl -fsSL "$1" | gunzip >"$2"' _ "$url" "$bin"; then
    chmod +x "$bin"
    success "Installed to $bin"
  else
    rm -f "$bin"
  fi
}

stow_dotfiles() {
  section "Stowing Dotfiles"
  eval "$("$BREW_PATH" shellenv)"
  run "Updating submodules" git -C "$DOTFILES_DIR" submodule update --init --recursive
  mkdir -p "$HOME/.config"

  local pkg
  for pkg in tmux zim nvim yazi pip wezterm zsh kitty; do
    stow --restow --dir="$DOTFILES_DIR" --target="$HOME" \
      --ignore='(^|/)\.git$' --ignore='(^|/)\.DS_Store$' --ignore='(^|/)\.nvimlog$' \
      "$pkg" || error "Failed to stow '$pkg'"
    step "$pkg"
  done
  success "All dotfiles linked"
}

install_zim() {
  section "Zim & Plugins"
  export ZIM_HOME="${ZDOTDIR:-$HOME}/.zim"
  if [[ ! -d "$ZIM_HOME" ]]; then
    run "Installing Zimfw" /bin/bash -o pipefail -c \
      'curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | "$1"' _ "$ZSH_PATH"
  fi
  run "Installing Zim modules" "$ZSH_PATH" -c \
    'source "$1/zimfw.zsh" init -q && source "$1/zimfw.zsh" install' _ "$ZIM_HOME"
  success "All modules synced"
}

# Append line $2 to ~/.zshrc unless $1 already appears there.
add_to_zshrc() {
  grep -qF -- "$1" "$HOME/.zshrc" && return
  echo "$2" >> "$HOME/.zshrc"
  step "Added: $2"
}

# Runs after install_zim so ~/.zshrc.local is sourced below the Zim bootstrap
# block and its zle/bindkey customizations apply after Zim init.
setup_zshrc() {
  section "Configuring ~/.zshrc"
  touch "$HOME/.zshrc"
  local brew_env="eval \"\$($BREW_PATH shellenv)\""
  add_to_zshrc "$brew_env" "$brew_env"
  add_to_zshrc '$HOME/.local/bin' 'export PATH="$HOME/.local/bin:$PATH"'
  add_to_zshrc '.cargo/env' '[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"'
  add_to_zshrc 'fnm env' 'eval "$(fnm env --use-on-cd)"'
  add_to_zshrc '.zshrc.local' '[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"'
  success "Configured"
}

setup_shell() {
  section "Default Shell"
  if [[ "$SHELL" == */zsh ]]; then
    success "Already set to zsh"
    return
  fi
  if ! grep -Fxq "$ZSH_PATH" /etc/shells; then
    warn "Adding $ZSH_PATH to /etc/shells (requires sudo)..."
    echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null
  fi
  chsh -s "$ZSH_PATH" && success "Default shell changed to zsh" || \
    warn "Failed to change shell. Run manually: chsh -s $ZSH_PATH"
}

main() {
  case "${1:-}" in
    root)
      [[ $# -le 2 ]] || error "Usage: bash install.sh root [username]"
      bootstrap_root "${2-chijw}"
      return
      ;;
    -h|--help) usage; return ;;
    "") ;;
    *) usage; error "Unknown argument: $1" ;;
  esac
  [[ "$EUID" -ne 0 ]] || error "Use 'bash install.sh root [username]' when running as root."

  echo -e "\n${BOLD}${CYAN}Dotfiles Setup${NC}"
  export PATH="$HOME/.local/bin:$PATH"

  init_paths
  install_homebrew
  install_packages
  init_paths
  install_rust
  install_node
  install_node_packages
  install_mihomo
  stow_dotfiles
  install_zim
  setup_zshrc

  # In root mode the root parent sets the login shell, without a password.
  if [[ "${DOTFILES_ROOT_SETUP:-0}" == 1 ]]; then
    success "User environment installed; returning to root to set the login shell."
    return
  fi
  setup_shell

  echo -e "\n${GREEN}${BOLD}✓ Setup complete!${NC}"
  echo -e "${DIM}Start a fresh zsh session:${NC} exec zsh -l\n"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
