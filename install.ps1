# dotfiles 引导（Windows）。仓库是 bare git repo，$HOME 就是工作区。
#
#   irm https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.ps1 | iex
#
$ErrorActionPreference = 'Stop'
$Repo    = if ($env:DOTFILES_REPO) { $env:DOTFILES_REPO } else { 'https://github.com/erichuanp/dotfiles.git' }
$GitDir  = Join-Path $HOME '.dotfiles'
$Backup  = Join-Path $HOME 'tmp\.dotfiles-backup'
$Proxy   = if ($env:DOTFILES_GH_PROXY) { $env:DOTFILES_GH_PROXY } else { 'https://ghfast.top' }
$Socks   = if ($env:DOTFILES_SOCKS) { $env:DOTFILES_SOCKS } else { '127.0.0.1:1080' }
$GitNet  = @()   # socks 模式下的 git 参数

function dot { & git @GitNet --git-dir="$GitDir" --work-tree="$HOME" @args }
# step 只打印前缀不换行；卡住时你会看到一行没有结果的输出，一眼知道卡在哪
function step($m) { Write-Host ("{0,-30}" -f "$m ...") -NoNewline }
function okmsg($m) { Write-Host $m }

if (-not (Get-Command git -ErrorAction Ignore)) { throw '需要 git，先装 Git for Windows' }

# Windows 不跑 zsh，所以 shell 相关的文件不 checkout
$Common   = @('.gitconfig','.gitignore_global','.vimrc','.inputrc')
$HostOnly = @('.condarc',
              'Documents/PowerShell/Microsoft.PowerShell_profile.ps1',
              'Documents/PowerShell/profile.ps1',
              'Documents/WindowsPowerShell/profile.ps1')
$Personal = @('.ssh/authorized_keys.enc','.ssh/config.enc')

$tier = $env:DOTFILES_TIER
if (-not $tier) {
    Write-Host '1. 个人设备      —— 需要密码'
    Write-Host '2. 公司个人用户  —— 无 ssh'
    $tier = Read-Host '选择 [1/2]'
}
$files = switch ($tier) {
    '1' { $Common + $HostOnly + $Personal }
    '2' { $Common + $HostOnly }
    default { exit 1 }
}

Write-Host ''
Write-Host '开始安装...'
Write-Host ''
Write-Host "平台：Windows $env:PROCESSOR_ARCHITECTURE"

# 国内机器 github.com:443 通常不通，raw 却是通的（所以这个脚本能下下来）。
# 探一次，不通就把 github.com 的 URL 走代理；push 走 ssh:443（代理是只读的）。
# 四级回退。反向 SOCKS 排在公共代理前面：它只转发 TCP，到 GitHub 的 TLS 是端到端的；
# ghfast 必须终止 TLS 再重新取，内容它全看得见。
# 用 curl.exe（Win10+ 自带）而不是 Invoke-WebRequest —— 后者不支持 SOCKS 代理。
# 写成朴素的嵌套 if：@() 放在参数位置会让解析器懵，别用函数包一层。
step 'github.com 连通性'
$mode = 'fail'
& curl.exe -fsS -o NUL --connect-timeout 10 --max-time 25 'https://github.com/' 2>$null
if ($LASTEXITCODE -eq 0) {
    $mode = 'direct'
    okmsg 'OK'
} else {
    # SSH 协议不允许服务端主动向客户端开通道，这条管子只能是上游机器连过来时
    # 用 -R 铺好的。这里只负责发现它在不在。
    & curl.exe -fsS -o NUL --socks5-hostname $Socks --connect-timeout 10 --max-time 25 'https://github.com/' 2>$null
    if ($LASTEXITCODE -eq 0) {
        $mode = 'socks'
        okmsg "直连不通 -> 反向 SOCKS $Socks"
        $GitNet = @('-c', "http.proxy=socks5h://$Socks")
    } else {
        & curl.exe -fsS -o NUL --connect-timeout 10 --max-time 25 "$Proxy/https://github.com/" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $mode = 'proxy'
            okmsg "直连不通 -> $Proxy"
        }
    }
}
if ($mode -eq 'fail') {
    okmsg 'FAIL'
    Write-Host ''
    Write-Host "连不上 GitHub，三条路都不通：直连 / 反向 SOCKS($Socks) / $Proxy"
    if ($env:SSH_CONNECTION) {
        Write-Host '这台机器是被 ssh 上来的。回到上游机器，用反向 SOCKS 重连再跑：'
        Write-Host ''
        Write-Host '    ssh -R 1080 <本机>'
        Write-Host ''
        Write-Host '或者把这两行写进上游的 ~/.ssh/config，以后自动带上：'
        Write-Host ''
        Write-Host '    Host <本机>'
        Write-Host '      RemoteForward 1080'
    } else {
        Write-Host '安装失败，需要代理环境。'
        Write-Host '本机不是 ssh 会话，没有上游可借；请先让这台机器能上 GitHub，'
        Write-Host '或设 $env:DOTFILES_GH_PROXY=<可用的代理> 重跑。'
    }
    exit 1
}
$direct = ($mode -eq 'direct')
function ghurl($u) {
    if ($mode -eq 'proxy' -and $u -like 'https://github.com/*') { "$Proxy/$u" } else { $u }
}

