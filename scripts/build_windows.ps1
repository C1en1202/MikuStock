param(
    [string]$Flutter = 'flutter',
    [string]$Python = (Join-Path $PSScriptRoot '..\.venv\Scripts\python.exe')
)

$ErrorActionPreference = 'Stop'
$localFlutter = Join-Path $PSScriptRoot '..\.tools\flutter-local\flutter\bin\flutter.bat'
if (-not $PSBoundParameters.ContainsKey('Flutter') -and (Test-Path -LiteralPath $localFlutter -PathType Leaf)) {
    $Flutter = (Resolve-Path -LiteralPath $localFlutter).Path
}

$flutterCommand = Get-Command $Flutter -CommandType Application -ErrorAction SilentlyContinue
if (-not $flutterCommand) {
    throw "Flutter executable not found: $Flutter. Extract the Windows SDK and pass the path to flutter\bin\flutter.bat with -Flutter."
}
$clientPath = Join-Path $PSScriptRoot '..\client'

& $Python (Join-Path $PSScriptRoot 'bundle_gateway.py')
if ($LASTEXITCODE -ne 0) { throw 'Windows gateway packaging failed.' }

Push-Location $clientPath
try {
    if (-not (Test-Path -LiteralPath 'windows\CMakeLists.txt')) {
        & $flutterCommand.Source create --platforms=windows --project-name mikustock --empty --no-pub .
        if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows runner generation failed.' }
    }

    & $flutterCommand.Source pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed.' }

    & $flutterCommand.Source analyze
    if ($LASTEXITCODE -ne 0) { throw 'Flutter static analysis failed.' }

    & $flutterCommand.Source build windows
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed.' }
}
finally {
    Pop-Location
}
