# dotfiles

bare git repo，`$HOME` 就是工作区 —— 改了什么 `dot status` 直接看得见，没有"忘记同步"这个动作可以忘。

管的机器：macOS（mbp、mini4）/ Linux（pi4g、VPS ×5、公司 dev 机）/ Windows（eva02）。
不管：thor1/2/3（公用账户）、syno（群晖，连 git 都没有）、pi8g（OpenWrt）、xiaoai。

## 装

```sh
curl -fsSL https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.sh | sh
```

会问一次分级：

| | 谁 | 拿到什么 |
|---|---|---|
| **1 个人设备** | 自己的机器 | 全套 + `ssh config`、`authorized_keys`（要密码解密） |
| **2 公司个人用户** | 公司里我自己的账号 | 除 ssh 相关外全套 |
| **3 容器** | dev container | 只有 shell / git / tmux 配置 |

跳过提问：`DOTFILES_TIER=2 curl ... | sh`。**容器构建时没有 tty，自动按 3 级装**，所以 Dockerfile 里直接写：

```dockerfile
RUN curl -fsSL https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.sh | sh
SHELL ["/bin/zsh", "-c"]
```

Windows：

```powershell
irm https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.ps1 | iex
```

装之前的同名文件一律先原样备份到 `~/.dotfiles-backup/`。

## 日常

```sh
dot status          # 看漂移。$HOME 就是工作区，这里显示的就是真相
dot diff
dot add ~/.zshrc
dot commit -m "..."
dot push
dot pull            # 拉别的机器上的改动
```

`dot` 是 `.zshrc` 里的函数（Windows 在 PowerShell profile 里），就是
`git --git-dir=~/.dotfiles --work-tree=$HOME`。

### 改了 ssh config / authorized_keys

这两个是**加密**存的（仓库公开，里面有内网拓扑和公司主机名）。改完明文后必须重新封一次：

```sh
dotseal             # 加密 ~/.ssh/{config,authorized_keys} 并 git add
dot commit -m "ssh: ..." && dot push
```

首次生成密文（只做一次）：

```sh
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in ~/.ssh/config          -out ~/.ssh/config.enc
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in ~/.ssh/authorized_keys -out ~/.ssh/authorized_keys.enc
```

密码不是"检查"，就是解密钥匙本身 —— 输错的结果是解不出东西，没有分支可以绕过。
明文 `~/.ssh/config`、`~/.ssh/authorized_keys` 已写进 `.git/info/exclude`，
`dot add -A` 不会顺手把它们带上去。

## 本机私货

这些文件**永不纳管、永不被覆盖**，每台机器自己管自己的：

| 文件 | 谁读 |
|---|---|
| `~/.zshrc.local` | `.zshrc` 最后一行 |
| `~/.bashrc.local` / `~/.profile.local` | 对应的 rc |
| `~/.gitconfig.local` | `.gitconfig` 的 `[include]`（放最后，所以本机赢） |
| `Documents/PowerShell/profile.local.ps1` | PowerShell profile 末尾 |

追加一行不用手编辑：

```sh
zshrc "alias k=kubectl"     # 去重追加进 .zshrc.local 并预填 source 命令
zshrc vim                   # 直接编辑
```

## 管了哪些文件

```
.zshrc  .bashrc  .profile  .zprofile      三级都有
.tmux.conf  .gitconfig  .gitignore_global
.vimrc  .inputrc

.condarc  .hushlogin                       1、2 级
.local/bin/dotup  .local/bin/sfp

.ssh/config.enc  .ssh/authorized_keys.enc  只有 1 级

Documents/PowerShell/*                     只有 Windows
Documents/WindowsPowerShell/*
```

## 会装的工具

| 方式 | 装什么 |
|---|---|
| 静态二进制 → `~/.local/bin` | lsd、ripgrep、fzf（+ 1/2 级：gh、git-lfs、dops） |
| git clone | oh-my-zsh + autosuggestions + syntax-highlighting |
| pip --user | sshow（1/2 级；和 ssh config 配套） |
| 官方安装器 | miniconda、node（nvm）—— 1/2 级；已有则跳过 |
| apt / apk | zsh、tmux、vim、curl —— **只有缺了才装**，非 root 问一次 sudo，拿不到就跳过 |
| macOS | 一律 brew（全新 Mac 先装 brew 本体） |

用户态优先，全局是例外。任一处已有的工具一律跳过，重复跑安全。

## chsh 替代

不少机器没 sudo，改不了 `/etc/shells`、`chsh` 不了。`.bashrc` / `.profile` 里有一段：
非交互直接 return（不然 scp/rsync 会断），交互式则先试跑 `zsh -c 'exit 0'` 再 `exec zsh -l`。

zsh 坏了进不去时：`DOTFILES_NO_EXEC_ZSH=1 ssh xxx`。
