param([Parameter(Mandatory)][string]$Stage)
$ErrorActionPreference = 'Stop'
if (!(Test-Path "$Stage/Pairwise.exe")) { throw 'Stage the native executable first.' }
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
if (!(Test-Path $vswhere)) { throw 'Visual Studio Installer/vswhere is required to locate redistributable runtime DLLs.' }
$installation = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$installation) { throw 'Visual Studio 2022 x64 C++ tools are required.' }
$redist = Get-ChildItem "$installation/VC/Redist/MSVC" -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+(\.\d+)?$' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (!$redist) { throw 'MSVC redistributable runtime is missing.' }
$crt = Join-Path $redist.FullName 'x64/Microsoft.VC143.CRT'
if (!(Test-Path "$crt/msvcp140.dll")) { throw 'The x64 MSVC CRT directory is missing.' }
Copy-Item "$crt/*.dll" $Stage -Force
foreach ($name in @('msvcp140.dll','msvcp140_1.dll','msvcp140_2.dll','vcruntime140.dll','vcruntime140_1.dll')) {
    if (!(Test-Path "$Stage/$name")) { throw "Required app-local runtime DLL missing: $name" }
}
