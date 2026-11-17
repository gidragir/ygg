# scripts/install.ps1 — Windows Non-Admin Bootstrapper for Yggdrasil (ygg)
$ErrorActionPreference = "Stop"

Write-Host "==> Installing Yggdrasil (ygg) on Windows (Non-Admin)..." -ForegroundColor Cyan

# 1. Ensure user-space directory ~/.local/bin exists
$UserHome = $env:USERPROFILE
$LocalBin = Join-Path $UserHome ".local\bin"
if (-not (Test-Path $LocalBin)) {
    New-Item -ItemType Directory -Force -Path $LocalBin | Out-Null
}

# 2. Check / Install Nushell (via mise, winget, or scoop) without admin
$NuCmd = Get-Command nu -ErrorAction SilentlyContinue
if (-not $NuCmd) {
    if (Get-Command mise -ErrorAction SilentlyContinue) {
        Write-Host "==> Installing nushell via mise..." -ForegroundColor Green
        mise use -g nushell
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "==> Installing nushell via winget..." -ForegroundColor Green
        winget install --id Nushell.Nushell --exact --accept-source-agreements --accept-package-agreements
    } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
        Write-Host "==> Installing nushell via scoop..." -ForegroundColor Green
        scoop install nu
    } else {
        Write-Host "==> Installing mise for Windows..." -ForegroundColor Green
        Invoke-RestMethod https://mise.run | Invoke-Expression
        $env:PATH = "$LocalBin;$env:PATH"
        mise use -g nushell
    }
}

# Refresh PATH to locate nu
$NuCmd = Get-Command nu -ErrorAction SilentlyContinue
if (-not $NuCmd) {
    $PossibleNuPaths = @(
        (Join-Path $LocalBin "nu.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\nu.exe"),
        (Join-Path $UserHome "scoop\shims\nu.exe")
    )
    foreach ($p in $PossibleNuPaths) {
        if (Test-Path $p) {
            $NuDir = Split-Path $p -Parent
            $env:PATH = "$NuDir;$env:PATH"
            break
        }
    }
}

# 3. Clone or update ygg engine into ~/.ygg/.engine
#    $env:YGG_CHANNEL = "stable" (default): latest v<semver> release tag; "main": tip of main
$YggHome = if ($env:YGG_HOME) { $env:YGG_HOME } else { Join-Path $UserHome ".ygg" }
$EngineDir = Join-Path $YggHome ".engine"
$Channel = if ($env:YGG_CHANNEL) { $env:YGG_CHANNEL } else { "stable" }
if ($Channel -notin @("stable", "main")) {
    throw "YGG_CHANNEL must be 'stable' or 'main' (got '$Channel')."
}

function Invoke-Git {
    git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

if (-not (Test-Path $YggHome)) {
    New-Item -ItemType Directory -Force -Path $YggHome | Out-Null
}

if (-not (Test-Path (Join-Path $EngineDir ".git"))) {
    Write-Host "==> Cloning ygg engine to $EngineDir..." -ForegroundColor Green
    if (Test-Path $EngineDir) {
        Remove-Item -Recurse -Force $EngineDir
    }
    Invoke-Git clone --quiet https://github.com/gidragir/ygg.git $EngineDir
} elseif (git -C $EngineDir status --porcelain --untracked-files=no) {
    Write-Host "==> $EngineDir has uncommitted changes, leaving the engine as is." -ForegroundColor Yellow
    $Channel = "keep"
} else {
    Write-Host "==> Updating existing ygg engine in $EngineDir..." -ForegroundColor Green
    Invoke-Git -C $EngineDir fetch --quiet --tags --force origin
}

if ($Channel -eq "stable") {
    $Tag = git -C $EngineDir tag --list "v*" --sort=v:refname |
        Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } | Select-Object -Last 1
    if ($Tag) {
        Write-Host "==> Using ygg release $Tag" -ForegroundColor Green
        Invoke-Git -C $EngineDir -c advice.detachedHead=false checkout --quiet --detach $Tag
    } else {
        Write-Host "==> No ygg release tags found, falling back to main." -ForegroundColor Yellow
        $Channel = "main"
    }
}
if ($Channel -eq "main") {
    Write-Host "==> Using ygg main branch" -ForegroundColor Green
    Invoke-Git -C $EngineDir checkout --quiet main
    Invoke-Git -C $EngineDir merge --quiet --ff-only origin/main
}

# 4. Copy Windows batch shim to ~/.local/bin/ygg.cmd
$ShimSrc = Join-Path $EngineDir "bin\ygg.cmd"
$ShimDest = Join-Path $LocalBin "ygg.cmd"
Copy-Item -Path $ShimSrc -Destination $ShimDest -Force

# Also copy ygg extensionless shim for git bash / nushell
$ShSrc = Join-Path $EngineDir "bin\ygg"
$ShDest = Join-Path $LocalBin "ygg"
if (Test-Path $ShSrc) {
    Copy-Item -Path $ShSrc -Destination $ShDest -Force
}

# 5. Ensure ~/.local/bin is in User Environment PATH
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$LocalBin*") {
    Write-Host "==> Adding $LocalBin to User PATH..." -ForegroundColor Green
    $NewPath = if ([string]::IsNullOrEmpty($UserPath)) { $LocalBin } else { "$UserPath;$LocalBin" }
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    $env:PATH = "$LocalBin;$env:PATH"
}

Write-Host "`n✅ Yggdrasil installed successfully!" -ForegroundColor Green
Write-Host "Restart your terminal or run: ygg --help" -ForegroundColor Yellow
