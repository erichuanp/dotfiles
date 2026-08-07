#!/bin/sh
# dotfiles 引导。仓库是 bare git repo，$HOME 就是工作区，所以改了什么 `dot status` 直接看得见。
#
#   curl -fsSL https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.sh | sh
#
# 非交互环境（容器构建）自动按容器级安装。要跳过提问：DOTFILES_TIER=2 curl ... | sh
set -eu

REPO="${DOTFILES_REPO:-https://github.com/erichuanp/dotfiles.git}"
GITDIR="$HOME/.dotfiles"
BACKUP="$HOME/tmp/.dotfiles-backup"
BIN="$HOME/.local/bin"

# 所有网络操作都必须有上限。只设 connect-timeout 不够 —— 连上之后传输停滞会永远挂着
# --max-time 是总上限，防不住"连上了但不动"。真正管用的是 --speed-limit/--speed-time：
# 30 秒内平均速度低于 1KB/s 就放弃，交给 _dl 换下一条路，不用干等 5 分钟。
CURL_T='--connect-timeout 10 --max-time 300 --speed-limit 1024 --speed-time 30 --retry 1' 
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30

GIT_NET=""   # socks 模式下填 -c http.proxy=...
dot() { git $GIT_NET --git-dir="$GITDIR" --work-tree="$HOME" "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
say() { echo "[dotfiles] $*"; }
# step 只打印前缀不换行；卡住时你会看到一行没有结果的输出，一眼知道卡在哪
# printf 的 %-30s 按字节数补齐，中文 3 字节却只占 2 列，直接用会歪。
# wc -m 依赖 locale（没设时退化成字节数），所以直接扫字节：ASCII 记 1 列，
# 多字节的首字节记 2 列，后续字节记 0 列 —— 对 ASCII+中文精确，且与 locale 无关。
step() {
  _lbl="$1 ..."
  _w=$(printf '%s' "$_lbl" | od -An -tu1 \
       | awk '{for(i=1;i<=NF;i++){if($i<128)w++; else if($i>=192)w+=2}} END{print w+0}')
  printf '%s' "$_lbl"
  _pad=$(( 30 - _w )); [ "$_pad" -lt 1 ] && _pad=1
  printf '%*s' "$_pad" ''
}
okmsg() { echo "$1"; }
# 容器里 /dev/tty 这个设备节点是存在的、权限位也可读，但没有控制终端，
# 一打开就 "No such device or address"。所以不能用 [ -r /dev/tty ] 判断，
# 必须真的开一次。
# 必须放在子 shell 里：`:` 是 POSIX 特殊内建，特殊内建上的重定向失败会让
# 非交互 shell 直接退出（dash 严格照做，bash 不），子 shell 把它挡住。
_has_tty() { ( : > /dev/tty ) 2>/dev/null; }
# 换路提示要绕开 want 的 $(...) 捕获，直接写终端；没有 tty（容器构建）就退到 stderr
_note() { printf '\n      %s ' "$1" > /dev/tty 2>/dev/null || printf '\n      %s ' "$1" >&2; }

have git || { echo "需要 git，先装 git" >&2; exit 1; }

# ---------- 分级 ----------
COMMON='.zshrc .bashrc .profile .zprofile .tmux.conf .gitconfig .gitconfig.erichuanp .gitignore_global .vimrc .inputrc'
HOSTONLY='.condarc .hushlogin .local/bin/dotup .local/bin/sfp .local/bin/dotpull'
PERSONAL='.ssh/authorized_keys.enc .ssh/config.enc'
# 公用账户：$HOME 里每个文件都是所有人共用的，只有 zsh 那一族事实上归我
# （其他人全用 bash）。.gitconfig / .bashrc / .tmux.conf / authorized_keys 一律不碰。
SHARED='.zshrc .zprofile .gitconfig.erichuanp .local/bin/dotup .local/bin/sfp .local/bin/dotpull'

tier="${DOTFILES_TIER:-}"
if [ -z "$tier" ]; then
  if _has_tty; then
    {
      echo "1. 个人设备      —— 需要密码"
      echo "2. 公司个人用户  —— 无 ssh"
      echo "3. 公司公用用户  —— 只铺 zsh 那一族，不碰任何共享文件"
      echo "4. 容器          —— 仅有 shell/git/tmux 配置"
      printf '选择 [1/2/3/4]: '
    } > /dev/tty
    read -r tier < /dev/tty
  else
    tier=4
    say "无 tty，按容器级安装"
  fi
fi

case "$tier" in
  1) FILES="$COMMON $HOSTONLY $PERSONAL"; TIERNAME="个人设备" ;;
  2) FILES="$COMMON $HOSTONLY";           TIERNAME="公司个人用户" ;;
  3) FILES="$SHARED";                     TIERNAME="公司公用用户" ;;
  4) FILES="$COMMON";                     TIERNAME="容器" ;;
  *) exit 1 ;;
