# ~/.zshrc — dotfiles 受管（bare repo：$HOME 就是工作区，改了 `dot status` 直接看得见）
# 本机私货写 ~/.zshrc.local，那个文件永不纳管、永不被覆盖

export SHELL=/bin/zsh

# ---- locale: 选可用的 UTF-8，避免 LC_ALL 报错
if locale -a 2>/dev/null | grep -Eq '^en_US\.UTF-8$|^en_US\.utf8$'; then
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
elif locale -a 2>/dev/null | grep -Eq '^C\.UTF-8$|^C\.utf8$'; then
  export LANG=C.UTF-8
  export LC_ALL=C.UTF-8
fi

# ---- PATH（-g：保证在函数内被 source 时仍操作全局 PATH）
typeset -gU path PATH
[ -d "$HOME/bin" ] && path=("$HOME/bin" $path)
[ -d "$HOME/.local/bin" ] && path=("$HOME/.local/bin" $path)
[ -d "$HOME/.npm-global/bin" ] && path=("$HOME/.npm-global/bin" $path)
# pip --user 的 bin（sshow 装这）；macOS 是 ~/Library/Python/*/bin，Linux 已在 ~/.local/bin
for _py_user_bin in "$HOME"/Library/Python/*/bin(N); do
  path=("$_py_user_bin" $path)
done
unset _py_user_bin

# ---- fzf 环境
export FZF_DEFAULT_COMMAND='rg --files --hidden --follow --glob "!.git/*"'
export FZF_CTRL_R_OPTS="--preview 'echo {}'"

# ---- oh-my-zsh（没装就整段跳过，新机首次进 shell 不报错）
export ZSH="$HOME/.oh-my-zsh"
if [ -r "$ZSH/oh-my-zsh.sh" ]; then
  ZSH_THEME="robbyrussell"
  plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
  )
  source "$ZSH/oh-my-zsh.sh"
fi

# ---- fzf keybindings（按安装位置探测）
for _fzf_file in \
  /opt/homebrew/opt/fzf/shell/completion.zsh \
  /usr/local/opt/fzf/shell/completion.zsh \
  /usr/share/doc/fzf/examples/completion.zsh \
  /usr/share/fzf/completion.zsh; do
  [ -r "$_fzf_file" ] && source "$_fzf_file" && break
done
for _fzf_file in \
  /opt/homebrew/opt/fzf/shell/key-bindings.zsh \
  /usr/local/opt/fzf/shell/key-bindings.zsh \
  /usr/share/doc/fzf/examples/key-bindings.zsh \
  /usr/share/fzf/key-bindings.zsh; do
  [ -r "$_fzf_file" ] && source "$_fzf_file" && break
done
unset _fzf_file
# 防插件抢回 ^R
autoload -Uz add-zsh-hook
_rebind_fzf_ctrl_r() {
  if zle -la 2>/dev/null | grep -qx 'fzf-history-widget'; then
    bindkey '^R' fzf-history-widget
  fi
}
add-zsh-hook -Uz precmd _rebind_fzf_ctrl_r
_rebind_fzf_ctrl_r

# ---- prompt: (conda) 主机名:父目录/当前目录/  SSH=绿 本机=黄
function prompt_setup() {
  local conda_part=""
  if [[ -n "$CONDA_DEFAULT_ENV" ]]; then
    conda_part="%F{cyan}($CONDA_DEFAULT_ENV)%f "
  fi

  local hostname_color
  if [[ -n "$SSH_CONNECTION" || -n "$SSH_CLIENT" || -n "$SSH_TTY" ]]; then
    hostname_color="%F{green}%m%f:"
  else
    hostname_color="%F{yellow}%m%f:"
  fi

  local path_display="" parent_dir="" current_dir=""
  if [[ "$PWD" == "/" ]]; then
    path_display=" %F{cyan}//%f "
  elif [[ "${PWD#/}" != */* ]]; then
    path_display=" %F{cyan}/%f%F{cyan}${PWD#/}/%f "
  else
    parent_dir="${PWD:h:t}"
    current_dir="${PWD:t}"
    path_display=" %F{cyan}${parent_dir}/%f%F{cyan}${current_dir}/%f "
  fi

  PROMPT="${conda_part}${hostname_color}${path_display}"
}
add-zsh-hook precmd prompt_setup

# ---- history
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_FIND_NO_DUPS
setopt SHARE_HISTORY
HISTFILE=$HOME/.zsh_history
HISTSIZE=10000
SAVEHIST=10000

autoload -Uz compinit && compinit

# ---- aliases
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias claude='claude --dangerously-skip-permissions'
alias update='dotup'

