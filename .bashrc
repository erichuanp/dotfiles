# ~/.bashrc — dotfiles 受管
# 作用：在无 sudo（改不了 /etc/shells、chsh 不了）的机器上，把交互式 bash 换成 zsh。

# 非交互（scp / rsync / ssh 带命令）必须立刻退出，否则文件传输会被 exec 打断
case $- in *i*) ;; *) return ;; esac

# 逃生口：zsh 坏了就 DOTFILES_NO_EXEC_ZSH=1 ssh xxx
if [ -z "${DOTFILES_NO_EXEC_ZSH:-}" ] && [ -t 1 ] && command -v zsh >/dev/null 2>&1; then
  # 先试跑一次再 exec —— exec 会替换掉当前进程，zsh 起不来就等于把自己关在门外
  zsh -c 'exit 0' 2>/dev/null && exec zsh -l
fi

[ -f "$HOME/.bashrc.local" ] && . "$HOME/.bashrc.local"
