# Builds the Windows Grabber and Sender from this package and packs the beta: the Windows
# counterpart of build.sh. Run it from PowerShell on a PC with the Swift toolchain:
#
#   .\build-windows.ps1                  release build, engine check, package folder
#   .\build-windows.ps1 -Zip             the same, plus a .zip beside the folder
#   .\build-windows.ps1 -DebugBuild      debug build only (fast; nothing packaged)
#   .\build-windows.ps1 -NoPackage       release build and engine check, nothing packaged
#   .\build-windows.ps1 -Force           replace a package of the same version
#
# The build goes to -Scratch (by default %LOCALAPPDATA%\nag-build), outside this folder: this folder is synced, and a
# build inside it would sync gigabytes and lock files. Only the finished package is written to the
# synced folder: by default to nags-windows-beta beside this project (one level up), so it reaches
# the Mac and can be zipped there. Pass -Out to put it somewhere else.
# The version is WindowsGrabber.version (Sources/Windows/GrabberCore/WindowsGrabber.swift); the
# package folder is NAGS-Windows-<version>. What goes in beside the programs is in
# Sources/Windows/Package: README.txt (edit it for each release) and Licences\.
#
# A release build records no paths from this PC: no debug info, no PDB, and the source, build and
# toolchain folders mapped to short names. The package is scanned for this PC's user name,
# computer name and folders, and each program is run with only System32 on the PATH, so a
# missing DLL shows up here rather than on someone else's PC. Nothing goes on the network.
param(
  [switch]$DebugBuild,
  [switch]$NoPackage,
  [switch]$Force,
  [switch]$Zip,
  [string]$Scratch = "$env:LOCALAPPDATA\nag-build",
  [string]$Out = ""
)
# Not "Stop": Windows PowerShell turns a native program's stderr into errors, and swift writes
# its progress there. Failures are caught by checking output and exit codes instead.
$ErrorActionPreference = "Continue"
$src = $PSScriptRoot
if (-not $Out) { $Out = Join-Path (Split-Path $src) "nags-windows-beta" }
$started = Get-Date

function Fail([string]$why) { Write-Host "FAILED: $why" -ForegroundColor Red; exit 1 }
function Step([string]$what) { Write-Host "==> $what" -ForegroundColor Cyan }

