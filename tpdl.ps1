param(
    [Parameter(Position = 0)]
    [string] $Repository,

    [Alias("r", "Checkout")]
    [string] $Ref,

    [Alias("n")]
    [string] $Namespace = "local",

    [Alias("p")]
    [string] $PackagePath,

    [Alias("f")]
    [switch] $Force,

    [switch] $KeepTemp,

    [Alias("h")]
    [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-Usage {
    Write-Host @"
Usage: .\tpdl.ps1 <git-repository> [options]

Options:
  -Ref, -Checkout <ref>       Git tag, branch, or commit to checkout.
  -Namespace, -n <name>       Typst namespace to install into (default: local).
  -PackagePath, -p <dir>      Typst package data path (default: TYPST_PACKAGE_PATH or system data dir).
  -Force, -f                  Replace an existing package version.
  -Help, -h                   Print this help.

Installs to:
  {package-path}/{namespace}/{package.name}/{package.version}
"@
}

function Fail {
    param([string] $Message)
    Write-Error $Message
    exit 1
}

if ($Help) {
    Show-Usage
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Repository)) {
    Show-Usage
    exit 1
}

function Resolve-FullPath {
    param([string] $Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-RelativePath {
    param(
        [string] $BasePath,
        [string] $Path
    )
    $base = Resolve-FullPath $BasePath
    if (-not $base.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $base += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = New-Object System.Uri($base)
    $pathUri = New-Object System.Uri((Resolve-FullPath $Path))
    $relative = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString())
    return $relative -replace '/', [System.IO.Path]::DirectorySeparatorChar
}

function Resolve-TypstPackagePath {
    if (-not [string]::IsNullOrWhiteSpace($PackagePath)) {
        return Resolve-FullPath $PackagePath
    }

    if (-not [string]::IsNullOrWhiteSpace($env:TYPST_PACKAGE_PATH)) {
        return Resolve-FullPath $env:TYPST_PACKAGE_PATH
    }

    $homeDir = [Environment]::GetFolderPath("UserProfile")
    $isWindowsOs = $env:OS -eq "Windows_NT" -or [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $isMacOs = -not $isWindowsOs -and (uname -s 2>$null) -eq "Darwin"
    if ($isWindowsOs) {
        $dataDir = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $homeDir "AppData\Roaming" }
    }
    elseif ($isMacOs) {
        $dataDir = Join-Path $homeDir "Library/Application Support"
    }
    else {
        $dataDir = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $homeDir ".local/share" }
    }

    return Join-Path $dataDir "typst/packages"
}

function Normalize-Namespace {
    param([string] $Value)
    $normalized = $Value.Trim()
    while ($normalized.StartsWith("@")) {
        $normalized = $normalized.Substring(1)
    }
    return $normalized
}

function Assert-TypstIdentifier {
    param(
        [string] $Value,
        [string] $Label
    )
    if ($Value -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') {
        Fail "$Label '$Value' is not a valid Typst package identifier for this script."
    }
}

function Assert-TypstVersion {
    param([string] $Value)
    if ($Value -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        Fail "package.version '$Value' is not a valid Typst package version. Expected major.minor.patch."
    }
}

function Read-TomlString {
    param(
        [string] $Body,
        [string] $Key
    )
    $pattern = '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*(?:"(?<double>(?:\\"|[^"])*)"|''(?<single>[^'']*)'')'
    $match = [regex]::Match($Body, $pattern)
    if (-not $match.Success) {
        return $null
    }
    if ($match.Groups["double"].Success) {
        return $match.Groups["double"].Value -replace '\\"', '"'
    }
    return $match.Groups["single"].Value
}

function Read-TomlStringArray {
    param(
        [string] $Body,
        [string] $Key
    )
    $pattern = '(?ms)^\s*' + [regex]::Escape($Key) + '\s*=\s*\[(?<items>.*?)\]'
    $match = [regex]::Match($Body, $pattern)
    if (-not $match.Success) {
        return @()
    }

    $items = @()
    foreach ($item in [regex]::Matches($match.Groups["items"].Value, '(?:"(?<double>(?:\\"|[^"])*)"|''(?<single>[^'']*)'')')) {
        if ($item.Groups["double"].Success) {
            $items += ($item.Groups["double"].Value -replace '\\"', '"')
        }
        else {
            $items += $item.Groups["single"].Value
        }
    }
    return $items
}

function Read-PackageManifest {
    param([string] $RepoDir)
    $manifestPath = Join-Path $RepoDir "typst.toml"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Fail "Repository root does not contain typst.toml."
    }

    $content = Get-Content -LiteralPath $manifestPath -Raw
    $package = [regex]::Match($content, '(?ms)^\s*\[package\]\s*(?<body>.*?)(?=^\s*\[|\z)')
    if (-not $package.Success) {
        Fail "typst.toml is missing a [package] table."
    }

    $body = $package.Groups["body"].Value
    $name = Read-TomlString $body "name"
    $version = Read-TomlString $body "version"
    $entrypoint = Read-TomlString $body "entrypoint"
    $exclude = Read-TomlStringArray $body "exclude"

    if ([string]::IsNullOrWhiteSpace($name)) {
        Fail "typst.toml is missing package.name."
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        Fail "typst.toml is missing package.version."
    }
    if ([string]::IsNullOrWhiteSpace($entrypoint)) {
        Fail "typst.toml is missing package.entrypoint."
    }

    Assert-TypstIdentifier $name "package.name"
    Assert-TypstVersion $version

    return [pscustomobject]@{
        Name = $name
        Version = $version
        Entrypoint = $entrypoint
        Exclude = $exclude
    }
}

function Convert-GlobToRegex {
    param([string] $Pattern)
    $result = New-Object System.Text.StringBuilder
    $chars = $Pattern.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $char = $chars[$i]
        if ($char -eq '*') {
            if (($i + 1) -lt $chars.Length -and $chars[$i + 1] -eq '*') {
                [void] $result.Append(".*")
                $i++
            }
            else {
                [void] $result.Append("[^/]*")
            }
        }
        elseif ($char -eq '?') {
            [void] $result.Append("[^/]")
        }
        else {
            [void] $result.Append([regex]::Escape([string] $char))
        }
    }
    return "^$($result.ToString())$"
}