esac

# 2/3/4 没有密码那道刹车，选错了会直接覆盖别人的文件，所以补一次确认。
# 只在从菜单选的时候问：显式设了 DOTFILES_TIER 就是有意为之，容器构建也不该卡住。
if [ -z "${DOTFILES_TIER:-}" ] && [ "$tier" != 1 ] && _has_tty; then
  {
    echo
    echo "  本机：$(id -un)@$(hostname)   $HOME"
    echo "  分级：$tier $TIERNAME"
    printf '  继续？[y/N]: '
  } > /dev/tty
  read -r _yes < /dev/tty
  case "$_yes" in
    y|Y) ;;
    *) echo "已取消"; exit 1 ;;
  esac
fi
echo
echo "开始安装..."
echo
echo "平台：$(uname -s) $(uname -m)"

# ---------- 0/5 GitHub 可达性 ----------
# 国内机器 github.com:443 通常不通，但 raw / api / codeload / ssh:443 都通。
# 探一次，不通就把所有 github.com 的 URL 走代理；push 走 ssh:443（代理是只读的）。
GHPROXY="${DOTFILES_GH_PROXY:-https://ghfast.top}"
SOCKS="${DOTFILES_SOCKS:-127.0.0.1:1080}"
CURL_NET=""

# 反向 SOCKS 单独探一次，不管直连通不通 —— 后面某个下载卡住时要拿它兜底。
# 没有隧道时连 127.0.0.1:1080 会立刻 connection refused，不拖时间。
SOCKS_OK=no
if curl -fsS -o /dev/null --socks5-hostname "$SOCKS" --connect-timeout 5 --max-time 12 \
     https://github.com/ 2>/dev/null; then
  # SSH 协议不允许服务端主动向客户端开通道，这条管子只能是上游机器连过来时用
  # -R 铺好的。脚本只负责发现它在不在。
  SOCKS_OK=yes
fi

step "github.com 连通性"
if curl -fsS -o /dev/null --connect-timeout 10 --max-time 25 --retry 1 https://github.com/ 2>/dev/null; then
  GHMODE=direct
  okmsg "OK"
elif [ "$SOCKS_OK" = yes ]; then
  GHMODE=socks; okmsg "直连不通 -> 反向 SOCKS $SOCKS"
  CURL_NET="--socks5-hostname $SOCKS"
  GIT_NET="-c http.proxy=socks5h://$SOCKS"
elif curl -fsS -o /dev/null --connect-timeout 10 --max-time 25 "$GHPROXY/https://github.com/" 2>/dev/null; then
  GHMODE=proxy; okmsg "直连不通 -> $GHPROXY"
else
  okmsg "FAIL"
  echo
  echo "连不上 GitHub，三条路都不通：直连 / 反向 SOCKS($SOCKS) / $GHPROXY"
  if [ -n "${SSH_CONNECTION:-}" ]; then
    echo "这台机器是被 ssh 上来的。回到上游机器，用反向 SOCKS 重连再跑："
    echo
    echo "    ssh -R 1080 <本机>"
    echo
    echo "或者把这两行写进上游的 ~/.ssh/config，以后自动带上："
    echo
    echo "    Host <本机>"
    echo "      RemoteForward 1080"
  else
    echo "安装失败，需要代理环境。"
    echo "本机不是 ssh 会话，没有上游可借；请先让这台机器能上 GitHub，"
    echo "或用 DOTFILES_GH_PROXY=<可用的代理> 重跑。"
  fi
  exit 1
fi
ghurl() {
  case "$1" in
    https://github.com/*) [ "$GHMODE" = proxy ] && echo "$GHPROXY/$1" || echo "$1" ;;
    *) echo "$1" ;;
  esac
}

