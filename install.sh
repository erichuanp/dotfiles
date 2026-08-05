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

# 所有网络操作都必须有上限。只设 connect-timeout 不够 —— 连上之后传输停滞会永远挂着
CURL_T='--connect-timeout 10 --max-time 300 --retry 2'
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30

dot() { git --git-dir="$GITDIR" --work-tree="$HOME" "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
say() { echo "[dotfiles] $*"; }
phase() { echo; echo "== $* =="; }
# step 只打印前缀不换行；卡住时你会看到一行没有结果的输出，一眼知道卡在哪
step() { printf '  %-32s' "$1 ..."; }
okmsg() { echo "$1"; }

have git || { echo "需要 git，先装 git" >&2; exit 1; }

# ---------- 分级 ----------
COMMON='.zshrc .bashrc .profile .zprofile .tmux.conf .gitconfig .gitignore_global .vimrc .inputrc'
HOSTONLY='.condarc .hushlogin .local/bin/dotup .local/bin/sfp'
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
say "分级 $tier   $(uname -s) $(uname -m)"

# ---------- 0/5 GitHub 可达性 ----------
# 国内机器 github.com:443 通常不通，但 raw / api / codeload / ssh:443 都通。
# 探一次，不通就把所有 github.com 的 URL 走代理；push 走 ssh:443（代理是只读的）。
phase "0/5 网络"
GHPROXY="${DOTFILES_GH_PROXY:-https://ghfast.top}"
step "github.com 直连"
# 超时给足：树莓派 / 弱网过旁路由时会慢，宁可多等也不要误判成被墙
if curl -fsS -o /dev/null --connect-timeout 10 --max-time 25 --retry 1 https://github.com/ 2>/dev/null; then
  GHMODE=direct; okmsg "通"
else
  GHMODE=proxy; okmsg "不通，改走 $GHPROXY"
fi
ghurl() {
  case "$1" in
    https://github.com/*) [ "$GHMODE" = proxy ] && echo "$GHPROXY/$1" || echo "$1" ;;
    *) echo "$1" ;;
  esac
}

# ---------- 1/5 取仓库 ----------
phase "1/5 取仓库"
if [ -d "$GITDIR" ]; then
  step "已存在，fetch 更新"
  if dot fetch -q origin 2>/dev/null; then okmsg "OK"; else okmsg "失败（用本地副本继续）"; fi
else
  step "clone 仓库"
  if _out=$(git clone --bare -q "$(ghurl "$REPO")" "$GITDIR" 2>&1); then okmsg "OK"
  else okmsg "失败"; echo "$_out" | head -4 | sed 's/^/        /'; exit 1; fi
fi
# 代理是只读的，push 必须走 ssh:443（国内唯一能连通 GitHub 的写入通道）
if [ "$GHMODE" = proxy ]; then
  dot remote set-url --push origin ssh://git@ssh.github.com:443/erichuanp/dotfiles.git 2>/dev/null || :
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
say "分级清单已写入（$(echo $FILES | wc -w | tr -d ' ') 个文件）"

# ---------- 2/5 铺文件 ----------
phase "2/5 铺文件"
step "备份同名旧文件"
_n=0
for f in $FILES; do
  [ -e "$HOME/$f" ] || continue
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp -p "$HOME/$f" "$BACKUP/$f"
  _n=$((_n+1))
done
okmsg "$_n 个 -> $BACKUP"

step "checkout"
if _out=$(dot checkout -f 2>&1); then okmsg "OK"
else okmsg "失败"; echo "$_out" | head -6 | sed 's/^/        /'; exit 1; fi
dot reset -q

[ -d "$HOME/.ssh" ] && chmod 700 "$HOME/.ssh"
chmod +x "$BIN/dotup" "$BIN/sfp" 2>/dev/null || :

# ---------- 3/5 解密 ----------
phase "3/5 解密（仅 1 级）"
if [ "$tier" = 1 ]; then
  printf '解密密码（ssh config / authorized_keys）: ' > /dev/tty
  stty -echo < /dev/tty 2>/dev/null || :
  read -r _pw < /dev/tty
  stty echo < /dev/tty 2>/dev/null || :
  printf '\n' > /dev/tty
  # 密码不是"检查"，是解密钥匙本身：错了就解不出东西，没有分支可以绕过
  for _f in config authorized_keys; do
    [ -f "$HOME/.ssh/$_f.enc" ] || continue
    step "$_f"
    if openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "pass:$_pw" \
         -in "$HOME/.ssh/$_f.enc" -out "$HOME/.ssh/$_f.new" 2>/dev/null; then
      mv "$HOME/.ssh/$_f.new" "$HOME/.ssh/$_f"
      chmod 600 "$HOME/.ssh/$_f"
      okmsg "OK"
    else
      okmsg "密码错误"
      mv -f "$HOME/.ssh/$_f.new" "$BACKUP/$_f.failed" 2>/dev/null || :
      unset _pw
      exit 1
    fi
  done
  unset _pw
