# dotfiles 引导（Windows）。仓库是 bare git repo，$HOME 就是工作区。
#
#   irm https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.ps1 | iex
#
$ErrorActionPreference = 'Stop'
$Repo    = if ($env:DOTFILES_REPO) { $env:DOTFILES_REPO } else { 'https://github.com/erichuanp/dotfiles.git' }
$GitDir  = Join-Path $HOME '.dotfiles'
$Backup  = Join-Path $HOME 'tmp\.dotfiles-backup'
$Proxy   = if ($env:DOTFILES_GH_PROXY) { $env:DOTFILES_GH_PROXY } else { 'https://ghfast.top' }

function dot { & git --git-dir="$GitDir" --work-tree="$HOME" @args }
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
step 'github.com 连通性'
$direct = $false
try {
    Invoke-WebRequest -Uri 'https://github.com/' -Method Head -TimeoutSec 25 -UseBasicParsing | Out-Null
    $direct = $true
} catch { $direct = $false }
if ($direct) { okmsg 'OK' } else { okmsg "不通 -> $Proxy" }
function ghurl($u) {
    if (-not $direct -and $u -like 'https://github.com/*') { "$Proxy/$u" } else { $u }
}

if (Test-Path $GitDir) {
    step 'fetch 仓库'
    try { dot fetch -q origin; okmsg 'OK' } catch { okmsg 'FAIL（用本地副本继续）' }
} else {
    step 'clone 仓库'
    git clone --bare -q (ghurl $Repo) $GitDir
    if ($LASTEXITCODE -ne 0) { okmsg 'FAIL'; throw '拉不到仓库，检查网络' }
    okmsg 'OK'
}
if (-not $direct) {
    dot remote set-url --push origin 'ssh://git@ssh.github.com:443/erichuanp/dotfiles.git' 2>$null
}

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