# _dl <github 原始 url> <输出文件>
# 探测通过不代表后面每个下载都顺 —— 国内到 GitHub 常见"握手成功、传到一半停住"。
# 所以每个下载各自带回退，而不是一次探测定终身：当前模式 -> 反向 SOCKS -> 公共代理。
_dl() {
  curl -fsSL $CURL_T $CURL_NET "$(ghurl "$1")" -o "$2" 2>/dev/null && return 0
  if [ "$SOCKS_OK" = yes ] && [ "$GHMODE" != socks ]; then
    _note "换走反向 SOCKS 重试"
    curl -fsSL $CURL_T --socks5-hostname "$SOCKS" "$1" -o "$2" 2>/dev/null && return 0
  fi
  [ "$GHMODE" = proxy ] && return 1
  _note "换走 $GHPROXY 重试"
  curl -fsSL $CURL_T "$GHPROXY/$1" -o "$2" 2>/dev/null
}

# ---------- 1/5 取仓库 ----------
if [ -d "$GITDIR" ]; then
  step "fetch 仓库"
  if dot fetch -q origin 2>/dev/null; then okmsg "OK"; else okmsg "FAIL"; fi
else
  step "clone 仓库"
  if _out=$(git $GIT_NET clone --bare -q "$(ghurl "$REPO")" "$GITDIR" 2>&1); then okmsg "OK"
  else okmsg "FAIL"; echo "$_out" | head -4 | sed 's/^/        /'; exit 1; fi
fi
# push 一律走 SSH：HTTPS 推送要 PAT，GitHub 早就不收密码了。
# 直连用标准 22 端口；国内节点用 ssh.github.com:443（22 通常被墙）。
if [ "$GHMODE" = direct ]; then
  dot remote set-url --push origin git@github.com:erichuanp/dotfiles.git 2>/dev/null || :
else
  dot remote set-url --push origin ssh://git@ssh.github.com:443/erichuanp/dotfiles.git 2>/dev/null || :
fi
# --bare clone 的 refspec 直接写 refs/heads/*，不建远程跟踪分支，于是 push 会说
# "no upstream"。换成标准 refspec 并建好跟踪，以后 dot push / dot pull 都不用带参数。
dot config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
dot fetch -q origin 2>/dev/null || :
dot branch --set-upstream-to=origin/main main >/dev/null 2>&1 || :
# 代理模式把 fetch 地址也固化，以后 dot pull 不需要再想网络的事；
# SOCKS 模式不固化 —— 那条管子不是常在的，写死了反而会在没隧道时挂掉
if [ "$GHMODE" = proxy ]; then
  dot remote set-url origin "$(ghurl "$REPO")" 2>/dev/null || :
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


# ---------- 2/5 铺文件 ----------
step "备份不同旧文件"
_n=0
for f in $FILES; do
  # 加密文件直接覆盖：明文才是本体，密文备份了也没用
  case "$f" in *.enc) continue ;; esac
  [ -e "$HOME/$f" ] || continue
  # 内容和仓库里一模一样就没必要备份，免得 backup 目录里全是噪音
  if dot show "HEAD:$f" 2>/dev/null | cmp -s - "$HOME/$f"; then continue; fi
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp -p "$HOME/$f" "$BACKUP/$f"
  _n=$((_n+1))
done
okmsg "$_n 个 -> ~/tmp/.dotfiles-backup/"

step "写入配置文件"
if _out=$(dot checkout -f 2>&1); then okmsg "OK"
else okmsg "FAIL"; echo "$_out" | head -6 | sed 's/^/        /'; exit 1; fi
dot reset -q

if [ "$tier" = 3 ]; then
  : > "$HOME/.dotfiles-shared"
  # 公用账户上，同事的这些文件仍然留在索引里（sparse 规则碰不动已存在且内容
  # 不同的文件，只会 warning）。标成 skip-worktree，git 从此彻底无视它们：
  # dot status 不再有噪音，将来任何 checkout 也不会把同事的文件覆盖掉。
  for _sf in $COMMON $HOSTONLY; do
    case " $SHARED " in *" $_sf "*) continue ;; esac
    dot update-index --skip-worktree "$_sf" 2>/dev/null || :
  done
fi
[ -d "$HOME/.ssh" ] && chmod 700 "$HOME/.ssh"
chmod +x "$BIN/dotup" "$BIN/sfp" "$BIN/dotpull" 2>/dev/null || :

# ---------- 3/5 解密 ----------
if [ "$tier" = 1 ]; then
  _has_tty || { echo "1 级要输密码，但没有终端可读。用 DOTFILES_TIER 选别的级。" >&2; exit 1; }
  echo "SSH 文件解密..."
  printf 'Password: ' > /dev/tty
  stty -echo < /dev/tty 2>/dev/null || :
  read -r _pw < /dev/tty
  stty echo < /dev/tty 2>/dev/null || :
  printf '\n' > /dev/tty
  # 密码不是"检查"，是解密钥匙本身：错了就解不出东西，没有分支可以绕过
  for _f in config authorized_keys; do
    [ -f "$HOME/.ssh/$_f.enc" ] || continue
    step "  解密 $_f"
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
fi

