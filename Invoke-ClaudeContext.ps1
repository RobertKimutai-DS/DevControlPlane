#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Get-Location) '.claude-context.md'),
    [ValidatePattern('^[^/]+/[^/]+$')]
    [string[]]$Repository
)

Set-StrictMode -Version Latest

$moduleManifest = Join-Path $PSScriptRoot 'DevControlPlane.psd1'
if (-not (Get-Module -Name DevControlPlane)) {
    Import-Module $moduleManifest -Force
}

# --- Workspace status ---
$statusParams = @{}
if ($Repository -and $Repository.Count -gt 0) { $statusParams['Repository'] = $Repository }
$status = Get-DevWorkspaceStatus @statusParams

# --- Git status (porcelain) ---
$gitStatus     = $null
$gitBranch     = $null
$gitRemote     = $null
$gitStatusError = $null

try {
    $gitOutput = git status --porcelain 2>&1
    if ($LASTEXITCODE -eq 0) {
        $gitStatus = if ($gitOutput) { $gitOutput -join "`n" } else { '(clean — no uncommitted changes)' }
        $gitBranch = git rev-parse --abbrev-ref HEAD 2>$null
        $gitRemote = git remote get-url origin 2>$null
    } else {
        $gitStatusError = 'Not inside a git repository.'
    }
} catch {
    $gitStatusError = $_.Exception.Message
} finally {
    $global:LASTEXITCODE = 0
}

# --- GitHub Actions section ---
function Format-ActionsSection {
    param($githubActions, $githubError)
    if ($githubError) { return "> **Notice:** $githubError" }
    if (-not $githubActions) { return '_No data available._' }

    $sections = foreach ($repoResult in $githubActions) {
        $header = "### ``$($repoResult.Repository)``"
        if ($repoResult.Error) {
            "$header`n> **Error:** $($repoResult.Error)"
        } elseif (-not $repoResult.Runs) {
            "$header`n_No workflow runs found._"
        } else {
            $lines = @('| Workflow | Status | Conclusion | Created |', '|---|---|---|---|')
            foreach ($r in $repoResult.Runs) {
                $lines += "| $($r.name) | $($r.status) | $($r.conclusion) | $($r.created_at) |"
            }
            "$header`n" + ($lines -join "`n")
        }
    }
    $sections -join "`n`n"
}

# --- Render markdown ---
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'

$md = @"
# Claude Dev Context
_Generated: ${timestamp}_

---

## Docker

| Field | Value |
|---|---|
| Engine Health | $($status.Docker.EngineHealth) |
| Exited / Zombie Containers | $($status.Docker.ExitedContainers) |

---

## VS Code

| Field | Value |
|---|---|
| Workspace Storage Path | ``$($status.VSCode.WorkspaceStoragePath)`` |
| Workspace Storage Size | $($status.VSCode.WorkspaceStorageSizeMB) MB |

---

## RStudio Artifacts

| File | Present |
|---|---|
| ``~/.Rhistory`` | $($status.RStudio.RHistoryFound) |
| ``~/.RData`` | $($status.RStudio.RDataFound) |

---

## GitHub Actions (last 5 runs per repo)

$(Format-ActionsSection $status.GitHubActions $status.GitHubActionsError)

---

## Git Repository State

$(if ($gitStatusError) {
    "> **Notice:** $gitStatusError"
} else {
@"
| Field | Value |
|---|---|
| Branch | ``$gitBranch`` |
| Remote (origin) | $gitRemote |

**Uncommitted changes:**

``````
$gitStatus
``````
"@
})

---

## Recommendations

$(if ($status.Docker.ExitedContainers -gt 0) {
    "- **Docker:** $($status.Docker.ExitedContainers) exited container(s) detected. Run ``Optimize-DevWorkspace`` or ``dclean``."
})
$(if ($status.VSCode.WorkspaceStorageSizeMB -gt 500) {
    "- **VS Code:** Workspace storage is $($status.VSCode.WorkspaceStorageSizeMB) MB. Consider running ``dclean`` to prune stale cache entries."
})
$(if ($status.RStudio.RHistoryFound -or $status.RStudio.RDataFound) {
    "- **RStudio:** History/Data artifacts present. Run ``dclean`` to remove them."
})
"@

Set-Content -Path $OutputPath -Value $md -Encoding UTF8 -Force
Write-Host "Claude context written to: $OutputPath" -ForegroundColor Green
