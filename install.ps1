$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Repo = 'Yimikami/Sunshine'

$headers = @{ 'User-Agent' = 'Sunshine-Installer'; Accept = 'application/vnd.github+json' }
$release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/latest"

$asset = $release.assets | Where-Object { $_.name -match '_x64-setup\.exe$' } | Select-Object -First 1
if (-not $asset) {
    $asset = $release.assets | Where-Object { $_.name -match '\.exe$' } | Select-Object -First 1
}
if (-not $asset) { throw "No installer asset on release '$($release.tag_name)'." }

$tmp = Join-Path $env:TEMP $asset.name
Write-Host ">> Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)" -ForegroundColor Cyan
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing

Write-Host ">> Installing (UAC prompt may appear)" -ForegroundColor Cyan
$proc = Start-Process -FilePath $tmp -ArgumentList '/S' -Wait -PassThru
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -ne 0) {
    Write-Warning "Installer exited with code $($proc.ExitCode)."
    return
}
Write-Host "Sunshine $($release.tag_name) installed." -ForegroundColor Green
