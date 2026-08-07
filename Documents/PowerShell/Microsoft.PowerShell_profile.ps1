if (-not (Get-Command poetry -ErrorAction Ignore)) { $env:Path += ";$env:APPDATA\Python\Scripts" }

# prompt: (conda) 主机名:目录  SSH=绿 本机=黄
function Prompt {
    $condaEnv = $env:CONDA_DEFAULT_ENV
    if ($condaEnv) {
        $condaPart = "`e[96m($condaEnv)`e[0m "
    } else {
        $condaPart = ""
    }

    $fullHostname = $env:COMPUTERNAME
    $shortHostname = $fullHostname -replace ".*?-", ""

    if ($env:SSH_CONNECTION) {
        $hostname = "`e[92m$shortHostname`e[0m:"
    } else {
        $hostname = "`e[33m$shortHostname`e[0m:"
    }

    # 路径：父文件夹\当前文件夹\（盘根显示 C:\）
    $currentPath = (Get-Location).Path
    $pathDisplay = if ($currentPath -match "^[a-zA-Z]:\\$") {
        $currentPath
    } else {
        $leaf = Split-Path -Leaf $currentPath
        $parentPath = Split-Path -Parent $currentPath
        if ($parentPath -match "^[a-zA-Z]:\\$") {
            "$parentPath$leaf\"
        } else {
            "$(Split-Path -Leaf $parentPath)\$leaf\"
        }
    }
    $folderColor = "`e[94m$pathDisplay`e[0m"

    "$condaPart$hostname$folderColor "
}

# sfp <host> <port> [extra-url] — SSH 端口转发；不开浏览器，只打印可点击 URL
function sfp {
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$hostname,

        [Parameter(Mandatory=$true, Position=1)]
        [int]$port,

        [Parameter(Mandatory=$false, Position=2)]
        [string]$url
    )

    $ip = (ssh -G $hostname 2>$null | Select-String '^hostname (.+)$').Matches.Groups[1].Value

    Write-Host "http://localhost:$port/" -ForegroundColor Cyan
    Write-Host "https://localhost:$port/" -ForegroundColor Cyan
    if ($ip) {
        Write-Host "http://${ip}:$port/" -ForegroundColor Cyan
        Write-Host "https://${ip}:$port/" -ForegroundColor Cyan
    }
    if ($url) { Write-Host $url -ForegroundColor Cyan }

    Write-Host "[sfp] forwarding $port -> ${hostname}:127.0.0.1:$port  (Ctrl+C 退出)"
    ssh -N -L "${port}:127.0.0.1:${port}" $hostname
}

function claude {
    & "$HOME\.local\bin\claude.exe" --dangerously-skip-permissions @args
}

# dotup — 工具更新检查器（手动触发：update / dotup）
# A:全部更新 Y:更新该工具 N:暂不更新 I:跳过该版本 其他:退出
function dotup {
    # 非交互环境直接退出
    if ([Console]::IsInputRedirected -or ([Environment]::GetCommandLineArgs() -match '-NonInteractive')) { return }

    $ignoreFile = "$env:APPDATA\dotup\ignore.txt"
    New-Item -ItemType Directory -Force (Split-Path $ignoreFile) | Out-Null
    if (-not (Test-Path $ignoreFile)) { New-Item -ItemType File $ignoreFile | Out-Null }
    $ignored = @(Get-Content $ignoreFile)

    $managedIds = @('Git.Git','GitHub.cli','OpenJS.NodeJS.LTS','Python.Python.3.13','tmux')
    $updates = @()
    foreach ($line in (winget upgrade --accept-source-agreements 2>$null)) {
        $t = -split $line
        if ($t.Count -ge 5 -and $managedIds -contains $t[-4]) {
            $updates += [pscustomobject]@{ Id = $t[-4]; Cur = $t[-3]; New = $t[-2] }
        }
    }
    if (-not $updates) { return }

    $all = $false
    foreach ($u in $updates) {
        if ($ignored -contains "$($u.Id) $($u.New)") { continue }
        if ($all) { winget upgrade --id $u.Id -e; continue }
        $ans = Read-Host "dotup: $($u.Id) $($u.Cur) -> $($u.New)  [A:全部更新 Y:更新该工具 N:暂不更新工具 I:跳过该版本 其他:暂不全部更新]"
        switch -Regex ($ans) {
            '^[Yy]$' { winget upgrade --id $u.Id -e }
            '^[Aa]$' { $all = $true; winget upgrade --id $u.Id -e }
            '^[Nn]$' { }
            '^[Ii]$' { Add-Content $ignoreFile "$($u.Id) $($u.New)" }
            default  { return }
        }
    }
}
Set-Alias -Name update -Value dotup