alias ls='lsd'
alias ll='lsd -la'
lst() {
  if [ $# -eq 0 ]; then
    lsd --tree
  else
    lsd --tree --depth "$1"
  fi
}
# ---- conda：取第一个命中的安装位置；不自动激活 base
for _conda_root in "$HOME/miniconda3" "$HOME/anaconda3" /opt/miniconda3 /opt/anaconda3; do
  if [ -f "$_conda_root/etc/profile.d/conda.sh" ]; then
    . "$_conda_root/etc/profile.d/conda.sh"
    break
  fi
done
unset _conda_root

# ---- nvm（装了才生效）
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# ---- dot：操作 dotfiles 仓库。$HOME 就是工作区，所以 `dot status` = 真实漂移
dot() {
  if [[ "${1:-}" == h ]]; then
    cat <<'DOTHELP'
Stage Files:
# 对于无 SSH 的改动
dot status  # 目前的改动
dot add -u  # 将改动添加
# 对于有 SSH 的改动
dotseal

Push:
dot commit -m "提交信息"
dot remote set-url origin git@github.com:erichuanp/dotfiles.git  # 只需跑一次
dot push

Pull:
dot pull
# 如果有 SSH 的改动
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in ~/.ssh/config.enc -out ~/.ssh/config
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in ~/.ssh/authorized_keys.enc -out ~/.ssh/authorized_keys
chmod 600 ~/.ssh/config ~/.ssh/authorized_keys
# 重新进 Shell

如果有不想纳管的文件，请用 *.local 来 append 到已纳管文件。
  ~/.zshrc.local  ~/.bashrc.local  ~/.profile.local  ~/.gitconfig.local
DOTHELP
    return 0
  fi
  git --git-dir="$HOME/.dotfiles" --work-tree="$HOME" "$@"
}

# ---- dotseal：把明文 ~/.ssh/{config,authorized_keys} 重新加密回仓库
#      改完必须跑一次，否则提交上去的还是旧密文
dotseal() {
  local n ok=0
  for n in config authorized_keys; do
    [ -f "$HOME/.ssh/$n" ] || continue
    openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
      -in "$HOME/.ssh/$n" -out "$HOME/.ssh/$n.enc" || return 1
    dot add "$HOME/.ssh/$n.enc" && ok=1
  done
  (( ok )) || { echo "没有可加密的文件"; return 1; }
  echo "已加密并 staged，接着 dot commit && dot push"
}

# ---- zshrc 工具：zshrc=重载(print -z 预填,回车全局生效)  vim/nano=编辑 .zshrc.local
#      "命令"/文件=追加进 .zshrc.local（不纳管，永不被覆盖）
zshrc() {
  local rc="$HOME/.zshrc" lc="$HOME/.zshrc.local" line
  _zshrc_add() {
    [ -n "$1" ] || return 0
    grep -qxF "$1" "$lc" 2>/dev/null || printf '%s\n' "$1" >> "$lc"
  }
  case "${1:-}" in
    "")    print -z "source $rc" ;;
    vim)   vim "$lc" ;;
    nano)  nano "$lc" ;;
    *)
      if [ $# -eq 1 ] && [ -f "$1" ]; then
        while IFS= read -r line; do _zshrc_add "$line"; done < "$1"
      else
        _zshrc_add "$*"
      fi
      print -z "source $rc"
      ;;
  esac
}

# ============================================================
# 标准命令包装 —— 必须放在最底下
# 上面的 oh-my-zsh / compinit 等启动代码里会调 mkdir、cd，
# 定义在它们之后，那些代码就只会碰到真命令。
#
# 每个包装第一行都先问一句：是人在命令行敲的吗？
#   ${#funcstack} == 1  → 是，走包装
#   否则（脚本里、函数里、被 source 的文件里）→ 原样转发给原生命令
# 这样脚本拿到的永远是标准行为：mkdir 不会被偷加 -p，docker ps 不会变成
# dops（输出格式不同会把解析脚本搞挂），cd 不会往 stdout 吐一屏文件名。
# 想在命令行强制走原生：command mkdir / builtin cd。
# ============================================================

cd() {
  (( ${#funcstack} == 1 )) || { builtin cd "$@"; return }
  builtin cd "$@" || return
  ls
  return 0
}

mkdir() {
  (( ${#funcstack} == 1 )) || { command mkdir "$@"; return }
  command mkdir -p "$@" || return
  local dirs=(${@:#-*})
  (( $#dirs == 1 )) && [[ -o interactive ]] && cd -- $dirs[1]
  return 0
}

# docker ps -> dops（better-docker-ps）。没装 dops 就原样透传
docker() {
  (( ${#funcstack} == 1 )) || { command docker "$@"; return }
  if [[ "$1" == "ps" ]] && command -v dops >/dev/null 2>&1; then
    shift
    DOCKER_HOST=${DOCKER_HOST:-unix://$HOME/.orbstack/run/docker.sock} dops "$@"
  else
    command docker "$@"
  fi
}

# ---- 本机私有补充（必须放最后：让本机能覆盖上面任何设定）
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
