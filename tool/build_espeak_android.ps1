param(
    [string]$SourceDirectory = (Join-Path $PSScriptRoot '..\build\reference\espeak-ng'),
    [string]$NdkDirectory = 'C:\tools\android-sdk\ndk\28.2.13676358',
    [string]$CmakeExecutable = 'C:\tools\android-sdk\cmake\3.22.1\bin\cmake.exe'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourcePath = [IO.Path]::GetFullPath($SourceDirectory)
$commit = 'ba90c8e9f440ad544f674a790bb5f53878b6ffc5'
$actual = & git -C $sourcePath rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actual.Trim() -ne $commit) { throw "Use the pinned eSpeak source commit $commit. See tool/espeak_android_build.json." }
$toolchain = Join-Path $NdkDirectory 'build\cmake\android.toolchain.cmake'
$ninja = Join-Path (Split-Path $CmakeExecutable) 'ninja.exe'
$strip = Join-Path $NdkDirectory 'toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe'
foreach ($abi in @('arm64-v8a','armeabi-v7a','x86','x86_64')) {
    $output = Join-Path $root "build\reference\espeak-build\$abi"
    & $CmakeExecutable -S (Join-Path $sourcePath 'android\jni') -B $output -G Ninja "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_TOOLCHAIN_FILE=$toolchain" "-DANDROID_ABI=$abi" -DANDROID_PLATFORM=android-21 -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384' -DUSE_ASYNC=OFF -DUSE_MBROLA=OFF -DUSE_LIBSONIC=ON -DUSE_LIBPCAUDIO=OFF -DCMAKE_BUILD_TYPE=Release
    if ($LASTEXITCODE -ne 0) { throw "Configuration failed for $abi" }
    & $CmakeExecutable --build $output --target ttsespeak --parallel 4
    if ($LASTEXITCODE -ne 0) { throw "Build failed for $abi" }
    $library = Join-Path $output 'libttsespeak.so'
    & $strip --strip-unneeded $library
    if ($LASTEXITCODE -ne 0) { throw "Strip failed for $abi" }
    $destination = Join-Path $root "android\app\src\main\jniLibs\$abi"
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    Copy-Item -LiteralPath $library -Destination (Join-Path $destination 'libttsespeak.so') -Force
}
Write-Host 'Native speech libraries rebuilt. Update and verify the native hashes before distributing a new release.'
