<#
.SYNOPSIS
    一键提交并推送 customSoundPad 的全部仓库。

.DESCRIPTION
    按正确顺序处理三个仓库：
      1. CustomSoundpad_frontend  (submodule)
      2. InjectAudioApo           (submodule)
      3. 当前 meta 仓库            (记录子模块指针)
    每个仓库先 git add -A，有实际改动才提交，然后推送；
    推送被拒绝时自动 git pull --rebase --autostash 后重试一次。

.PARAMETER Message
    提交信息。默认 "update: yyyy-MM-dd HH:mm"。
    子模块用这条信息；meta 仓库若只有子模块指针变化，会自动改用
    "chore: bump submodules ($Message)"。

.PARAMETER NoPush
    只提交，不推送。

.PARAMETER DryRun
    只显示将要提交的文件，不做任何修改。

.EXAMPLE
    .\update.ps1
    .\update.ps1 "feat: 加入新的 APO 音效链"
    .\update.ps1 -DryRun
    .\update.ps1 "wip" -NoPush

.NOTES
    需要 PowerShell 7+（推荐）或 5.1+，且 git 已配置好 GitHub 凭据。
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Message,

    [switch] $NoPush,

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$script:PushEnabled = -not $NoPush

function Write-Step {
    param([string] $Text, [string] $Color = 'Cyan')
    Write-Host "`n=== $Text ===" -ForegroundColor $Color
}

function Write-Info {
    param([string] $Text, [string] $Color = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Color
}

# 在指定目录执行 git，返回输出行数组；$LastExitCode 由调用方通过 $script:LastExit 获取
function Invoke-GitIn {
    param(
        [string]   $Path,
        [string[]] $Arguments,
        [switch]   $AllowFailure
    )
    Push-Location -LiteralPath $Path
    try {
        $output = & git @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    $script:LastExit = $code
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ("git {0} 执行失败（退出码 {1}），目录：{2}`n{3}" -f ($Arguments -join ' '), $code, $Path, ($output -join "`n"))
    }
    return $output
}

function Get-ChangedPaths {
    param([string] $Path)
    $lines = @(Invoke-GitIn -Path $Path -Arguments @('status', '--porcelain'))
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line.Length -lt 4) { continue }
        $p = $line.Substring(3).Trim()
        # 处理重命名： "old -> new"
        if ($p -like '* -> *') { $p = ($p -split ' -> ')[-1] }
        $p = $p.Trim('"')
        $result.Add($p)
    }
    return $result.ToArray()
}

# 取单行 git 输出（避免 PowerShell 把单元素数组解包成字符串后 [0] 取到 char）
function Get-GitText {
    param(
        [string]   $Path,
        [string[]] $Arguments
    )
    $lines = @(Invoke-GitIn -Path $Path -Arguments $Arguments -AllowFailure)
    if ($script:LastExit -ne 0) { return '' }
    return ($lines -join "`n").Trim()
}

# 嵌套子模块（如 frontend 里的 godot-cpp）自身的未提交内容不会随父仓库推送，这里给出提醒
function Test-NestedDirty {
    param([string] $RepoPath, [string[]] $NestedPaths)
    foreach ($n in $NestedPaths) {
        $p = Join-Path $RepoPath $n
        if (-not (Test-Path -LiteralPath (Join-Path $p '.git'))) { continue }
        $lines = @(Invoke-GitIn -Path $p -Arguments @('status', '--porcelain', '--untracked-files=no') -AllowFailure)
        if ($script:LastExit -eq 0 -and $lines.Count -gt 0) {
            Write-Info "⚠ 嵌套子模块 $n 有 $($lines.Count) 个已跟踪文件被修改，它们不会被提交到这里" 'Yellow'
            Write-Info "  如需一并保存，请进入 $n 自行提交（它是独立仓库）" 'DarkGray'
        }
    }
}

function Push-Branch {
    param([string] $Path, [string] $Label)
    if (-not $script:PushEnabled) {
        Write-Info "跳过推送（-NoPush）" 'DarkGray'
        return
    }
    if ($DryRun) {
        Write-Info "[dry-run] git push" 'DarkGray'
        return
    }

    $branch = Get-GitText -Path $Path -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
    $out = Invoke-GitIn -Path $Path -Arguments @('push') -AllowFailure
    if ($script:LastExit -eq 0) {
        Write-Info "✓ 已推送 $Label ($branch)" 'Green'
        return
    }

    Write-Info "推送被拒绝，尝试 rebase 后重试…" 'Yellow'
    $pull = Invoke-GitIn -Path $Path -Arguments @('pull', '--rebase', '--autostash') -AllowFailure
    if ($script:LastExit -ne 0) {
        Write-Info "rebase 失败，请手动处理后重试：" 'Red'
        $pull | ForEach-Object { Write-Info $_ 'Red' }
        return
    }

    $out = Invoke-GitIn -Path $Path -Arguments @('push', '-u', 'origin', $branch) -AllowFailure
    if ($script:LastExit -eq 0) {
        Write-Info "✓ 已推送 $Label ($branch)" 'Green'
    }
    else {
        Write-Info "✗ 推送仍然失败：" 'Red'
        $out | ForEach-Object { Write-Info $_ 'Red' }
    }
}