# psrc 工具：code/vim/nano=编辑 profile.local.ps1  "命令"/文件=追加（不纳管）
# PS 函数内 dot-source 是局部作用域，重载只能提示执行 . $PROFILE
function psrc {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
    $rc = $PROFILE.CurrentUserCurrentHost
    $lc = Join-Path (Split-Path $rc) 'profile.local.ps1'
    function script:_psrcAdd([string]$line) {
        if (-not $line) { return }
        if (-not (Test-Path $lc) -or (@(Get-Content $lc) -notcontains $line)) { Add-Content $lc $line }
    }
    if (-not $Rest) { Write-Host "运行 . `$PROFILE 生效（或重开终端）" -ForegroundColor Yellow; return }
    $cmd = $Rest -join ' '
    switch ($cmd) {
        'code' { code $lc; return }
        'vim'  { vim $lc; return }
        'nano' { nano $lc; return }
        default {
            if ($Rest.Count -eq 1 -and (Test-Path $cmd -PathType Leaf)) {
                foreach ($line in Get-Content $cmd) { _psrcAdd $line }
            } else {
                _psrcAdd $cmd
            }
            Write-Host "已写入 profile.local.ps1，运行 . `$PROFILE 生效（或重开终端）" -ForegroundColor Yellow
        }
    }
}

# dot 包装：pull 成功后提示重载
function dot {
    if ($args.Count -ge 1 -and $args[0] -eq 'h') {
        @'
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
# 重新进 Shell

如果有不想纳管的文件，请用 *.local 来 append 到已纳管文件。
  ~/.gitconfig.local   Documents/PowerShell/profile.local.ps1
'@ | Write-Host
        return
    }
    $exe = Get-Command git -CommandType Application -ErrorAction Stop
    & $exe --git-dir="$HOME\.dotfiles" --work-tree="$HOME" @args
    if ($LASTEXITCODE -eq 0 -and $args.Count -ge 1 -and @('pull','checkout','reset') -contains $args[0]) {
        Write-Host "配置已更新：运行 . `$PROFILE 生效（或重开终端）" -ForegroundColor Yellow
    }
}

# dotseal：把明文 ~/.ssh/{config,authorized_keys} 重新加密回仓库
# 改完 ssh 相关文件必须跑一次，否则提交上去的还是旧密文
function dotseal {
    $any = $false
    foreach ($f in @('config','authorized_keys')) {
        $src = "$HOME\.ssh\$f"
        if (-not (Test-Path $src)) { continue }
        & openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -in $src -out "$src.enc"
        if ($LASTEXITCODE -ne 0) { return }
        dot add "$src.enc"; $any = $true
    }
    if ($any) { Write-Host '已加密并 staged，接着 dot commit && dot push' }
    else { Write-Host '没有可加密的文件' }
}

# ---- 提醒仓库有没有新版本
#      判断只用本地已有的 origin/main，不产生任何网络等待；
#      真正的 fetch 丢后台且每 6 小时最多一次 —— 开终端不该被网络卡住。
$_g = Join-Path $HOME '.dotfiles'
if (Test-Path $_g) {
    $_behind = & git --git-dir="$_g" rev-list --count HEAD..origin/main 2>$null
    if ($_behind -and [int]$_behind -gt 0) {
        Write-Host "dotfiles 落后 $_behind 个提交： dot pull，然后 . `$PROFILE" -ForegroundColor Yellow
    }
    $_stamp = Join-Path $_g '.last-fetch'
    if (-not (Test-Path $_stamp) -or ((Get-Date) - (Get-Item $_stamp).LastWriteTime).TotalHours -gt 6) {
        Start-Process -FilePath 'git' -ArgumentList "--git-dir=$_g","fetch","-q","origin" -WindowStyle Hidden
        New-Item -ItemType File -Force $_stamp | Out-Null
    }
}

# 本机私有补充（此文件不纳管）
$_localProfile = Join-Path (Split-Path $PROFILE.CurrentUserCurrentHost) 'profile.local.ps1'
if (Test-Path $_localProfile) { . $_localProfile }
