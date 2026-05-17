#Requires -Version 5.1
#Requires -Modules Microsoft.PowerShell.SecretManagement
Set-StrictMode -Version Latest

$script:Config = $null
$configFile    = Join-Path $PSScriptRoot 'DevControlPlane.config.json'
if (Test-Path $configFile) {
    $script:Config = Get-Content $configFile -Raw | ConvertFrom-Json
}

#region Private helpers

function Write-AuditEntry {
    param([string]$Action, [string]$Target, [string]$Result)
    try {
        $logDir = Join-Path $PSScriptRoot 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        [PSCustomObject]@{
            Timestamp = (Get-Date -Format 'o')
            Action    = $Action
            Target    = $Target
            Result    = $Result
            User      = $env:USERNAME
        } | Export-Csv -Path (Join-Path $logDir 'cleanup-audit.log') -Append -NoTypeInformation -Encoding UTF8
    } catch { }
}

#endregion

#region Get-DevWorkspaceStatus

function Get-DevWorkspaceStatus {
<#
.SYNOPSIS
    Returns a unified status snapshot of the local development workspace.

.DESCRIPTION
    Queries Docker engine health and exited container count, VS Code workspace
    storage size, RStudio artifact presence, and GitHub Actions workflow run
    history for one or more repositories. The GitHub token is retrieved from
    the DevVault SecretStore (falls back to GITHUB_TOKEN env var for CI).
    All results are returned as a single PSCustomObject for programmatic
    consumption — no output is printed.

.PARAMETER Repository
    One or more GitHub repositories in owner/repo format (e.g. owner/repo).
    Defaults to repositories listed in DevControlPlane.config.json, then
    falls back to $env:GITHUB_REPOSITORY if the config is unavailable.

.OUTPUTS
    System.Management.Automation.PSCustomObject

.EXAMPLE
    Get-DevWorkspaceStatus
    Returns status for all repositories configured in DevControlPlane.config.json.

.EXAMPLE
    Get-DevWorkspaceStatus -Repository 'RobertKimutai-DS/Portfolio','RobertKimutai-DS/dairy-management'
    Returns status including Actions runs for two specific repositories.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string[]]$Repository
    )

    # --- Docker ---
    $dockerHealth = 'unavailable'
    $exitedCount  = 0
    try {
        $null = docker info 2>$null
        if ($LASTEXITCODE -eq 0) {
            $dockerHealth = 'running'
            $exitedRaw    = docker ps -a --filter 'status=exited' --format '{{json .}}' 2>$null
            $exitedCount  = ($exitedRaw | Where-Object { $_ -ne '' } | Measure-Object).Count
        }
    } catch { }

    # --- VS Code workspace storage ---
    $vscodeStoragePath = Join-Path $env:APPDATA 'Code\User\WorkspaceStorage'
    $vscodeSizeBytes   = 0
    if (Test-Path $vscodeStoragePath) {
        $vscodeSizeBytes = (
            Get-ChildItem $vscodeStoragePath -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum
        ).Sum
        if ($null -eq $vscodeSizeBytes) { $vscodeSizeBytes = 0 }
    }
    $vscodeSizeMB = [math]::Round($vscodeSizeBytes / 1MB, 2)

    # --- RStudio artifacts ---
    $rHistoryFound = Test-Path (Join-Path $HOME '.Rhistory')
    $rDataFound    = Test-Path (Join-Path $HOME '.RData')

    # --- Resolve repo list ---
    [array]$repoList = if ($Repository) {
        $Repository
    } elseif ($env:GITHUB_REPOSITORY) {
        $env:GITHUB_REPOSITORY
    } elseif ($script:Config -and $script:Config.repositories) {
        $script:Config.repositories
    } else {
        @()
    }

    # --- Retrieve GitHub token (SecretStore primary, env var CI fallback) ---
    $githubToken = $null
    try {
        $githubToken = Get-Secret -Name GitHubToken -Vault DevVault -AsPlainText -ErrorAction Stop
    } catch {
        $githubToken = $env:GITHUB_TOKEN
    }

    # --- GitHub Actions (one result object per repo) ---
    $githubResults = $null
    $githubError   = $null

    if (-not $githubToken) {
        $githubError = 'GitHub token unavailable (SecretStore and GITHUB_TOKEN both unset)'
    } elseif (-not $repoList) {
        $githubError = 'No repository specified. Use -Repository owner/repo or set $env:GITHUB_REPOSITORY'
    } else {
        $headers = @{
            Authorization = "Bearer $githubToken"
            Accept        = 'application/vnd.github+json'
        }

        $githubResults = @(foreach ($repo in $repoList) {
            try {
                $uri  = "https://api.github.com/repos/$repo/actions/runs?per_page=5"
                $runs = @(
                    (Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop).workflow_runs |
                    Select-Object -Property name, status, conclusion, created_at
                )
                [PSCustomObject]@{
                    Repository = $repo
                    Runs       = $runs
                    Error      = $null
                }
            } catch {
                [PSCustomObject]@{
                    Repository = $repo
                    Runs       = $null
                    Error      = $_.Exception.Message
                }
            }
        })
    }

    [PSCustomObject]@{
        Timestamp          = Get-Date -Format 'o'
        Docker             = [PSCustomObject]@{
            EngineHealth     = $dockerHealth
            ExitedContainers = $exitedCount
        }
        VSCode             = [PSCustomObject]@{
            WorkspaceStoragePath   = $vscodeStoragePath
            WorkspaceStorageSizeMB = $vscodeSizeMB
        }
        RStudio            = [PSCustomObject]@{
            RHistoryFound = $rHistoryFound
            RDataFound    = $rDataFound
        }
        GitHubActions      = [array]$githubResults
        GitHubActionsError = $githubError
    }
}

