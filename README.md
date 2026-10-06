# .dotfiles

Personal dotfiles. Managed with stow.

## Setup

```bash
git clone --recursive https://github.com/chijw/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles
bash install.sh
exec zsh -l
```

From root (Linux with apt/dnf/yum):

```bash
bash install.sh root          # default user: chijw
# bash install.sh root alice  # custom username
su - chijw
```