if (Test-Path $GitDir) {
    step 'fetch 仓库'
    try { dot fetch -q origin; okmsg 'OK' } catch { okmsg 'FAIL（用本地副本继续）' }
} else {
    step 'clone 仓库'
    & git @GitNet clone --bare -q (ghurl $Repo) $GitDir
    if ($LASTEXITCODE -ne 0) { okmsg 'FAIL'; throw '拉不到仓库，检查网络' }
    okmsg 'OK'
}
# push 一律走 SSH：HTTPS 推送要 PAT，GitHub 早就不收密码了。
if ($direct) {
    dot remote set-url --push origin 'git@github.com:erichuanp/dotfiles.git' 2>$null
} else {
    dot remote set-url --push origin 'ssh://git@ssh.github.com:443/erichuanp/dotfiles.git' 2>$null
}
# --bare clone 不建远程跟踪分支，push 会说 no upstream；换标准 refspec 并建好跟踪
dot config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
dot fetch -q origin 2>$null
dot branch --set-upstream-to=origin/main main 2>$null | Out-Null
# 代理模式把 fetch 地址也固化；SOCKS 模式不固化 —— 那条管子不是常在的
if ($mode -eq 'proxy') { dot remote set-url origin (ghurl $Repo) 2>$null }

dot config core.bare false
dot config core.worktree "$HOME"
# 否则 dot status 会把整个家目录当未跟踪文件列出来
dot config status.showUntrackedFiles no
dot config core.sparseCheckout true
dot config core.sparseCheckoutCone false
$files | Set-Content -Encoding ascii (Join-Path $GitDir 'info\sparse-checkout')
# 安全网：仓库是公开的，明文 ssh config 绝不能被 dot add -A 顺手带进去
@('/.ssh/config','/.ssh/authorized_keys','/.ssh/id_*','/.ssh/known_hosts*','/.gitconfig.local',
  '/Documents/PowerShell/profile.local.ps1') |
  Set-Content -Encoding ascii (Join-Path $GitDir 'info\exclude')

step '备份不同旧文件'
$n = 0
foreach ($f in $files) {
    # 加密文件直接覆盖：明文才是本体，密文备份了也没用
    if ($f -like '*.enc') { continue }
    $src = Join-Path $HOME $f
    if (-not (Test-Path $src)) { continue }
    # 比 blob 哈希，和仓库里一模一样就不备份，免得 backup 目录里全是噪音
    $a = (& git --git-dir="$GitDir" hash-object -- "$src" 2>$null)
    $b = (dot rev-parse "HEAD:$f" 2>$null)
    if ($a -and $b -and $a -eq $b) { continue }
    $dst = Join-Path $Backup $f
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Force
    $n++
}
okmsg "$n 个 -> ~\tmp\.dotfiles-backup\"

step '写入配置文件'
dot checkout -f
if ($LASTEXITCODE -ne 0) { okmsg 'FAIL'; throw 'checkout 失败' }
dot reset -q
okmsg 'OK'

if ($tier -eq '1') {
    Write-Host 'SSH 文件解密...'
    $sec = Read-Host 'Password' -AsSecureString
    $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    # 密码不是"检查"，是解密钥匙本身：错了就解不出东西，没有分支可以绕过
    foreach ($f in @('config','authorized_keys')) {
        if (-not (Test-Path "$HOME\.ssh\$f.enc")) { continue }
        step "  解密 $f"
        & openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "pass:$pw" `
            -in "$HOME\.ssh\$f.enc" -out "$HOME\.ssh\$f.new" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Move-Item "$HOME\.ssh\$f.new" "$HOME\.ssh\$f" -Force
            okmsg 'OK'
        } else {
            okmsg '密码错误'
            Remove-Item "$HOME\.ssh\$f.new" -ErrorAction Ignore
            $pw = $null
            exit 1
        }
    }
    $pw = $null
}

foreach ($id in @('Git.Git','GitHub.cli','OpenJS.NodeJS.LTS','Python.Python.3.13')) {
    step $id
    if (winget list --id $id -e 2>$null | Select-String $id) { okmsg 'SKIP' }
    else {
        winget install --id $id -e --silent 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { okmsg 'OK' } else { okmsg 'FAIL' }
    }
}
step 'sshow'
if (Get-Command sshow -ErrorAction Ignore) { okmsg 'SKIP' }
else {
    pip install --user --quiet sshow 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { okmsg 'OK' } else { okmsg 'FAIL' }
}

Write-Host ''
Write-Host '安装完成。'
Write-Host '请重新进 Shell'
Write-Host 'dot h  # 同步教程'
