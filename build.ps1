#Requires -Version 5.1
<#
.SYNOPSIS
    一键构建 CustomSoundpad：编译 InjectAudioApo -> 拷贝 DLL/signtool -> Godot 导出 Windows -> 拷贝 bin。

.DESCRIPTION
    步骤：
      1. 用 MSBuild 编译 InjectAudioApo（默认 Debug|x64，产物在 InjectAudioApo\build\bin\x64\<配置>）。
      2. 拷贝 InjectAudioApo.dll 到 CustomSoundpad_frontend\bin\InjectAudioApo.dll。
      3. 从 Windows SDK 找到最新的 x64 signtool.exe 并拷贝到 CustomSoundpad_frontend\bin。
      4. 用 Godot 导出 "Windows Desktop" 预设到 build\<项目名>.exe。
      5. 拷贝 CustomSoundpad_frontend\bin 到 build\bin。

.PARAMETER ApoConfiguration
    InjectAudioApo 的编译配置，Debug（默认）或 Release。

.PARAMETER ExportMode
    Godot 导出模式，release（默认）或 debug。

.PARAMETER Preset
    Godot 导出预设名，默认 "Windows Desktop"。

.PARAMETER GodotExe
    Godot 可执行文件路径。默认依次查找：本参数 -> 环境变量 GODOT_EXE -> PATH 上的 godot* -> 桌面 Godot* 目录。

.PARAMETER OutputName
    导出的 exe 名称（不含扩展名）。默认取 project.godot 里的 config/name。

.PARAMETER SkipApo
    跳过步骤 1。

.PARAMETER SkipGodot
    跳过步骤 4。

.PARAMETER SkipBinCopy
    跳过步骤 5。

.PARAMETER InstallTemplates
    导出模板缺失时自动下载并安装（Godot mono 模板约 1GB，需要网络）。

.EXAMPLE
    .\build.ps1
    .\build.ps1 -ApoConfiguration Release -ExportMode release
    .\build.ps1 -SkipApo
    .\build.ps1 -InstallTemplates
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $ApoConfiguration = 'Debug',

    [ValidateSet('debug', 'release')]
    [string] $ExportMode = 'release',

    [string] $Preset = 'Windows Desktop',

    [string] $GodotExe,

    [string] $OutputName,

    [switch] $SkipApo,

    [switch] $SkipGodot,

    [switch] $SkipBinCopy,

    [switch] $InstallTemplates
)

$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$frontend = Join-Path $root 'CustomSoundpad_frontend'
$apo = Join-Path $root 'InjectAudioApo'
$frontendBin = Join-Path $frontend 'bin'
$outDir = Join-Path $root 'build'

