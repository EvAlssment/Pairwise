param(
    [Parameter(Mandatory)][string]$Stage,
    [Parameter(Mandatory)][string]$Output,
    [string]$Version = '0.1.0.0',
    [string]$Publisher = 'CN=Pairwise Preview',
    [string]$CertificateThumbprint,
    [string]$UpdateBaseUrl
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw 'Use a four-part numeric MSIX version.' }
if (!(Test-Path "$Stage/Pairwise.exe")) { throw 'Missing staged executable.' }
foreach ($name in @('msvcp140.dll','msvcp140_1.dll','msvcp140_2.dll','vcruntime140.dll','vcruntime140_1.dll','livekit.dll','livekit_ffi.dll','Qt6Core.dll','platforms/qwindows.dll','multimedia/ffmpegmediaplugin.dll')) {
    if (!(Test-Path "$Stage/$name")) { throw "Required runtime file missing: $name. Run windeployqt and stage-runtime.ps1 before packaging." }
}
foreach ($name in @('README.md','sources.json','LiveKit-Cpp-LICENSE.txt','LiveKit-Rust-LICENSE.txt','Qt-LGPL-3.0.txt','Qt-GPL-3.0.txt','FFmpeg-LGPL-2.1.txt','Qt-FFmpeg-attribution.json')) {
    if (!(Test-Path "$Stage/third-party-notices/$name")) { throw "Required native component notice missing: $name" }
}
$noticeSources = Get-Content "$Stage/third-party-notices/sources.json" -Raw | ConvertFrom-Json
foreach ($notice in $noticeSources) {
    $hash = (Get-FileHash "$Stage/third-party-notices/$($notice.file)" -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $notice.sha256) { throw "Upstream notice hash mismatch: $($notice.file). Preserve the original bytes and .gitattributes rules." }
}
New-Item -ItemType Directory -Force $Output | Out-Null
$Stage = (Resolve-Path $Stage).Path
$Output = (Resolve-Path $Output).Path
$sdk = Get-ChildItem "${env:ProgramFiles(x86)}/Windows Kits/10/bin/*/x64/makeappx.exe" | Sort-Object FullName -Descending | Select-Object -First 1
if (!$sdk) { throw 'Install the Windows SDK packaging tools.' }
$tools = Split-Path $sdk.FullName
$assets = New-Item -ItemType Directory -Force "$Stage/Assets"
Add-Type -AssemblyName System.Drawing
foreach ($item in @(@('StoreLogo',50),@('Square44x44Logo',44),@('Square150x150Logo',150))) {
    $size = [int]$item[1]
    $bitmap = New-Object System.Drawing.Bitmap($size,$size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(24,35,61))
    $font = New-Object System.Drawing.Font('Segoe UI',($size*0.52),[System.Drawing.FontStyle]::Bold,[System.Drawing.GraphicsUnit]::Pixel)
    $graphics.DrawString('P',$font,[System.Drawing.Brushes]::White,($size*0.22),($size*0.10))
    $bitmap.Save("$assets/$($item[0]).png",[System.Drawing.Imaging.ImageFormat]::Png)
    $font.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
$escapedPublisher = [System.Security.SecurityElement]::Escape($Publisher)
$manifest = (Get-Content "$PSScriptRoot/AppxManifest.xml.in" -Raw).Replace('@PUBLISHER@',$escapedPublisher).Replace('@VERSION@',$Version)
Set-Content "$Stage/AppxManifest.xml" $manifest -Encoding utf8
$package = "$Output/Pairwise-$Version-x64.msix"
& "$tools/makeappx.exe" pack /d $Stage /p $package /o
if ($LASTEXITCODE) { throw 'MSIX validation/packaging failed.' }
if ($CertificateThumbprint) {
    # Signing uses a certificate already installed in the Windows user store;
    # no private key or password is accepted as an argument or written to disk.
    # DigiCert's documented RFC 3161 endpoint; SignTool on the supported SDK
    # rejects the HTTPS URL. The returned timestamp is cryptographically verified.
    & "$tools/signtool.exe" sign /sha1 $CertificateThumbprint /fd SHA256 /tr 'http://timestamp.digicert.com' /td SHA256 $package
    if ($LASTEXITCODE) { throw 'MSIX signing failed.' }
    & "$tools/signtool.exe" verify /pa /v /tw $package
    if ($LASTEXITCODE) { throw 'MSIX signature verification failed.' }
} elseif ($UpdateBaseUrl) { throw 'An update feed requires a signed MSIX.' }
if ($UpdateBaseUrl) {
    $uri = [Uri]$UpdateBaseUrl
    if (!$uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Use a public HTTPS base URL for updates.' }
    $base = [System.Security.SecurityElement]::Escape($UpdateBaseUrl.TrimEnd('/'))
    $appInstaller = @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2018" Version="$Version" Uri="$base/Pairwise.appinstaller">
 <MainPackage Name="Pairwise.Desktop" Publisher="$escapedPublisher" Version="$Version" ProcessorArchitecture="x64" Uri="$base/Pairwise-$Version-x64.msix" />
 <UpdateSettings><OnLaunch HoursBetweenUpdateChecks="4" ShowPrompt="true" UpdateBlocksActivation="false" /></UpdateSettings>
</AppInstaller>
"@
    Set-Content "$Output/Pairwise.appinstaller" $appInstaller -Encoding utf8
}
Get-FileHash $package -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $([IO.Path]::GetFileName($_.Path))" } | Set-Content "$package.sha256"