function Normalize-RelativePackagePath {
    param([string] $Path)
    $normalized = $Path -replace '\\', '/'
    while ($normalized.StartsWith("./")) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized.TrimEnd("/")
}

function Test-ExcludedPath {
    param(
        [string] $RelativePath,
        [string[]] $Patterns
    )
    $relative = Normalize-RelativePackagePath $RelativePath
    if ($relative -eq ".git" -or $relative.StartsWith(".git/")) {
        return $true
    }

    foreach ($pattern in $Patterns) {
        $normalized = Normalize-RelativePackagePath $pattern
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        if ($relative -eq $normalized -or $relative.StartsWith("$normalized/")) {
            return $true
        }

        if ($relative -match (Convert-GlobToRegex $normalized)) {
            return $true
        }
    }

    return $false
}

function Copy-PackageFiles {
    param(
        [string] $Source,
        [string] $Destination,
        [string[]] $Exclude
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $sourceRoot = Resolve-FullPath $Source
    foreach ($entry in Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse) {
        $relative = Resolve-RelativePath $sourceRoot $entry.FullName
        if (Test-ExcludedPath $relative $Exclude) {
            continue
        }

        $target = Join-Path $Destination $relative
        if ($entry.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
        }
        else {
            $parent = Split-Path -Parent $target
            if ($parent) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            Copy-Item -LiteralPath $entry.FullName -Destination $target -Force
        }
    }
}

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCommand) {
    Fail "git was not found on PATH."
}

$Namespace = Normalize-Namespace $Namespace
Assert-TypstIdentifier $Namespace "namespace"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("tpdl-" + [System.Guid]::NewGuid().ToString("N"))
$cloneDir = Join-Path $tempRoot "repo"

try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    if ([string]::IsNullOrWhiteSpace($Ref)) {
        git clone --depth 1 -- $Repository $cloneDir
        if ($LASTEXITCODE -ne 0) {
            Fail "git clone failed."
        }
    }
    else {
        git clone -- $Repository $cloneDir
        if ($LASTEXITCODE -ne 0) {
            Fail "git clone failed."
        }
        git -C $cloneDir checkout $Ref
        if ($LASTEXITCODE -ne 0) {
            Fail "git checkout failed."
        }
    }

    $manifest = Read-PackageManifest $cloneDir
    $packageRoot = Resolve-TypstPackagePath
    $baseDir = Join-Path $packageRoot (Join-Path $Namespace $manifest.Name)
    $destination = Join-Path $baseDir $manifest.Version
    $spec = "@$Namespace/$($manifest.Name):$($manifest.Version)"

    if (Test-Path -LiteralPath $destination) {
        if (-not $Force) {
            Write-Host "Already installed $spec"
            Write-Host $destination
            exit 0
        }
        Remove-Item -LiteralPath $destination -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $baseDir | Out-Null
    $tempInstall = Join-Path $baseDir (".tmp-$($manifest.Version)-$([System.Guid]::NewGuid().ToString("N").Substring(0, 8))")
    if (Test-Path -LiteralPath $tempInstall) {
        Remove-Item -LiteralPath $tempInstall -Recurse -Force
    }

    try {
        Copy-PackageFiles $cloneDir $tempInstall $manifest.Exclude
        [System.IO.Directory]::Move($tempInstall, $destination)
    }
    catch {
        if ((Test-Path -LiteralPath $destination) -and -not $Force) {
            Remove-Item -LiteralPath $tempInstall -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Remove-Item -LiteralPath $tempInstall -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }
    }

    Write-Host "Installed $spec"
    Write-Host $destination
}
finally {
    if (-not $KeepTemp) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif (Test-Path -LiteralPath $tempRoot) {
        Write-Host "Kept temporary directory: $tempRoot"
    }
}