else
  echo "  （跳过）"
fi

# ---------- 4/5 装工具 ----------
phase "4/5 装工具"
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

# 直连时走 releases/latest 的重定向拿版本号，不碰 API 免限流；
# 代理模式下 github.com 根本不通，改用 api.github.com（国内可达）
ghtag() {
  if [ "$GHMODE" = direct ]; then
    curl -fsSLI --connect-timeout 10 --max-time 20 --retry 2 -o /dev/null -w '%{url_effective}' \
      "https://github.com/$1/releases/latest" | grep -o '/tag/[^/]*$' | sed 's#.*/tag/##'
  else
    curl -fsSL --connect-timeout 10 --max-time 20 --retry 2 \
      "https://api.github.com/repos/$1/releases/latest" \
      | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
  fi
}
# ghbin <repo> <tar.gz 资产名，TAG/VER 占位> <二进制名>
ghbin() {
  [ -n "$a1" ] || { echo "架构不支持"; return 1; }
  tag=$(ghtag "$1" || :)
  [ -n "$tag" ] || { echo "版本探测失败（连不上 github.com？）"; return 1; }
  asset=$(printf '%s' "$2" | sed "s/TAG/$tag/g; s/VER/${tag#v}/g")
  t=$(mktemp -d)
  curl -fsSL $CURL_T "$(ghurl "https://github.com/$1/releases/download/$tag/$asset")" \
    | tar -xz -C "$t" 2>/dev/null || :
  f=$(find "$t" -type f -name "$3" | head -1)
  if [ -n "$f" ]; then install -m755 "$f" "$BIN/$3"; rm -rf "$t"; return 0
  else rm -rf "$t"; echo "下载失败：$asset"; return 1; fi
}
# ghraw <repo> <裸二进制资产名> <二进制名>
ghraw() {
  [ -n "$a2" ] && [ -n "$osname" ] || { echo "架构不支持"; return 1; }
  tag=$(ghtag "$1" || :)
  [ -n "$tag" ] || { echo "版本探测失败（连不上 github.com？）"; return 1; }
  asset=$(printf '%s' "$2" | sed "s/TAG/$tag/g; s/VER/${tag#v}/g")
  curl -fsSL $CURL_T "$(ghurl "https://github.com/$1/releases/download/$tag/$asset")" -o "$BIN/$3.part" \
    || { echo "下载失败：$asset"; return 1; }
  chmod +x "$BIN/$3.part" && mv "$BIN/$3.part" "$BIN/$3"
}
# want <命令名> <安装命令...>：已有就跳过，没有才装；失败只警告不中断
want() {
  _c=$1; shift
  step "$_c"
  if have "$_c"; then okmsg "已有，跳过"; return 0; fi
  if _out=$("$@" "$_c" 2>&1); then okmsg "已安装"
  else okmsg "失败（跳过）"; echo "$_out" | head -4 | sed 's/^/        /'; fi
  return 0
}

