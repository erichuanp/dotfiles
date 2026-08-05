# ~/.profile — dotfiles 受管
# 登录 shell 是 sh/dash/bash 时的入口，和 .bashrc 同样的逻辑
case $- in *i*) ;; *) return 2>/dev/null || exit 0 ;; esac

[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" && export PATH

if [ -z "${DOTFILES_NO_EXEC_ZSH:-}" ] && [ -t 1 ] && command -v zsh >/dev/null 2>&1; then
  zsh -c 'exit 0' 2>/dev/null && exec zsh -l
fi

[ -f "$HOME/.profile.local" ] && . "$HOME/.profile.local"
