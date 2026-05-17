#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Remove
)

Set-StrictMode -Version Latest

$profilePath = $PROFILE.CurrentUserAllHosts

# Ensure the profile file and its parent directory exist
if (-not (Test-Path (Split-Path $profilePath))) {
    New-Item -ItemType Directory -Path (Split-Path $profilePath) -Force | Out-Null
}
if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

$sentinel  = '# --- DevControlPlane BEGIN ---'
$sentinelE = '# --- DevControlPlane END ---'

$block = @"

$sentinel
# DevControlPlane — auto-injected by ProfileConfig.ps1
Import-Module DevControlPlane -Force -ErrorAction SilentlyContinue
Set-Alias -Name dstatus  -Value Get-DevWorkspaceStatus  -Scope Global -Force -ErrorAction SilentlyContinue
Set-Alias -Name dclean   -Value Optimize-DevWorkspace   -Scope Global -Force -ErrorAction SilentlyContinue
Set-Alias -Name wfail    -Value Get-WorkflowFailures    -Scope Global -Force -ErrorAction SilentlyContinue
Set-Alias -Name wrepair  -Value Repair-FailedWorkflow   -Scope Global -Force -ErrorAction SilentlyContinue
function global:cctx {
    `$script = Join-Path (Split-Path (Get-Module DevControlPlane).Path) 'Invoke-ClaudeContext.ps1'
    & `$script @args
}
$sentinelE

"@

$currentContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if ($null -eq $currentContent) { $currentContent = '' }

if ($Remove) {
    $pattern        = "(?s)\r?\n?$([regex]::Escape($sentinel)).*?$([regex]::Escape($sentinelE))\r?\n?"
    $updatedContent = [regex]::Replace($currentContent, $pattern, '')
    if ($PSCmdlet.ShouldProcess($profilePath, 'Remove DevControlPlane profile block')) {
        Set-Content -Path $profilePath -Value $updatedContent -Encoding UTF8 -NoNewline
        Write-Host "DevControlPlane profile block removed from: $profilePath" -ForegroundColor Yellow
    }
    return
}

if ($currentContent -match [regex]::Escape($sentinel)) {
    Write-Host "DevControlPlane profile block already present in: $profilePath" -ForegroundColor DarkCyan
    return
}

if ($PSCmdlet.ShouldProcess($profilePath, 'Inject DevControlPlane profile block')) {
    Add-Content -Path $profilePath -Value $block -Encoding UTF8
    Write-Host "DevControlPlane profile block injected into: $profilePath" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Aliases registered (active after shell restart):" -ForegroundColor Cyan
    Write-Host "    dstatus  -> Get-DevWorkspaceStatus" -ForegroundColor DarkCyan
    Write-Host "    dclean   -> Optimize-DevWorkspace"  -ForegroundColor DarkCyan
    Write-Host "    cctx     -> Invoke-ClaudeContext.ps1" -ForegroundColor DarkCyan
}