function Write-Step {
    param([string] $Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Write-Info {
    param([string] $Text, [string] $Color = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Color
}

function Fail {
    param([string] $Text)
    throw $Text
}

function Resolve-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null |
            Select-Object -First 1
        if ($found) { return $found }
    }
    $command = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Resolve-Godot {
    if ($GodotExe) {
        if (-not (Test-Path -LiteralPath $GodotExe)) { Fail "Godot 不存在：$GodotExe" }
        return (Resolve-Path -LiteralPath $GodotExe).Path
    }
    if ($env:GODOT_EXE -and (Test-Path -LiteralPath $env:GODOT_EXE)) {
        return (Resolve-Path -LiteralPath $env:GODOT_EXE).Path
    }
    foreach ($name in @('godot', 'godot4', 'godot_console', 'godot4_console')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop -and (Test-Path -LiteralPath $desktop)) {
        $found = Get-ChildItem -LiteralPath $desktop -Directory -Filter 'Godot*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'Godot*_console.exe' -ErrorAction SilentlyContinue } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Get-ProjectName {
    $projectFile = Join-Path $frontend 'project.godot'
    if (Test-Path -LiteralPath $projectFile) {
        $match = Select-String -LiteralPath $projectFile -Pattern '^\s*config/name\s*=\s*"([^"]*)"' |
            Select-Object -First 1
        if ($match -and $match.Matches.Count -gt 0) {
            return $match.Matches[0].Groups[1].Value
        }
    }
    return 'CustomSoundpad'
}

function Assert-PresetExists {
    param([string] $Name)
    $presetFile = Join-Path $frontend 'export_presets.cfg'
    if (-not (Test-Path -LiteralPath $presetFile)) {
        Fail "找不到导出预设文件：$presetFile"
    }
    $names = @(Select-String -LiteralPath $presetFile -Pattern '^name="([^"]+)"' |
        ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($names -notcontains $Name) {
        Fail "导出预设不存在：`"$Name`"（可用：$($names -join ', ')）"
    }
}

function Get-TemplateVersionKey {
    param([string] $GodotPath)
    $line = (& $GodotPath --headless --version 2>$null | Select-Object -First 1)
    if (-not $line) { return $null }
    $parts = ($line -split '\.')
    if ($parts.Count -lt 4) { return $null }
    $flavor = if ($line -match 'mono') { 'mono' } else { '' }
    $key = "$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])"
    if ($flavor) { $key = "$key.$flavor" }
    return $key
}

function Install-ExportTemplates {
    param([string] $VersionKey)

    $parts = $VersionKey.Split('.')
    if ($parts.Count -lt 4) { Fail "无法解析版本：$VersionKey" }
    $tag = "$($parts[0]).$($parts[1]).$($parts[2])-$($parts[3])"
    $flavor = if ($VersionKey -match 'mono') { '_mono' } else { '' }
    $asset = "Godot_v$tag${flavor}_export_templates.tpz"
    $url = "https://github.com/godotengine/godot/releases/download/$tag/$asset"

    $templateRoot = Join-Path $env:APPDATA "Godot\export_templates\$VersionKey"
    $tempTpz = Join-Path ([IO.Path]::GetTempPath()) $asset
    $tempExtract = Join-Path ([IO.Path]::GetTempPath()) "godot_templates_$VersionKey"

    Write-Info "下载导出模板：$url" 'Yellow'
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $url -OutFile $tempTpz -UseBasicParsing
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    if (Test-Path -LiteralPath $tempExtract) { Remove-Item -LiteralPath $tempExtract -Recurse -Force }
    Expand-Archive -LiteralPath $tempTpz -DestinationPath $tempExtract -Force
    $source = Join-Path $tempExtract 'templates'
    if (-not (Test-Path -LiteralPath $source)) { $source = $tempExtract }

    New-Item -ItemType Directory -Path $templateRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $templateRoot -Recurse -Force
    Remove-Item -LiteralPath $tempTpz -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Info "模板已安装：$templateRoot" 'Green'
}

function Ensure-ExportTemplates {
    param([string] $GodotPath)

    $versionKey = Get-TemplateVersionKey -GodotPath $GodotPath
    if (-not $versionKey) {
        Write-Info '无法确定 Godot 版本，跳过模板检查。' 'Yellow'
        return
    }
    $templateRoot = Join-Path $env:APPDATA "Godot\export_templates\$versionKey"
    $expected = Join-Path $templateRoot "windows_${ExportMode}_x86_64.exe"
    if (Test-Path -LiteralPath $expected) {
        return
    }
    if (-not $InstallTemplates) {
        Fail ("缺少导出模板：$expected`n" +
              "  可在编辑器里 编辑器 -> 管理导出模板 -> 下载并安装；`n" +
              "  或重新运行：.\build.ps1 -InstallTemplates（mono 模板约 1GB）。")
    }
    Install-ExportTemplates -VersionKey $versionKey
    if (-not (Test-Path -LiteralPath $expected)) {
        Fail "模板安装后仍找不到：$expected"
    }
}

Write-Host 'CustomSoundpad 构建' -ForegroundColor White
Write-Info "根目录：$root"
Write-Info "APO 配置：$ApoConfiguration | 导出模式：$ExportMode"

# ---------------------------------------------------------------- 1/5 APO

if ($SkipApo) {
    Write-Step '1/5 跳过 InjectAudioApo 构建 (-SkipApo)'
}
else {
    Write-Step "1/5 构建 InjectAudioApo ($ApoConfiguration|x64)"
    $msbuild = Resolve-MSBuild
    if (-not $msbuild) {
        Fail '找不到 MSBuild：请安装 Visual Studio 的 MSBuild 组件，或把 msbuild 加入 PATH。'
    }
    Write-Info "MSBuild: $msbuild" 'DarkGray'

    $solution = Join-Path $apo 'InjectAudioApo.slnx'
    $target = if (Test-Path -LiteralPath $solution) { $solution } else { Join-Path $apo 'Apo\InjectAudioApo.vcxproj' }
    if (-not (Test-Path -LiteralPath $target)) {
        Fail "找不到 InjectAudioApo 工程：$target"
    }
    Write-Info "工程: $target" 'DarkGray'

    & $msbuild $target /nologo /m /v:m "/p:Configuration=$ApoConfiguration" '/p:Platform=x64'
    if ($LASTEXITCODE -ne 0) {
        Fail "MSBuild 失败（退出码 $LASTEXITCODE）。"
    }
}

# ---------------------------------------------------------------- 2/5 DLL

Write-Step '2/5 拷贝未签名 APO DLL 到 frontend\bin'
$builtDll = Join-Path $apo "build\bin\x64\$ApoConfiguration\InjectAudioApo.dll"
if (-not (Test-Path -LiteralPath $builtDll)) {
    Fail "找不到构建产物：$builtDll"
}
if (-not (Test-Path -LiteralPath $frontendBin)) {
    New-Item -ItemType Directory -Path $frontendBin -Force | Out-Null
}
$dllTarget = Join-Path $frontendBin 'InjectAudioApo_unsign.dll'
Copy-Item -LiteralPath $builtDll -Destination $dllTarget -Force
Write-Info "$builtDll -> $dllTarget" 'Green'
Write-Info '（安装时由 ApoInstaller 复制为 InjectAudioApo.dll 并签名）' 'DarkGray'

$staleSigned = Join-Path $frontendBin 'InjectAudioApo.dll'
if (Test-Path -LiteralPath $staleSigned) {
    try {
        Remove-Item -LiteralPath $staleSigned -Force
        Write-Info '已删除旧的 InjectAudioApo.dll（安装时重新生成）' 'DarkGray'
    }
    catch {
        Write-Info "旧的 InjectAudioApo.dll 被占用，保留：$($_.Exception.Message)" 'Yellow'
    }
}

# ---------------------------------------------------------------- 3/5 signtool

Write-Step '3/5 拷贝 signtool.exe'
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\signtool.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if ($signtool) {
    Copy-Item -LiteralPath $signtool -Destination (Join-Path $frontendBin 'signtool.exe') -Force
    Write-Info "$signtool -> $frontendBin\signtool.exe" 'Green'
}
else {
    Write-Info '未找到 Windows SDK 的 x64 signtool.exe，跳过（ApoInstaller 会回退到系统搜索）。' 'Yellow'
}

# ---------------------------------------------------------------- 4/5 Godot

$exportedExe = $null
if ($SkipGodot) {
    Write-Step '4/5 跳过 Godot 导出 (-SkipGodot)'
}
else {
    Write-Step "4/5 Godot 导出 ($Preset / $ExportMode)"
    $godot = Resolve-Godot
    if (-not $godot) {
        Fail '找不到 Godot 可执行文件：请用 -GodotExe 指定，或设置环境变量 GODOT_EXE。'
    }
    Write-Info "Godot: $godot" 'DarkGray'

    Assert-PresetExists -Name $Preset
    Ensure-ExportTemplates -GodotPath $godot

    $name = if ($OutputName) { $OutputName } else { Get-ProjectName }
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $exportedExe = Join-Path $outDir "$name.exe"

    & $godot --headless --path $frontend "--export-$ExportMode" $Preset $exportedExe
    if ($LASTEXITCODE -ne 0) {
        Fail "Godot 导出失败（退出码 $LASTEXITCODE）。"
    }
    if (-not (Test-Path -LiteralPath $exportedExe)) {
        Fail "导出命令结束但找不到产物：$exportedExe"
    }
    Write-Info "-> $exportedExe" 'Green'
}

# ---------------------------------------------------------------- 5/5 bin

if ($SkipBinCopy) {
    Write-Step '5/5 跳过 bin 拷贝 (-SkipBinCopy)'
}
else {
    Write-Step '5/5 拷贝 frontend\bin 到 build\bin'
    if (-not (Test-Path -LiteralPath $frontendBin)) {
        Fail "找不到目录：$frontendBin"
    }
    $targetBin = Join-Path $outDir 'bin'
    if (Test-Path -LiteralPath $targetBin) {
        Remove-Item -LiteralPath $targetBin -Recurse -Force
    }
    Copy-Item -LiteralPath $frontendBin -Destination $targetBin -Recurse -Force
    Write-Info "$frontendBin -> $targetBin" 'Green'
}

Write-Host ''
Write-Host '构建完成。' -ForegroundColor Green
if ($exportedExe) {
    Write-Host "产物：$exportedExe" -ForegroundColor White
}