function Update-Repo {
    param(
        [string]   $Label,
        [string]   $Path,
        [string]   $CommitMessage,
        [string[]] $NestedPaths = @()
    )

    Write-Step $Label
    Write-Info $Path 'DarkGray'

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        Write-Info "不是 git 仓库，跳过" 'Yellow'
        return
    }

    $changed = @(Get-ChangedPaths -Path $Path)

    if ($changed.Count -eq 0) {
        Write-Info "无改动，跳过提交"
    }
    elseif ($DryRun) {
        Write-Info "待提交 $($changed.Count) 项（dry-run，不执行）：" 'DarkGray'
        $changed | ForEach-Object { Write-Info "  $_" 'DarkGray' }
    }
    else {
        Write-Info "待提交 $($changed.Count) 项"
        Invoke-GitIn -Path $Path -Arguments @('add', '-A') | Out-Null
        $staged = @(Invoke-GitIn -Path $Path -Arguments @('diff', '--cached', '--name-only'))
        if ($staged.Count -eq 0) {
            Write-Info "只有子模块内部状态变化，没有可提交内容" 'Yellow'
        }
        else {
            Invoke-GitIn -Path $Path -Arguments @('commit', '-m', $CommitMessage) | Select-Object -First 1 | ForEach-Object { Write-Info $_ }
            $short = Get-GitText -Path $Path -Arguments @('rev-parse', '--short', 'HEAD')
            Write-Info "✓ 已提交 $short" 'Green'
        }
    }

    Push-Branch -Path $Path -Label $Label
    if ($NestedPaths.Count -gt 0) { Test-NestedDirty -RepoPath $Path -NestedPaths $NestedPaths }
}

# ---------------------------------------------------------------- 主流程 ---

$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location -LiteralPath $root

if (-not $Message) {
    $Message = 'update: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')
}

Write-Host "customSoundPad 提交 + 推送" -ForegroundColor White
Write-Info "仓库根目录：$root"
Write-Info "提交信息：$Message"
if ($DryRun) { Write-Info "模式：dry-run（不会修改任何内容）" 'Yellow' }
if (-not $PushEnabled) { Write-Info "模式：仅提交（-NoPush）" 'Yellow' }

$submodulePaths = @(Get-Content (Join-Path $root '.gitmodules') -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '^\s*path\s*=' } |
    ForEach-Object { ($_ -split '=', 2)[1].Trim() })

# 子模块没初始化时先拉取（只对缺失的生效，已初始化的不受影响）
if (-not $DryRun) {
    $uninitialized = @(Invoke-GitIn -Path $root -Arguments @('submodule', 'status') |
        Where-Object { $_ -match '^-' })
    if ($uninitialized.Count -gt 0) {
        Write-Step "初始化子模块" 'Cyan'
        Invoke-GitIn -Path $root -Arguments @('submodule', 'update', '--init', '--recursive') |
            ForEach-Object { Write-Info $_ 'DarkGray' }
    }
}

foreach ($sub in $submodulePaths) {
    $subPath = Join-Path $root $sub
    # godot-cpp 这种更深一层的子模块，其内部改动由 frontend 仓库的指针体现
    $nested = @(Get-Content (Join-Path $subPath '.gitmodules') -ErrorAction SilentlyContinue |
        Where-Object { $_ -match '^\s*path\s*=' } |
        ForEach-Object { ($_ -split '=', 2)[1].Trim() })
    Update-Repo -Label $sub -Path $subPath -CommitMessage $Message -NestedPaths $nested
}

# meta 仓库：只有子模块指针变化时用专门的提交信息
$metaMessage = $Message
$metaChanged = @(Get-ChangedPaths -Path $root)
if ($metaChanged.Count -gt 0) {
    $nonSubmodule = @($metaChanged | Where-Object { $submodulePaths -notcontains $_ })
    if ($nonSubmodule.Count -eq 0) {
        $metaMessage = "chore: bump submodules ($Message)"
    }
}
Update-Repo -Label (Split-Path $root -Leaf) -Path $root -CommitMessage $metaMessage

Write-Host ""
Write-Host "完成。" -ForegroundColor Green
