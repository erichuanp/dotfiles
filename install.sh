#!/bin/sh
# dotfiles 引导。仓库是 bare git repo，$HOME 就是工作区，所以改了什么 `dot status` 直接看得见。
#
#   curl -fsSL https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.sh | sh
#
# 非交互环境（容器构建）自动按容器级安装。要跳过提问：DOTFILES_TIER=2 curl ... | sh
set -eu

REPO="${DOTFILES_REPO:-https://github.com/erichuanp/dotfiles.git}"
GITDIR="$HOME/.dotfiles"
BACKUP="$HOME/.dotfiles-backup"
BIN="$HOME/.local/bin"

dot() { git --git-dir="$GITDIR" --work-tree="$HOME" "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
say() { echo "[dotfiles] $*"; }

have git || { echo "需要 git，先装 git" >&2; exit 1; }

# ---------- 分级 ----------
# 三级共用的：纯配置，任何机器都无害
COMMON='.zshrc .bashrc .profile .zprofile .tmux.conf .gitconfig .gitignore_global .vimrc .inputrc'
# 真机才要的：容器里没意义
HOSTONLY='.condarc .hushlogin .local/bin/dotup .local/bin/sfp'
# 只有个人设备：ssh config 是加密的，authorized_keys 是我自己的门
PERSONAL='.ssh/authorized_keys.enc .ssh/config.enc'

tier="${DOTFILES_TIER:-}"
if [ -z "$tier" ]; then
  if [ -r /dev/tty ]; then
    {
      echo "  1) 个人设备      —— 全套，含 ssh config（需密码解密）+ authorized_keys"
      echo "  2) 公司个人用户  —— 除 ssh 相关外全套"
      echo "  3) 容器          —— 只有 shell/git/tmux 配置"
      printf '选择 [1/2/3]: '
    } > /dev/tty
    read -r tier < /dev/tty
  else
    tier=3
    say "无 tty，按容器级安装"
  fi
fi

case "$tier" in
  1) FILES="$COMMON $HOSTONLY $PERSONAL" ;;
  2) FILES="$COMMON $HOSTONLY" ;;
  3) FILES="$COMMON" ;;
  *) echo "无效选择：$tier" >&2; exit 1 ;;
esac
say "分级 $tier"

# ---------- 取仓库 ----------
if [ -d "$GITDIR" ]; then
  say "已存在 $GITDIR，只更新分级与工作区（不动本地改动）"
  dot fetch -q origin || say "WARN: fetch 失败，用本地副本继续"
else
  git clone --bare -q "$REPO" "$GITDIR"
fi

dot config core.bare false
dot config core.worktree "$HOME"
# 否则 `dot status` 会把整个家目录当未跟踪文件列出来
dot config status.showUntrackedFiles no
dot config core.sparseCheckout true
dot config core.sparseCheckoutCone false
: > "$GITDIR/info/sparse-checkout"
for f in $FILES; do echo "$f" >> "$GITDIR/info/sparse-checkout"; done

# 安全网：仓库是公开的，明文 ssh config 绝不能被 `dot add -A` 顺手带进去
cat > "$GITDIR/info/exclude" <<'EXC'
/.ssh/config
/.ssh/authorized_keys
/.ssh/id_*
/.ssh/known_hosts*
/.zshrc.local
/.bashrc.local
/.profile.local
/.gitconfig.local
EXC

# ---------- 覆盖前先备份 ----------
# checkout -f 会直接盖掉同名文件，所以先原样存一份，出事能捞回来
for f in $FILES; do
  [ -e "$HOME/$f" ] || continue
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp -p "$HOME/$f" "$BACKUP/$f"
done
[ -d "$BACKUP" ] && say "旧文件已备份到 $BACKUP"

dot checkout -f
dot reset -q

# ---------- 权限 ----------
[ -d "$HOME/.ssh" ] && chmod 700 "$HOME/.ssh"
chmod +x "$BIN/dotup" "$BIN/sfp" 2>/dev/null || :

