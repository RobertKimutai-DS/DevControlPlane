#Requires -Version 7.0
#Requires -Modules Pode
[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8080
)

Set-StrictMode -Version Latest

# Load module by name (PSModulePath) or fall back to local path
if (-not (Get-Module -Name DevControlPlane)) {
    $localManifest = Join-Path $PSScriptRoot 'DevControlPlane.psd1'
    if (Test-Path $localManifest) {
        Import-Module $localManifest -Force -ErrorAction Stop
    } else {
        Import-Module DevControlPlane -Force -ErrorAction Stop
    }
}

# Read config — re-resolved inside server block via PodeState
$configPath = Join-Path $PSScriptRoot 'DevControlPlane.config.json'
$config     = Get-Content $configPath -Raw | ConvertFrom-Json
$listenPort = if ($Port -ne 8080) { $Port } else { [int]$config.port }
$apiKey     = $config.apiKey

Import-Module Pode -Force

Start-PodeServer -Threads 2 {

    Add-PodeEndpoint -Address localhost -Port $listenPort -Protocol Http

    # Share apiKey via Pode state so route/middleware scriptblocks can access it
    Set-PodeState -Name 'ApiKey'        -Value $apiKey
    Set-PodeState -Name 'ModulePath'    -Value (Get-Module DevControlPlane).Path
    Set-PodeState -Name 'LocalRepoPath' -Value $config.localRepoPath

    Write-PodeHost "DevControlPlane REST API (Pode) on http://localhost:$listenPort" -ForegroundColor Cyan
    Write-PodeHost "  GET /health  — unauthenticated liveness probe" -ForegroundColor DarkCyan
    Write-PodeHost "  GET /status  — workspace status  (X-Api-Key required)" -ForegroundColor DarkCyan
    Write-PodeHost "  GET /clean   — run optimizer     (X-Api-Key required)" -ForegroundColor DarkCyan
    Write-PodeHost "Press Ctrl+C to stop." -ForegroundColor Yellow

    # --- Middleware: API key auth (skip /health) ---
    Add-PodeMiddleware -Name 'ApiKeyAuth' -ScriptBlock {
        if ($WebEvent.Path -eq '/health') { return $true }
        $expected = Get-PodeState -Name 'ApiKey'
        $provided = $WebEvent.Request.Headers['X-Api-Key']
        if ($provided -ne $expected) {
            Set-PodeResponseStatus -Code 401
            Write-PodeJsonResponse -Value @{ error = 'Unauthorized: missing or invalid X-Api-Key header' }
            return $false
        }
        return $true
    }

    # GET /health — unauthenticated liveness probe
    Add-PodeRoute -Method Get -Path '/health' -ScriptBlock {
        Write-PodeJsonResponse -Value @{
            status    = 'ok'
            timestamp = (Get-Date -Format 'o')
        }
    }

    # GET /status — full workspace status as JSON
    Add-PodeRoute -Method Get -Path '/status' -ScriptBlock {
        try {
            $modPath = Get-PodeState -Name 'ModulePath'
            Import-Module (Split-Path $modPath) -Force -ErrorAction SilentlyContinue
            $status = Get-DevWorkspaceStatus
            Write-PodeJsonResponse -Value ($status | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = $_.Exception.Message }
        }
    }

    # GET /clean — trigger workspace optimization
    Add-PodeRoute -Method Get -Path '/clean' -ScriptBlock {
        try {
            $modPath = Get-PodeState -Name 'ModulePath'
            Import-Module (Split-Path $modPath) -Force -ErrorAction SilentlyContinue
            Optimize-DevWorkspace -Confirm:$false
            Write-PodeJsonResponse -Value @{ result = 'Workspace optimization complete' }
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = $_.Exception.Message }
        }
    }

    # GET /failures — list failed workflow runs across all configured repos
    Add-PodeRoute -Method Get -Path '/failures' -ScriptBlock {
        try {
            $modPath = Get-PodeState -Name 'ModulePath'
            Import-Module (Split-Path $modPath) -Force -ErrorAction SilentlyContinue
            $failures = Get-WorkflowFailures
            $summary  = $failures | Select-Object Repository, WorkflowName, Branch, CommitSha,
                                                   CreatedAt, JobName, FailedSteps,
                                                   LogExcerpt, HtmlUrl,
                                                   @{n='KnownPattern';e={$_.KnownPattern.PatternName}}
            Write-PodeJsonResponse -Value ($summary | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = $_.Exception.Message }
        }
    }

    # POST /repair — repair a specific run (body: { repository, runId, repoPath, autoCommit })
    Add-PodeRoute -Method Post -Path '/repair' -ScriptBlock {
        try {
            $modPath  = Get-PodeState -Name 'ModulePath'
            Import-Module (Split-Path $modPath) -Force -ErrorAction SilentlyContinue
            $body     = $WebEvent.Data
            $repo     = $body.repository
            $repoPath = if ($body.repoPath) { $body.repoPath } else { (Get-PodeState -Name 'LocalRepoPath') }

            $failures = Get-WorkflowFailures -Repository $repo
            if (-not $failures) {
                Write-PodeJsonResponse -Value @{ result = 'No failures found for this repository' }
                return
            }

            $results = $failures | Repair-FailedWorkflow -RepoPath $repoPath -Confirm:$false
            Write-PodeJsonResponse -Value ($results | ConvertTo-Json -Depth 4 | ConvertFrom-Json)
        } catch {
            Set-PodeResponseStatus -Code 500
            Write-PodeJsonResponse -Value @{ error = $_.Exception.Message }
        }
    }
}
