param(
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\build\reference\espeak-ng'),
    [string]$SonicDirectory = (Join-Path $PSScriptRoot '..\build\reference\espeak-build\arm64-v8a\_deps\sonic-git-src'),
    [string]$CmakeExecutable = 'C:\tools\android-sdk\cmake\3.22.1\bin\cmake.exe'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = [IO.Path]::GetFullPath($SourceDirectory)
$sonicPath = [IO.Path]::GetFullPath($SonicDirectory)
$pins = @(@($sourcePath, 'ba90c8e9f440ad544f674a790bb5f53878b6ffc5'), @($sonicPath, 'fbf75c3d6d846bad3bb3d456cbc5d07d9fd8c104'))
foreach ($pin in $pins) {
    $actual = & git -C $pin[0] rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actual.Trim() -ne $pin[1]) { throw "Source commit must be $($pin[1])." }
}
$wrapper = Join-Path $root 'build\reference\espeak-windows-source'
$output = Join-Path $root 'build\reference\espeak-windows-build'
[IO.Directory]::CreateDirectory($wrapper) | Out-Null
$sourceCmake = $sourcePath.Replace('\','/')
$sonicCmake = $sonicPath.Replace('\','/')
# Single-quoted template preserves CMake variable syntax without PowerShell expansion.
$template = @'
cmake_minimum_required(VERSION 3.14)
project(ScanoraSpeech LANGUAGES C CXX)
set(VOICE_SOURCE "@VOICE@")
set(SONIC_SOURCE "@SONIC@")
add_library(sonic STATIC "${SONIC_SOURCE}/sonic.c")
target_include_directories(sonic PUBLIC "${SONIC_SOURCE}")
set(SONIC_LIB sonic)
set(SONIC_INC "${SONIC_SOURCE}")
set(USE_LIBSONIC ON CACHE BOOL "" FORCE)
set(USE_ASYNC OFF CACHE BOOL "" FORCE)
set(USE_MBROLA OFF CACHE BOOL "" FORCE)
set(USE_LIBPCAUDIO OFF CACHE BOOL "" FORCE)
add_subdirectory("${VOICE_SOURCE}" espeak)
'@
[IO.File]::WriteAllText((Join-Path $wrapper 'CMakeLists.txt'), $template.Replace('@VOICE@',$sourceCmake).Replace('@SONIC@',$sonicCmake))
& $CmakeExecutable -S $wrapper -B $output -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'Speech configuration failed.' }
& $CmakeExecutable --build $output --config Release --target espeak-ng-bin --parallel 4
if ($LASTEXITCODE -ne 0) { throw 'Speech build failed.' }
$exe = Join-Path $output 'espeak\src\Release\espeak-ng.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Speech executable was not produced.' }
Copy-Item -LiteralPath $exe -Destination (Join-Path $root 'windows\espeak-ng\espeak-ng.exe') -Force
Write-Host 'Windows speech rebuilt with Sonic. Update the recorded executable hash before distributing.'
