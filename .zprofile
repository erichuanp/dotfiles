# ~/.zprofile — dotfiles 受管（内容对 Linux 无害，两处都有存在性判断）

# Homebrew（Apple Silicon / Intel）
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# OrbStack（装了才有）
source ~/.orbstack/shell/init.zsh 2>/dev/null || :
