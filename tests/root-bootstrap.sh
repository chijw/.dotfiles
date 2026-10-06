#!/usr/bin/env bash
# Run only in a disposable container:
# docker run --rm -v "$PWD:/src:ro" debian:bookworm-slim bash /src/tests/root-bootstrap.sh
set -euo pipefail
[[ -f /.dockerenv && "$EUID" -eq 0 ]] || {
  echo "This integration test requires root inside a disposable Docker container." >&2
  exit 1
}

INSTALLER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install.sh"
# shellcheck source=../install.sh
source "$INSTALLER"
install_system_dependencies >/tmp/bootstrap-dependencies.log 2>&1
apt-get install -y --no-install-recommends stow >/tmp/bootstrap-stow.log 2>&1

fixture=/root/bootstrap-fixture
mkdir -p "$fixture/sample" /root/bootstrap-submodule
git init -q /root/bootstrap-submodule
git -C /root/bootstrap-submodule -c user.name=Test -c user.email=test@example.com \
  commit -qm initial --allow-empty
git init -q "$fixture"
git -C "$fixture" -c protocol.file.allow=always submodule add -q /root/bootstrap-submodule submodule
printf 'test configuration\n' >"$fixture/sample/.bootstrap-example"
touch "$fixture/Brewfile"
cat >"$fixture/install.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$EUID" -ne 0 && "$USER" != root && "$LOGNAME" == "$USER" ]]
[[ "$HOME" == "$(getent passwd "$USER" | cut -d: -f6)" ]]
[[ "$PWD" == "$HOME" && "$SHELL" == /bin/bash ]]
[[ "$DOTFILES_ROOT_SETUP" == 1 && "$HOMEBREW_NO_SUDO" == 1 ]]
[[ -z "${CARGO_HOME:-}${XDG_CONFIG_HOME:-}${ZDOTDIR:-}" ]]
[[ "$PATH" != *"/root"* && "$http_proxy" == http://proxy.example:7890 ]]
[[ -w /home/linuxbrew/.linuxbrew ]]
touch /home/linuxbrew/.linuxbrew/installed-by-user
git -C "$HOME/.dotfiles" status --porcelain >/dev/null
git -C "$HOME/.dotfiles" submodule update --init --recursive
git -C "$HOME/.dotfiles/submodule" status --porcelain >/dev/null
stow --restow --dir="$HOME/.dotfiles" --target="$HOME" sample
printf '%s\n' "$USER" >"$HOME/bootstrap-ran"
EOF
git -C "$fixture" add .
git -C "$fixture" -c user.name=Test -c user.email=test@example.com commit -qm initial
printf 'uncommitted local edit\n' >"$fixture/local-edit"
chmod 0700 /root

export CARGO_HOME=/root/.cargo XDG_CONFIG_HOME=/root/.config ZDOTDIR=/root
export http_proxy=http://proxy.example:7890

run_installer() {
  # Use a separate bash so each invocation retains normal errexit semantics.
  # Dependency installation above is real; expensive user downloads are replaced
  # by the fixture, while user creation, copying, permissions, Git and Stow are real.
  bash -c 'source "$1"; install_system_dependencies() { :; }; DOTFILES_DIR=/root/bootstrap-fixture; main "${@:2}"' \
    _ "$INSTALLER" "$@"
}

expect_failure() {
  local expected="$1"
  shift
  if "$@" >/tmp/bootstrap-failure.log 2>&1; then
    echo "Unexpected success: $*" >&2
    exit 1
  fi
  grep -Fq "$expected" /tmp/bootstrap-failure.log
}

expect_failure 'when running as root' bash "$INSTALLER"
expect_failure 'Invalid username' run_installer root root
expect_failure 'Invalid username' run_installer root 'bad/name'
expect_failure 'Invalid username' run_installer root ''
expect_failure 'system account' run_installer root daemon
expect_failure 'Usage:' run_installer root alice extra
expect_failure 'Unknown argument' run_installer unknown

run_installer root >/tmp/bootstrap-default.log
[[ "$(cat /home/chijw/bootstrap-ran)" == chijw ]]
[[ "$(getent passwd chijw | cut -d: -f7)" == /usr/bin/zsh ]]
[[ "$(stat -c %U /home/linuxbrew/.linuxbrew/installed-by-user)" == chijw ]]
[[ "$(stat -c %U /home/chijw/.dotfiles/.git/config)" == chijw ]]
[[ "$(stat -c %U "$fixture/.git/config")" == root ]]
[[ "$(stat -c %a /root)" == 700 ]]
[[ -L /home/chijw/.bootstrap-example ]]
cmp "$fixture/local-edit" /home/chijw/.dotfiles/local-edit
[[ "$(getent shadow chijw | cut -d: -f2)" == '!'* ]]
expect_failure 'Run root mode as root' runuser -u chijw -- bash "$INSTALLER" root
echo 'PASS: default username, privilege drop, isolated environment, copy and submodules'

printf 'preserve user changes\n' >/home/chijw/.dotfiles/local-edit
chown -hR root:root /home/linuxbrew/.linuxbrew
run_installer root >/tmp/bootstrap-repeat.log
grep -Fq 'preserve user changes' /home/chijw/.dotfiles/local-edit
[[ "$(stat -c %U /home/linuxbrew/.linuxbrew)" == chijw ]]
echo 'PASS: repeat installation preserves edits and repairs root-owned Linuxbrew'

expect_failure 'belongs to another user' run_installer root alice
[[ "$(stat -c %U /home/linuxbrew/.linuxbrew)" == chijw ]]
mv /home/linuxbrew/.linuxbrew /home/linuxbrew/chijw-test-backup
run_installer root alice >/tmp/bootstrap-custom.log
[[ "$(cat /home/alice/bootstrap-ran)" == alice ]]
[[ "$(getent passwd alice | cut -d: -f7)" == /usr/bin/zsh ]]
echo "PASS: custom/existing user and protection of another user's Linuxbrew"

usermod --shell /bin/bash alice
printf '#!/bin/bash\nexit 42\n' >/home/alice/.dotfiles/install.sh
set +e
run_installer root alice >/tmp/bootstrap-child-failure.log 2>&1
status=$?
set -e
[[ "$status" == 42 ]]
[[ "$(getent passwd alice | cut -d: -f7)" == /bin/bash ]]
! grep -Fq 'Setup complete' /tmp/bootstrap-child-failure.log
echo 'PASS: child failure propagates and does not report success or change shell'

# No credential or sudo policy files are created by the bootstrap.
[[ ! -e /home/chijw/.ssh && ! -e /home/alice/.ssh ]]
[[ ! -e /etc/sudoers.d/chijw && ! -e /etc/sudoers.d/alice ]]

# fnm activation must happen in the calling shell, after the background download.
BREW_PATH=/bin/true
fnm() {
  case "$1" in
    env) printf ':\n' ;;
    install) return 0 ;;
    default) printf '%s\n' "$2" >/tmp/bootstrap-node-default ;;
    use) NODE_ACTIVE=1 ;;
    *) return 1 ;;
  esac
}
node() { [[ "${NODE_ACTIVE:-0}" == 1 ]] && echo v24.test; }
install_node >/tmp/bootstrap-node.log
[[ "$NODE_ACTIVE" == 1 && "$(cat /tmp/bootstrap-node-default)" == lts-latest ]]
echo 'PASS: Node LTS activation and default persist beyond the download subshell'
echo 'All root bootstrap integration checks passed.'