case "$os" in
Darwin)
  if ! have brew && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
    step "homebrew 本体"
    if _out=$(NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL $CURL_T https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1); then
      okmsg "已安装"
    else okmsg "失败（跳过）"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
  fi
  have brew || { [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"; } || :
  have brew || { [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"; } || :
  if have brew; then
    for pkg in zsh tmux fzf ripgrep lsd git-lfs gh node; do
      step "brew $pkg"
      if brew list "$pkg" >/dev/null 2>&1; then okmsg "已有，跳过"
      elif _out=$(brew install "$pkg" 2>&1); then okmsg "已安装"
      else okmsg "失败（跳过）"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
    done
  else
    say "WARN: brew 不可用，跳过工具安装"
  fi
  MINICONDA_OS=MacOSX
  ;;
Linux)
  want lsd ghbin lsd-rs/lsd         "lsd-TAG-$a1-unknown-linux-musl.tar.gz"
  want rg  ghbin BurntSushi/ripgrep "ripgrep-VER-$a1-unknown-linux-$rgl.tar.gz"
  want fzf ghbin junegunn/fzf       "fzf-VER-linux_$a2.tar.gz"
  if [ "$tier" != 3 ]; then
    want gh      ghbin cli/cli         "gh_VER_linux_$a2.tar.gz"
    want git-lfs ghbin git-lfs/git-lfs "git-lfs-linux-$a2-TAG.tar.gz"
  fi
  # 全局基础件：只有缺了才装。非 root 问一次 sudo，拿不到就跳过，绝不中断
  base=""
  for p in zsh tmux vim curl; do have "$p" || base="$base $p"; done
  step "系统包$base"
  if [ -z "$base" ]; then
    okmsg "都已有，跳过"
  else
    SUDO=""; ok=yes
    if [ "$(id -u)" -ne 0 ]; then
      okmsg "需要 sudo，下面会提示输密码（不想装就 Ctrl-C）"
      sudo -v 2>/dev/null && SUDO="sudo" || ok=no
      step "  apt/apk 安装"
    fi
    if [ "$ok" = yes ] && have apt-get; then
      if _out=$($SUDO apt-get update -qq 2>&1 && $SUDO apt-get install -y $base 2>&1); then okmsg "已安装"
      else okmsg "失败（跳过）"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
    elif [ "$ok" = yes ] && have apk; then
      if _out=$($SUDO apk add --no-cache $base 2>&1); then okmsg "已安装"
      else okmsg "失败（跳过）"; fi
    else
      okmsg "拿不到 sudo，跳过"
    fi
  fi
  MINICONDA_OS=Linux
  ;;
esac

# ---------- 5/5 oh-my-zsh 与其余 ----------
phase "5/5 oh-my-zsh 与其余"
ZSH_DIR="$HOME/.oh-my-zsh"
step "oh-my-zsh"
if [ -d "$ZSH_DIR" ]; then okmsg "已有，跳过"
elif _out=$(git clone --depth 1 -q "$(ghurl https://github.com/ohmyzsh/ohmyzsh.git)" "$ZSH_DIR" 2>&1); then okmsg "已安装"
else okmsg "失败（跳过）"; echo "$_out" | head -3 | sed 's/^/        /'; fi
for p in zsh-users/zsh-autosuggestions zsh-users/zsh-syntax-highlighting; do
  d="$ZSH_DIR/custom/plugins/${p#*/}"
  step "${p#*/}"
  if [ -d "$d" ]; then okmsg "已有，跳过"
  elif _out=$(git clone --depth 1 -q "$(ghurl "https://github.com/$p")" "$d" 2>&1); then okmsg "已安装"
  else okmsg "失败（跳过）"; fi
done

if [ "$tier" != 3 ]; then
  # sshow：和 ssh config 配套，pip 装，三端同一个命令
  # sshow：和 ssh config 配套。新版 Debian/Ubuntu 有 PEP 668 限制，
  # 普通 pip --user 会被拒，要加 --break-system-packages（装进用户目录，不动系统包）
  step "sshow"
  if have sshow; then okmsg "已有，跳过"
  else
    _pip=$(command -v pip3 || command -v pip || echo "")
    if [ -z "$_pip" ]; then okmsg "失败（没有 pip）"
    elif _out=$("$_pip" install --user --quiet --timeout 30 sshow 2>&1); then okmsg "已安装"
    elif _out=$("$_pip" install --user --quiet --timeout 30 --break-system-packages sshow 2>&1); then
      okmsg "已安装（--break-system-packages）"
    else okmsg "失败（跳过）"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
  fi

  want dops ghraw Mikescher/better-docker-ps "dops_${osname}-${a2}"

  step "node (nvm)"
  if have node || [ -s "$HOME/.nvm/nvm.sh" ]; then okmsg "已有，跳过"
  else
    okmsg "安装中（会拉 nvm 再装 LTS，慢是正常的）"
    step "  nvm + node"
    if _out=$( { curl -fsSL $CURL_T https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash; \
                 bash -c '. "$HOME/.nvm/nvm.sh" && nvm install --lts'; } 2>&1 ); then okmsg "已安装"
    else okmsg "失败（跳过）"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
  fi

  conda_found=no
  for d in "$HOME/miniconda3" "$HOME/anaconda3" /opt/miniconda3 /opt/anaconda3; do
    [ -f "$d/etc/profile.d/conda.sh" ] && conda_found=yes && break
  done
  step "miniconda"
  if [ "$conda_found" = yes ]; then okmsg "已有，跳过"
  elif [ -z "${MINICONDA_OS:-}" ]; then okmsg "该系统不支持，跳过"
  else
    okmsg "下载中（约 100MB，慢是正常的）"
    step "  下载并安装"
    if _out=$(curl -fsSL --connect-timeout 10 --max-time 900 \
                "https://repo.anaconda.com/miniconda/Miniconda3-latest-$MINICONDA_OS-$(uname -m).sh" \
                -o /tmp/miniconda.sh 2>&1 && bash /tmp/miniconda.sh -b -p "$HOME/miniconda3" 2>&1); then
      rm -f /tmp/miniconda.sh
      okmsg "已安装"
    else okmsg "失败（跳过）"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
  fi
fi

echo
say "完成。用 \`dot status\` 看改动，\`exec zsh\` 进新环境。"