# ---------- 解密 ssh config（仅个人级） ----------
# 密码不是"检查"，是解密钥匙本身：错了就解不出东西，没有分支可以绕过。
if [ "$tier" = 1 ]; then
  printf '解密密码（ssh config / authorized_keys）: ' > /dev/tty
  stty -echo < /dev/tty 2>/dev/null || :
  read -r _pw < /dev/tty
  stty echo < /dev/tty 2>/dev/null || :
  printf '\n' > /dev/tty
  # 密码错了就是解不出东西 —— 没有"检查"这一步可以被绕过
  for _n in config authorized_keys; do
    [ -f "$HOME/.ssh/$_n.enc" ] || continue
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "pass:$_pw" \
         -in "$HOME/.ssh/$_n.enc" -out "$HOME/.ssh/$_n.new" 2>/dev/null; then
      mv "$HOME/.ssh/$_n.new" "$HOME/.ssh/$_n"
      chmod 600 "$HOME/.ssh/$_n"
      say "$_n 已解密"
    else
      mv -f "$HOME/.ssh/$_n.new" "$BACKUP/$_n.failed" 2>/dev/null || :
      unset _pw
      echo "密码错误，$_n 未写入" >&2
      exit 1
    fi
  done
  unset _pw
fi

# ---------- 装工具 ----------
mkdir -p "$BIN"
PATH="$BIN:$PATH"

# 架构与下载助手：两个 OS 都要用，所以必须定义在 case 之前
os=$(uname -s)
case "$(uname -m)" in
  x86_64|amd64)  a1=x86_64  a2=amd64 rgl=musl ;;
  aarch64|arm64) a1=aarch64 a2=arm64 rgl=gnu  ;;
  *)             a1=""      a2=""    rgl=""   ;;
esac
case "$os" in Darwin) osname=macos ;; Linux) osname=linux ;; *) osname="" ;; esac

# 取 releases/latest 的重定向拿版本号，不碰 GitHub API，免限流
ghtag() {
  curl -fsSLI --retry 3 --connect-timeout 10 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$1/releases/latest" | grep -o '/tag/[^/]*$' | sed 's#.*/tag/##'
}
# ghbin <repo> <tar.gz 资产名，TAG/VER 占位> <二进制名>
ghbin() {
  [ -n "$a1" ] || return 0
  tag=$(ghtag "$1"); [ -n "$tag" ] || { say "WARN: $3 版本探测失败"; return 0; }
  asset=$(printf '%s' "$2" | sed "s/TAG/$tag/g; s/VER/${tag#v}/g")
  t=$(mktemp -d)
  curl -fsSL --retry 3 --connect-timeout 10 \
    "https://github.com/$1/releases/download/$tag/$asset" | tar -xz -C "$t" 2>/dev/null || :
  f=$(find "$t" -type f -name "$3" | head -1)
  if [ -n "$f" ]; then install -m755 "$f" "$BIN/$3" && say "$3 $tag -> $BIN/$3"
  else say "WARN: $3 下载失败 ($asset)"; fi
  rm -rf "$t"
}
# ghraw <repo> <裸二进制资产名，TAG/VER 占位> <二进制名>
ghraw() {
  [ -n "$a2" ] && [ -n "$osname" ] || return 0
  tag=$(ghtag "$1"); [ -n "$tag" ] || { say "WARN: $3 版本探测失败"; return 0; }
  asset=$(printf '%s' "$2" | sed "s/TAG/$tag/g; s/VER/${tag#v}/g")
  if curl -fsSL --retry 3 --connect-timeout 10 \
       "https://github.com/$1/releases/download/$tag/$asset" -o "$BIN/$3.part"; then
    chmod +x "$BIN/$3.part" && mv "$BIN/$3.part" "$BIN/$3" && say "$3 $tag -> $BIN/$3"
  else
    say "WARN: $3 下载失败 ($asset)"
  fi
}

