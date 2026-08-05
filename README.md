# dotfiles

bare git repo，`$HOME` 就是工作区 —— 改了什么 `dot status` 直接看得见，没有"忘记同步"这个动作可以忘。

管的机器：macOS（mbp、mini4）/ Linux（pi4g、VPS ×5、公司 dev 机）/ Windows（eva02）。
不管：thor1/2/3（公用账户）、syno（群晖，连 git 都没有）、pi8g（OpenWrt）、xiaoai。

## 装

**macOS / Linux**

```sh
curl -fsSL https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.sh | sh
```

**Windows**（PowerShell）

```powershell
irm https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.ps1 | iex
```

会问一次分级：

| | 谁 | 拿到什么 |
|---|---|---|
| **1 个人设备** | 自己的机器 | 全套 + `ssh config`、`authorized_keys`（要密码解密） |
| **2 公司个人用户** | 公司里我自己的账号 | 除 ssh 相关外全套 |
| **3 公司公用用户** | thor1/2/3 那种多人共用的账号 | 只铺 `.zshrc` / `.zprofile` / `.gitconfig.erichuanp` |
| **4 容器** | dev container | 只有 shell / git / tmux 配置（Windows 无 3、4 级） |

### 3 级为什么只铺这几个

公用账户里 `$HOME` 的每个文件都是所有人共用的。判断标准只有一条：
**覆盖它会不会改变别人的行为。**

那几台机器上其他人全用 bash，只有我用 zsh，所以 `.zshrc` / `.zprofile`
事实上是我的私人文件，可以直接铺。其余一律不碰：

- `.gitconfig` —— 上面是同事的 git 身份，覆盖等于把他的提交记到我头上
- `authorized_keys` —— 覆盖等于把人锁在门外
- `.bashrc` / `.profile` / `.tmux.conf` / `.vimrc` / `.inputrc` —— 所有人都在读

git 身份靠 `GIT_CONFIG_GLOBAL` 绕开：3 级会写一个 `~/.dotfiles-shared` 标记，
`.zshrc` 见到它就把 `GIT_CONFIG_GLOBAL` 指向 `~/.gitconfig.erichuanp`。
于是我的 zsh 会话用我的身份，同事的 bash 会话照常读 `~/.gitconfig`，一个字节没动。
**需要 git ≥ 2.32。**

3 级也不装任何要 sudo 的东西，不装 conda / node —— 公用机器上动全局是替别人做决定。

跳过提问：`DOTFILES_TIER=2 curl ... | sh`。**容器构建时没有 tty，自动按 4 级装**，
所以 Dockerfile 里直接写：

```dockerfile
RUN curl -fsSL https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.sh | sh
SHELL ["/bin/zsh", "-c"]
```

Windows 跑完补一句，否则受管的 gitconfig 会盖掉 gh 的凭据助手、`git push` 走 HTTPS 会失效：

```powershell
gh auth setup-git
```

### 纯国内节点（sz1 / sz2 那种）

脚本自己探路，四级回退：**直连 → 反向 SOCKS → ghfast 代理 → 报错退出**。

第二级要上游配合。SSH 协议不允许服务端主动向客户端开通道，所以管子只能在
连接时铺好，脚本只负责发现它在不在：

```sh
ssh -R 1080 sz1        # 然后在里面照常跑安装
```

嫌麻烦就写进上游的 `~/.ssh/config`，以后自动带上：

```
Host sz1 sz2
  RemoteForward 1080
```

反向 SOCKS 排在公共代理前面：它只转发 TCP，到 GitHub 的 TLS 是端到端的；
ghfast 必须终止 TLS 再重新取，内容它全看得见。

装之前，内容和仓库不一致的同名文件会先备份到 `~/tmp/.dotfiles-backup/`（一模一样的不备份，`*.enc` 直接覆盖）。

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