$full = [IO.Path]::GetFullPath($Scratch).TrimEnd('\')
if ($full.StartsWith($src.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
  Fail "-Scratch is inside the source folder ($src). Build somewhere that is not synced."
}
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) { Fail "swift is not on the PATH. Install the Swift toolchain." }

# The version, from the Grabber; the Sender's own string should match it.
$grabberSwift = Get-Content -Raw "$src\Sources\Windows\GrabberCore\WindowsGrabber.swift"
if ($grabberSwift -notmatch 'static let version = "([^"]+)"') { Fail "no version in WindowsGrabber.swift" }
$version = $Matches[1]
$senderSwift = Get-Content -Raw "$src\Sources\Windows\AppUI\SenderApp.swift"
if ($senderSwift -match 'let senderVersion = "([^"]+)"' -and $Matches[1] -ne $version) {
  Write-Host "warning: the Sender says $($Matches[1]), the Grabber $version (SenderApp.swift, senderVersion)" -ForegroundColor Yellow
}
Write-Host "Network Audio Grabber & Sender for Windows $version"

# The toolchain's own folders, for the prefix maps and the runtime DLLs.
$info = swift -print-target-info | ConvertFrom-Json
$runtimeDirs = @($info.paths.runtimeLibraryPaths)
$swiftExe = (Get-Command swift).Source
$cut = $swiftExe.IndexOf("\Toolchains\", [StringComparison]::OrdinalIgnoreCase)
$toolchainRoot = if ($cut -gt 0) { $swiftExe.Substring(0, $cut) } else { Split-Path (Split-Path (Split-Path $swiftExe)) }   # ...\Programs\Swift

$products = @("nag-grabber", "nag-grab", "nag-sender", "nag-send", "nag-vst3-scan", "NetworkAudioEngineCheck")
if ($DebugBuild) {
  $flags = @("--scratch-path", $Scratch)
} else {
  $flags = @(
    "-c", "release", "--scratch-path", $Scratch,
    "-debug-info-format", "none",
    "-Xswiftc", "-file-prefix-map", "-Xswiftc", "$toolchainRoot=swift",
    "-Xswiftc", "-file-prefix-map", "-Xswiftc", "$src=.",
    "-Xswiftc", "-file-prefix-map", "-Xswiftc", "$Scratch=build",
    "-Xcc", "-g0", "-Xcc", "-ffile-prefix-map=$src=.", "-Xcc", "-ffile-prefix-map=$Scratch=build",
    "-Xcxx", "-g0", "-Xcxx", "-ffile-prefix-map=$src=.", "-Xcxx", "-ffile-prefix-map=$Scratch=build",
    "-Xlinker", "/DEBUG:NONE"
  )
}

Push-Location $src
try {
  foreach ($product in $products) {
    Step "swift build $(if ($DebugBuild) { 'debug' } else { 'release' }) $product"
    $log = & swift build @flags --product $product 2>&1 | ForEach-Object { "$_" }
    $errors = $log | Where-Object { $_ -match ': error:' } | Select-Object -Unique
    if ($errors -or -not ($log | Where-Object { $_ -match 'Build complete' })) {
      $errors | Select-Object -First 30 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
      if (-not $errors) { $log | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" } }
      Fail "$product did not build"
    }
  }
  $bin = (& swift build @flags --show-bin-path 2>$null | Select-Object -Last 1).Trim()
} finally { Pop-Location }
Write-Host "Built into $bin"

# The engine's own check: the same tests as Tools/check-engine.sh on the Mac.
Step "engine check"
$check = & "$bin\NetworkAudioEngineCheck.exe" 2>&1 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { $check | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" }; Fail "the engine check failed" }
Write-Host "  $($check | Select-Object -Last 1)"

if ($DebugBuild -or $NoPackage) {
  Write-Host "Done in $([int]((Get-Date) - $started).TotalSeconds) s. Programs: $bin" -ForegroundColor Green
  exit 0
}

# The package: the programs, the Swift runtime they load, the guide, the README and the licences.
$name = "NAGS-Windows-$version"
$pkg = Join-Path $Out $name
$zipFile = "$pkg.zip"
if ((Test-Path $pkg) -or (Test-Path $zipFile)) {
  if (-not $Force) { Fail "$pkg already exists. Raise the version in WindowsGrabber.swift, or pass -Force to replace it." }
  Remove-Item -Recurse -Force -LiteralPath $pkg -ErrorAction SilentlyContinue
  Remove-Item -Force -LiteralPath $zipFile -ErrorAction SilentlyContinue
}
Step "package $pkg"
New-Item -ItemType Directory -Force $pkg | Out-Null
foreach ($exe in @("nag-grabber", "nag-grab", "nag-sender", "nag-send", "nag-vst3-scan")) {
  Copy-Item "$bin\$exe.exe" $pkg
}
$dlls = @("BlocksRuntime", "dispatch", "Foundation", "FoundationEssentials", "FoundationInternationalization",
          "_FoundationICU", "swiftCore", "swiftCRT", "swiftDispatch", "swiftObservation", "swiftSynchronization",
          "swiftWinSDK", "swift_Concurrency", "swift_RegexParser", "swift_StringProcessing")
foreach ($dll in $dlls) {
  $from = $runtimeDirs | ForEach-Object { Join-Path $_ "$dll.dll" } | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $from) { Fail "$dll.dll is not in the toolchain's runtime folders" }
  Copy-Item $from $pkg
}
Copy-Item "$src\docs\quick-start\QUICK-START.html" $pkg
Copy-Item "$src\Sources\Windows\Package\README.txt" $pkg
Copy-Item -Recurse "$src\Sources\Windows\Package\Licences" $pkg
$readmeTitle = Get-Content "$pkg\README.txt" -TotalCount 1
$plain = $version -replace '-beta', ' beta '
if ($readmeTitle -notlike "*$plain*") {
  Write-Host "warning: README.txt's title says '$readmeTitle', not $plain - update Sources/Windows/Package/README.txt" -ForegroundColor Yellow
}

# Nothing from this PC: its user and computer names, and the source, build and toolchain folders,
# in ASCII or UTF-16, in any file of the package.
Step "scan for this PC's names and folders"
$needles = @($env:USERNAME, $env:COMPUTERNAME, $src, $Scratch, $toolchainRoot, $env:USERPROFILE) |
  Where-Object { $_ -and $_.Length -ge 4 } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique
$latin1 = [Text.Encoding]::GetEncoding(28591)
$found = @()
foreach ($file in Get-ChildItem -Recurse -File $pkg) {
  $text = $latin1.GetString([IO.File]::ReadAllBytes($file.FullName)).ToLowerInvariant()
  foreach ($n in $needles) {
    $wide = -join ($n.ToCharArray() | ForEach-Object { "$_`0" })
    if ($text.Contains($n) -or $text.Contains($wide)) { $found += "$($file.Name): $n" }
  }
}
if ($found) { $found | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }; Fail "the package names this PC" }
Write-Host "  clean"

# Each program on its own, with only System32 on the PATH: a DLL left out fails here.
Step "run each program with only System32 on the PATH"
$savedPath = $env:PATH
$env:PATH = "$env:SystemRoot\System32"
try {
  foreach ($exe in @("nag-grabber", "nag-grab", "nag-sender", "nag-send")) {
    $p = Start-Process "$pkg\$exe.exe" -ArgumentList "--help" -WorkingDirectory $pkg -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput "$Scratch\help-$exe.txt"
    if ($p.ExitCode -ne 0) { Fail "$exe --help exited with $($p.ExitCode) (a missing DLL is -1073741515)" }
    Write-Host "  $exe ok"
  }
} finally { $env:PATH = $savedPath }

if (-not $Zip) {
  Write-Host "Done in $([int]((Get-Date) - $started).TotalSeconds) s: $pkg" -ForegroundColor Green
  exit 0
}
Step "zip $zipFile"
Compress-Archive -Path $pkg -DestinationPath $zipFile -CompressionLevel Optimal
$mb = [math]::Round((Get-Item $zipFile).Length / 1MB, 1)
Write-Host "Done in $([int]((Get-Date) - $started).TotalSeconds) s: $zipFile ($mb MB)" -ForegroundColor Green