case "$(uname -s)" in
Darwin)
  if ! have brew && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
    say "installing homebrew"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || say "WARN: homebrew install failed"
  fi
  have brew || { [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"; } || :
  have brew || { [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"; } || :
  if have brew; then
    for pkg in zsh tmux fzf ripgrep lsd git-lfs gh node; do
      brew list "$pkg" >/dev/null 2>&1 || brew install "$pkg"
    done
  else
    say "WARN: brew 不可用，跳过工具安装"
  fi
  MINICONDA_OS=MacOSX
  ;;
Linux)
  have lsd || ghbin lsd-rs/lsd         "lsd-TAG-$a1-unknown-linux-musl.tar.gz"     lsd
  have rg  || ghbin BurntSushi/ripgrep "ripgrep-VER-$a1-unknown-linux-$rgl.tar.gz" rg
  have fzf || ghbin junegunn/fzf       "fzf-VER-linux_$a2.tar.gz"                  fzf
  if [ "$tier" != 3 ]; then
    have gh      || ghbin cli/cli         "gh_VER_linux_$a2.tar.gz"        gh
    have git-lfs || ghbin git-lfs/git-lfs "git-lfs-linux-$a2-TAG.tar.gz"   git-lfs
  fi
  # 全局基础件：只有缺了才装。非 root 问一次 sudo，拿不到就跳过，绝不中断
  base=""
  for p in zsh tmux vim curl; do have "$p" || base="$base $p"; done
  if [ -n "$base" ]; then
    SUDO=""; ok=yes
    if [ "$(id -u)" -ne 0 ]; then
      say "安装$base 需要 sudo（失败则跳过）"
      sudo -v 2>/dev/null && SUDO="sudo" || ok=no
    fi
    if [ "$ok" = yes ] && have apt-get; then
      { $SUDO apt-get update -qq && $SUDO apt-get install -y $base; } || say "WARN: apt 失败:$base"
    elif [ "$ok" = yes ] && have apk; then
      $SUDO apk add --no-cache $base || say "WARN: apk 失败:$base"
    else
      say "WARN: 跳过（需 sudo）:$base"
    fi
  fi
  MINICONDA_OS=Linux
  ;;
esac

# oh-my-zsh + 两个插件（三级都要，容器也要）
ZSH_DIR="$HOME/.oh-my-zsh"
[ -d "$ZSH_DIR" ] || git clone --depth 1 -q https://github.com/ohmyzsh/ohmyzsh.git "$ZSH_DIR" \
  || say "WARN: oh-my-zsh clone 失败"
for p in zsh-users/zsh-autosuggestions zsh-users/zsh-syntax-highlighting; do
  d="$ZSH_DIR/custom/plugins/${p#*/}"
  [ -d "$d" ] || git clone --depth 1 -q "https://github.com/$p" "$d" || say "WARN: ${p#*/} clone 失败"
done

# 以下只有真机要
if [ "$tier" != 3 ]; then
  # sshow：和 ssh config 配套，pip 装，三端同一个命令
  have sshow || pip install --user --quiet sshow 2>/dev/null || pip3 install --user --quiet sshow 2>/dev/null \
    || say "WARN: sshow 安装失败（需要 pip）"

  # dops：裸二进制，两个 OS 都有
  have dops || ghraw Mikescher/better-docker-ps "dops_${osname}-${a2}" dops

  # node（nvm，用户态）。nvm 不兼容 dash，必须经 bash
  if ! have node && [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL --connect-timeout 10 --retry 2 https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash \
      && bash -c '. "$HOME/.nvm/nvm.sh" && nvm install --lts' \
      || say "WARN: node(nvm) 安装失败"
  fi

  # miniconda：任何位置已有 conda 就跳过
  conda_found=no
  for d in "$HOME/miniconda3" "$HOME/anaconda3" /opt/miniconda3 /opt/anaconda3; do
    [ -f "$d/etc/profile.d/conda.sh" ] && conda_found=yes && break
  done
  if [ "$conda_found" = no ] && [ -n "${MINICONDA_OS:-}" ]; then
    say "installing miniconda -> ~/miniconda3"
    curl -fsSL "https://repo.anaconda.com/miniconda/Miniconda3-latest-$MINICONDA_OS-$(uname -m).sh" -o /tmp/miniconda.sh \
      && bash /tmp/miniconda.sh -b -p "$HOME/miniconda3" \
      && rm -f /tmp/miniconda.sh \
      || say "WARN: miniconda 安装失败"
  fi
fi

say "完成。用 \`dot status\` 看改动，\`exec zsh\` 进新环境。"
