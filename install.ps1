# dotfiles 引导（Windows）。仓库是 bare git repo，$HOME 就是工作区。
#
#   irm https://raw.githubusercontent.com/erichuanp/dotfiles/main/install.ps1 | iex
#
$ErrorActionPreference = 'Stop'
$Repo    = if ($env:DOTFILES_REPO) { $env:DOTFILES_REPO } else { 'https://github.com/erichuanp/dotfiles.git' }
$GitDir  = Join-Path $HOME '.dotfiles'
$Backup  = Join-Path $HOME '.dotfiles-backup'

function dot { & git --git-dir="$GitDir" --work-tree="$HOME" @args }
function say($m) { Write-Host "[dotfiles] $m" -ForegroundColor Cyan }

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
    Write-Host '  1) 个人设备      —— 全套，含 ssh config（需密码解密）+ authorized_keys'
    Write-Host '  2) 公司个人用户  —— 除 ssh 相关外全套'
    $tier = Read-Host '选择 [1/2]'
}
$files = switch ($tier) {
    '1' { $Common + $HostOnly + $Personal }
    '2' { $Common + $HostOnly }
    default { throw "无效选择：$tier" }
}
say "分级 $tier"

if (Test-Path $GitDir) { say "已存在 $($GitDir) ，只更新分级与工作区"; dot fetch -q origin }
else { git clone --bare -q $Repo $GitDir }

dot config core.bare false
dot config core.worktree "$HOME"
dot config status.showUntrackedFiles no
dot config core.sparseCheckout true
dot config core.sparseCheckoutCone false
$files | Set-Content -Encoding ascii (Join-Path $GitDir 'info\sparse-checkout')
@('/.ssh/config','/.ssh/authorized_keys','/.ssh/id_*','/.ssh/known_hosts*','/.gitconfig.local',
  '/Documents/PowerShell/profile.local.ps1') |
  Set-Content -Encoding ascii (Join-Path $GitDir 'info\exclude')

foreach ($f in $files) {
    $src = Join-Path $HOME $f
    if (Test-Path $src) {
        $dst = Join-Path $Backup $f
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item $src $dst -Force
    }
}
if (Test-Path $Backup) { say "旧文件已备份到 $Backup" }

dot checkout -f
dot reset -q

if ($tier -eq '1') {
    $sec = Read-Host '解密密码（ssh config / authorized_keys）' -AsSecureString
    $pw  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
             [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    foreach ($n in @('config','authorized_keys')) {
        if (-not (Test-Path "$HOME\.ssh\$n.enc")) { continue }
        & openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "pass:$pw" `
            -in "$HOME\.ssh\$n.enc" -out "$HOME\.ssh\$n.new" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Move-Item "$HOME\.ssh\$n.new" "$HOME\.ssh\$n" -Force
            say "$n 已解密"
        } else {
            Remove-Item "$HOME\.ssh\$n.new" -ErrorAction Ignore
            $pw = $null
            throw "密码错误，$n 未写入"
        }
    }
    $pw = $null
}

foreach ($id in @('Git.Git','GitHub.cli','OpenJS.NodeJS.LTS','Python.Python.3.13')) {
    if (-not (winget list --id $id -e 2>$null | Select-String $id)) { winget install --id $id -e --silent }
}
if (-not (Get-Command sshow -ErrorAction Ignore)) { pip install --user --quiet sshow }

say '完成。运行 . $PROFILE 或重开终端。'