#endregion

#region Optimize-DevWorkspace

function Optimize-DevWorkspace {
<#
.SYNOPSIS
    Prunes Docker artifacts, stale VS Code caches, and RStudio history files.

.DESCRIPTION
    Removes dangling Docker volumes, all exited containers, VS Code workspace
    cache directories older than 7 days, and RStudio .Rhistory/.RData files.
    Supports -WhatIf and -Confirm via SupportsShouldProcess for risk-free dry
    runs. Each destructive action is recorded to an append-only audit CSV at
    logs\cleanup-audit.log relative to the module root.

.EXAMPLE
    Optimize-DevWorkspace -WhatIf
    Shows what would be removed without making any changes.

.EXAMPLE
    Optimize-DevWorkspace -Confirm:$false
    Runs all cleanup steps without interactive confirmation prompts.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param()

    # --- Docker: prune dangling volumes and exited containers ---
    if ($PSCmdlet.ShouldProcess('Docker', 'Prune dangling volumes')) {
        try {
            docker volume prune -f 2>$null | Out-Null
            Write-Verbose 'Docker dangling volumes pruned.'
            Write-AuditEntry -Action 'DockerVolumePrune' -Target 'dangling volumes' -Result 'Success'
        } catch {
            Write-Warning "Docker volume prune failed: $_"
            Write-AuditEntry -Action 'DockerVolumePrune' -Target 'dangling volumes' -Result "Failed: $_"
        }
    }

    if ($PSCmdlet.ShouldProcess('Docker', 'Remove all exited containers')) {
        try {
            $exitedIds = docker ps -a --filter 'status=exited' -q 2>$null
            if ($exitedIds) {
                docker rm $exitedIds 2>$null | Out-Null
                Write-Verbose "Removed $($exitedIds.Count) exited container(s)."
                Write-AuditEntry -Action 'DockerContainerRemove' -Target "$($exitedIds.Count) exited containers" -Result 'Success'
            }
        } catch {
            Write-Warning "Docker container removal failed: $_"
            Write-AuditEntry -Action 'DockerContainerRemove' -Target 'exited containers' -Result "Failed: $_"
        }
    }

    # --- VS Code: clear workspace cache entries older than 7 days ---
    $vscodeStoragePath = Join-Path $env:APPDATA 'Code\User\WorkspaceStorage'
    if (Test-Path $vscodeStoragePath) {
        $cutoff = (Get-Date).AddDays(-7)
        $staleDirs = Get-ChildItem $vscodeStoragePath -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -lt $cutoff }

        foreach ($dir in $staleDirs) {
            if ($PSCmdlet.ShouldProcess($dir.FullName, 'Remove stale VS Code workspace cache')) {
                try {
                    Remove-Item $dir.FullName -Recurse -Force -ErrorAction Stop
                    Write-Verbose "Removed VS Code cache: $($dir.FullName)"
                    Write-AuditEntry -Action 'VSCodeCacheRemove' -Target $dir.FullName -Result 'Success'
                } catch {
                    Write-Warning "Could not remove $($dir.FullName): $_"
                    Write-AuditEntry -Action 'VSCodeCacheRemove' -Target $dir.FullName -Result "Failed: $_"
                }
            }
        }
    }

    # --- RStudio: remove history/data files ---
    $rFiles = @(
        (Join-Path $HOME '.Rhistory'),
        (Join-Path $HOME '.RData')
    )

    foreach ($rFile in $rFiles) {
        if (Test-Path $rFile) {
            if ($PSCmdlet.ShouldProcess($rFile, 'Remove RStudio artifact')) {
                try {
                    Remove-Item $rFile -Force -ErrorAction Stop
                    Write-Verbose "Removed RStudio artifact: $rFile"
                    Write-AuditEntry -Action 'RStudioArtifactRemove' -Target $rFile -Result 'Success'
                } catch {
                    Write-Warning "Could not remove $rFile`: $_"
                    Write-AuditEntry -Action 'RStudioArtifactRemove' -Target $rFile -Result "Failed: $_"
                }
            }
        }
    }
}

#endregion

#region Start-ControlPanel  (stub — full impl lives in Start-ControlPanel.ps1)

function Start-ControlPanel {
<#
.SYNOPSIS
    Starts the DevControlPlane Pode-based REST API control panel server.

.DESCRIPTION
    Launches a multi-threaded Pode HTTP server on the specified port exposing
    three routes: GET /health (unauthenticated liveness probe returning JSON),
    GET /status (full workspace status, requires X-Api-Key header), and
    GET /clean (triggers Optimize-DevWorkspace, requires X-Api-Key header).
    The API key is read from DevControlPlane.config.json. Press Ctrl+C to stop.

.PARAMETER Port
    TCP port to listen on. Must be between 1024 and 65535. Defaults to the
    port configured in DevControlPlane.config.json (8080 if not set).

.EXAMPLE
    Start-ControlPanel
    Starts the server on the port defined in DevControlPlane.config.json.

.EXAMPLE
    Start-ControlPanel -Port 9090
    Starts the server on port 9090, overriding the config file default.
#>
    [CmdletBinding()]
    param(
        [ValidateRange(1024, 65535)]
        [int]$Port = 8080
    )

    $scriptPath = Join-Path $PSScriptRoot 'Start-ControlPanel.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "Start-ControlPanel.ps1 not found at: $scriptPath"
    }

    & $scriptPath -Port $Port
}

#endregion