# ---------- 4/5 装工具 ----------
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
# 直连时走 releases/latest 的重定向拿版本号，不碰 API 免限流；
# 拿不到就退到 api.github.com（国内可达），再退到反向 SOCKS。
ghtag() {
  _t=""
  if [ "$GHMODE" = direct ]; then
    _t=$(curl -fsSLI --connect-timeout 8 --max-time 15 -o /dev/null -w '%{url_effective}' \
         "https://github.com/$1/releases/latest" 2>/dev/null \
         | grep -o '/tag/[^/]*$' | sed 's#.*/tag/##')
  fi
  [ -n "$_t" ] && { echo "$_t"; return 0; }
  _t=$(curl -fsSL $CURL_NET --connect-timeout 8 --max-time 15 \
       "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
       | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  [ -n "$_t" ] && { echo "$_t"; return 0; }
  if [ "$SOCKS_OK" = yes ] && [ "$GHMODE" != socks ]; then
    _t=$(curl -fsSL --socks5-hostname "$SOCKS" --connect-timeout 8 --max-time 15 \
         "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
         | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  fi
  echo "$_t"
}
# ghbin <repo> <tar.gz 资产名，TAG/VER 占位> <二进制名>
ghbin() {
  [ -n "$a1" ] || { echo "架构不支持"; return 1; }
  tag=$(ghtag "$1" || :)
  [ -n "$tag" ] || { echo "版本探测失败（连不上 github.com？）"; return 1; }
  asset=$(printf '%s' "$2" | sed "s/TAG/$tag/g; s/VER/${tag#v}/g")
  t=$(mktemp -d)
  if ! _dl "https://github.com/$1/releases/download/$tag/$asset" "$t/pkg.tgz"; then
    rm -rf "$t"; echo "下载失败：$asset"; return 1
  fi
  tar -xzf "$t/pkg.tgz" -C "$t" 2>/dev/null || :
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
  _dl "https://github.com/$1/releases/download/$tag/$asset" "$BIN/$3.part" \
    || { echo "下载失败：$asset"; return 1; }
  chmod +x "$BIN/$3.part" && mv "$BIN/$3.part" "$BIN/$3"
}
# want <命令名> <安装命令...>：已有就跳过，没有才装；失败只警告不中断
want() {
  _c=$1; shift
  step "$_c"
  if have "$_c"; then okmsg "SKIP"; return 0; fi
  if _out=$("$@" "$_c" 2>&1); then okmsg "OK"
  else okmsg "FAIL"; echo "$_out" | head -4 | sed 's/^/        /'; fi
  return 0
}

case "$os" in
Darwin)
  if ! have brew && [ ! -x /opt/homebrew/bin/brew ] && [ ! -x /usr/local/bin/brew ]; then
    step "homebrew 本体"
    if _out=$(NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL $CURL_T https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" 2>&1); then
      okmsg "OK"
    else okmsg "FAIL"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
  fi
  have brew || { [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"; } || :
  have brew || { [ -x /usr/local/bin/brew ] && eval "$(/usr/local/bin/brew shellenv)"; } || :
  if have brew; then
    for pkg in zsh tmux fzf ripgrep lsd git-lfs gh node; do
      step "$pkg"
      if brew list "$pkg" >/dev/null 2>&1; then okmsg "SKIP"
      elif _out=$(brew install "$pkg" 2>&1); then okmsg "OK"
      else okmsg "FAIL"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
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
  case "$tier" in 1|2|3)
    want gh      ghbin cli/cli         "gh_VER_linux_$a2.tar.gz"
    want git-lfs ghbin git-lfs/git-lfs "git-lfs-linux-$a2-TAG.tar.gz"
  ;; esac
  # 全局基础件：只有缺了才装。非 root 问一次 sudo，拿不到就跳过，绝不中断
  base=""
  # 3 级不装系统包：公用机器上动全局是替别人做决定
  [ "$tier" = 3 ] || for p in zsh tmux vim curl; do have "$p" || base="$base $p"; done
  step "系统包$base"
  if [ -z "$base" ]; then
    okmsg "SKIP"
  else
    SUDO=""; ok=yes
    if [ "$(id -u)" -ne 0 ]; then
      okmsg "需要 sudo"
      sudo -v 2>/dev/null && SUDO="sudo" || ok=no
      step "  apt/apk 安装"
    fi
    if [ "$ok" = yes ] && have apt-get; then
      if _out=$($SUDO apt-get update -qq 2>&1 && $SUDO apt-get install -y $base 2>&1); then okmsg "OK"
      else okmsg "FAIL"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
    elif [ "$ok" = yes ] && have apk; then
      if _out=$($SUDO apk add --no-cache $base 2>&1); then okmsg "OK"
      else okmsg "FAIL"; fi
    else
      okmsg "SKIP"
    fi
  fi
  MINICONDA_OS=Linux
  ;;
esac

# ---------- 5/5 oh-my-zsh 与其余 ----------
ZSH_DIR="$HOME/.oh-my-zsh"
step "oh-my-zsh"
if [ -d "$ZSH_DIR" ]; then okmsg "SKIP"
elif _out=$(git $GIT_NET clone --depth 1 -q "$(ghurl https://github.com/ohmyzsh/ohmyzsh.git)" "$ZSH_DIR" 2>&1); then okmsg "OK"
else okmsg "FAIL"; echo "$_out" | head -3 | sed 's/^/        /'; fi
for p in zsh-users/zsh-autosuggestions zsh-users/zsh-syntax-highlighting; do
  d="$ZSH_DIR/custom/plugins/${p#*/}"
  step "${p#*/}"
  if [ -d "$d" ]; then okmsg "SKIP"
  elif _out=$(git $GIT_NET clone --depth 1 -q "$(ghurl "https://github.com/$p")" "$d" 2>&1); then okmsg "OK"
  else okmsg "FAIL"; fi
done

case "$tier" in 1|2)
  # sshow：和 ssh config 配套，pip 装，三端同一个命令
  # sshow：和 ssh config 配套。新版 Debian/Ubuntu 有 PEP 668 限制，
  # 普通 pip --user 会被拒，要加 --break-system-packages（装进用户目录，不动系统包）
  step "sshow"
  if have sshow; then okmsg "SKIP"
  else
    _pip=$(command -v pip3 || command -v pip || echo "")
    if [ -z "$_pip" ]; then okmsg "FAIL"; echo "        这台机器没有 pip"
    elif _out=$("$_pip" install --user --quiet --timeout 30 sshow 2>&1); then okmsg "OK"
    elif _out=$("$_pip" install --user --quiet --timeout 30 --break-system-packages sshow 2>&1); then
      okmsg "OK"
    else okmsg "FAIL"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
  fi

  want dops ghraw Mikescher/better-docker-ps "dops_${osname}-${a2}"

  step "node (nvm)"
  if have node || [ -s "$HOME/.nvm/nvm.sh" ]; then okmsg "SKIP"
  else
    okmsg "安装中"
    step "  nvm + node"
    if _out=$( { curl -fsSL $CURL_T https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash; \
                 bash -c '. "$HOME/.nvm/nvm.sh" && nvm install --lts'; } 2>&1 ); then okmsg "OK"
    else okmsg "FAIL"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
  fi

  conda_found=no
  for d in "$HOME/miniconda3" "$HOME/anaconda3" /opt/miniconda3 /opt/anaconda3; do
    [ -f "$d/etc/profile.d/conda.sh" ] && conda_found=yes && break
  done
  step "miniconda"
  if [ "$conda_found" = yes ]; then okmsg "SKIP"
  elif [ -z "${MINICONDA_OS:-}" ]; then okmsg "SKIP"
  else
    okmsg "下载中（约 100MB）"
    step "  下载并安装"
    if _out=$(curl -fsSL --connect-timeout 10 --max-time 900 \
                "https://repo.anaconda.com/miniconda/Miniconda3-latest-$MINICONDA_OS-$(uname -m).sh" \
                -o /tmp/miniconda.sh 2>&1 && bash /tmp/miniconda.sh -b -p "$HOME/miniconda3" 2>&1); then
      rm -f /tmp/miniconda.sh
      okmsg "OK"
    else okmsg "FAIL"; echo "$_out" | tail -3 | sed 's/^/        /'; fi
  fi
;;
# 3 级只多装个 dops（纯新增二进制，不改任何人的行为）
3) want dops ghraw Mikescher/better-docker-ps "dops_${osname}-${a2}" ;;
esac

echo
echo "安装完成。"
echo "请重新进 Shell"
echo "dot h  # 同步教程"
