#Requires -Version 5.1
#Requires -Modules Microsoft.PowerShell.SecretManagement
Set-StrictMode -Version Latest

$script:Config = $null
$configFile    = Join-Path $PSScriptRoot 'DevControlPlane.config.json'
if (Test-Path $configFile) {
    $script:Config = Get-Content $configFile -Raw | ConvertFrom-Json
}

#region Private helpers

function Get-GitHubToken {
    $token = $null
    try { $token = Get-Secret -Name GitHubToken -Vault DevVault -AsPlainText -ErrorAction Stop } catch { }
    if (-not $token) { $token = $env:GITHUB_TOKEN }
    $token
}

function Get-WorkflowJobLogs {
    param([string]$Repo, [string]$JobId, [string]$Token)
    try {
        $headers  = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json' }
        $logText  = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/actions/jobs/$JobId/logs" `
                        -Headers $headers -Method Get -ErrorAction Stop
        return $logText
    } catch {
        return "Log unavailable: $_"
    }
}

function Get-PatternFix {
    param([string]$LogText)

    $patterns = @(
        @{
            Name        = 'HardcodedDrivePath'
            Regex       = "DriveNotFoundException.*drive with the name '([A-Z])'"
            Diagnosis   = 'Absolute drive-letter path used in a script — fails on any runner that lacks that drive.'
            Instruction = 'Replace all hardcoded drive-letter paths (e.g. E:\, C:\Users\...) with $PSScriptRoot-relative paths using Join-Path $PSScriptRoot.'
        }
        @{
            Name        = 'ModuleNotFound'
            Regex       = "ModuleNotFoundError|module '(.+?)' was not loaded because no valid module|Could not load the module named '(.+?)'"
            Diagnosis   = 'A required PowerShell module is missing on the runner.'
            Instruction = 'Add an Install-Module step to the workflow YAML before the step that uses the module.'
        }
        @{
            Name        = 'CommandNotFound'
            Regex       = "The term '(.+?)' is not recognized as a name of a cmdlet"
            Diagnosis   = 'A command or function is called before its module is imported.'
            Instruction = 'Ensure the module that provides the missing command is imported before it is called.'
        }
        @{
            Name        = 'FileNotFound'
            Regex       = "Cannot find path '(.+?)'|cannot access '(.+?)'|ItemNotFoundException"
            Diagnosis   = 'A script references a file path that does not exist on the runner.'
            Instruction = 'Verify the file exists in the repo and the path is correct relative to the working directory.'
        }
        @{
            Name        = 'SecretMissing'
            Regex       = "secret.*not set|GITHUB_TOKEN.*not set|A valid password is required"
            Diagnosis   = 'A required secret or environment variable is not configured on the runner.'
            Instruction = 'Add the secret in repo Settings > Secrets and reference it in the workflow env block.'
        }
    )

    foreach ($p in $patterns) {
        if ($LogText -match $p.Regex) {
            return [PSCustomObject]@{
                PatternName = $p.Name
                Diagnosis   = $p.Diagnosis
                Instruction = $p.Instruction
                Matched     = $Matches[0]
            }
        }
    }
    return $null
}

function Invoke-ClaudeRepair {
    param([string]$LogText, [string]$RepoPath, [string]$FailedFile)

    # Uses the active Claude Code CLI session -- no API key required
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        throw 'Claude Code CLI (claude) not found in PATH. Install from https://claude.ai/code and log in.'
    }

    $fileContext = ''
    if ($FailedFile -and $RepoPath) {
        $localFile = Join-Path $RepoPath $FailedFile
        if (Test-Path $localFile) {
            $fileContext = "`n`nFILE CONTENT ($FailedFile):`n" + (Get-Content $localFile -Raw)
        }
    }

    $prompt = "Analyze this GitHub Actions failure and return a JSON repair plan.`n`nFAILURE LOG:`n$LogText$fileContext`n`nReturn ONLY a raw JSON object, no markdown fences, no text outside the JSON:`n{`"diagnosis`":`"one sentence root cause`",`"severity`":`"low|medium|high`",`"fixes`":[{`"file`":`"relative/path`",`"description`":`"what changes`",`"search`":`"exact string to find`",`"replace`":`"replacement`"}],`"commit_message`":`"fix: description`"}"

    $rawResponse = ($prompt | & claude --print 2>&1) -join "`n"

    if ($rawResponse -match '(?s)\{.*\}') {
        return ($Matches[0] | ConvertFrom-Json)
    }
    throw "Could not parse JSON from Claude Code response.`nRaw: $rawResponse"
}

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

#region Get-WorkflowFailures

function Get-WorkflowFailures {
<#
.SYNOPSIS
    Returns recent failed GitHub Actions runs across configured repositories.

.DESCRIPTION
    Queries the GitHub Actions API for failed workflow runs in each repository.
    For each failure it fetches the failed job details and a truncated log
    excerpt, returning a structured object ready for piping into
    Repair-FailedWorkflow.

.PARAMETER Repository
    One or more repositories in owner/repo format. Defaults to the list in
    DevControlPlane.config.json.

.PARAMETER MaxRuns
    Maximum number of recent runs to inspect per repository. Default: 5.

.EXAMPLE
    Get-WorkflowFailures
    Returns failures across all configured repositories.

.EXAMPLE
    Get-WorkflowFailures -Repository 'RobertKimutai-DS/DevControlPlane'
    Returns failures for a single repository.

.EXAMPLE
    Get-WorkflowFailures | Repair-FailedWorkflow -RepoPath 'E:\career\DevControlPlane' -AutoCommit
    Full automated repair pipeline.
#>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string[]]$Repository,
        [int]$MaxRuns = 5
    )

    $token = Get-GitHubToken
    if (-not $token) { throw 'GitHub token unavailable. Store it with: Set-Secret -Name GitHubToken -Vault DevVault -Secret <token>' }

    [array]$repoList = if ($Repository) {
        $Repository
    } elseif ($env:GITHUB_REPOSITORY) {
        $env:GITHUB_REPOSITORY
    } elseif ($script:Config -and $script:Config.repositories) {
        $script:Config.repositories
    } else {
        throw 'No repositories configured. Pass -Repository or set DevControlPlane.config.json.'
    }

    $headers = @{ Authorization = "Bearer $token"; Accept = 'application/vnd.github+json' }

    [array]$failures = foreach ($repo in $repoList) {
        try {
            $runs = (Invoke-RestMethod `
                -Uri "https://api.github.com/repos/$repo/actions/runs?per_page=$MaxRuns&status=failure" `
                -Headers $headers -ErrorAction Stop).workflow_runs

            foreach ($run in $runs) {
                $jobs = (Invoke-RestMethod `
                    -Uri "https://api.github.com/repos/$repo/actions/runs/$($run.id)/jobs" `
                    -Headers $headers -ErrorAction Stop).jobs

                foreach ($job in ($jobs | Where-Object { $_.conclusion -eq 'failure' })) {
                    $logText  = Get-WorkflowJobLogs -Repo $repo -JobId $job.id -Token $token
                    $pattern  = Get-PatternFix -LogText $logText
                    $failFile = if ($logText -match '[\\/]([\w.-]+\.ps1):\d+') { $Matches[1] } else { $null }

                    [PSCustomObject]@{
                        Repository    = $repo
                        RunId         = $run.id
                        WorkflowName  = $run.name
                        Branch        = $run.head_branch
                        CommitSha     = $run.head_sha.Substring(0, 7)
                        CreatedAt     = $run.created_at
                        JobId         = $job.id
                        JobName       = $job.name
                        FailedSteps   = @($job.steps | Where-Object { $_.conclusion -eq 'failure' } | Select-Object -ExpandProperty name)
                        LogExcerpt    = ($logText -split "`n" | Where-Object { $_ -match 'error|fail|exception|cannot|not found' } | Select-Object -First 15) -join "`n"
                        FullLog       = $logText
                        KnownPattern  = $pattern
                        FailedFile    = $failFile
                        HtmlUrl       = $run.html_url
                    }
                }
            }
        } catch {
            Write-Warning "Could not fetch failures for ${repo}: $_"
        }
    }

    if (-not $failures) {
        Write-Host 'No failed runs found across configured repositories.' -ForegroundColor Green
    }

    $failures
}

#endregion

#region Repair-FailedWorkflow

function Repair-FailedWorkflow {
<#
.SYNOPSIS
    Diagnoses and repairs a GitHub Actions workflow failure.

.DESCRIPTION
    Accepts a failure object from Get-WorkflowFailures (or pipeline input).
    First tries a pattern engine covering common CI failures (hardcoded paths,
    missing modules, missing secrets, command-not-found). If no pattern matches,
    sends the failure log and relevant file content to Claude API for an
    AI-generated fix. Applies the fix to the local repo files. Use -AutoCommit
    to automatically git add, commit, and push.

.PARAMETER Failure
    A failure object from Get-WorkflowFailures. Accepts pipeline input.

.PARAMETER RepoPath
    Local path to the git repository root. Defaults to the current directory.

.PARAMETER AutoCommit
    When set, automatically stages, commits, and pushes fixed files.

.EXAMPLE
    Get-WorkflowFailures -Repository 'RobertKimutai-DS/DevControlPlane' | Repair-FailedWorkflow -RepoPath 'E:\career\DevControlPlane'
    Diagnoses and repairs all failures, showing a diff for review.

.EXAMPLE
    Get-WorkflowFailures | Repair-FailedWorkflow -RepoPath 'E:\career\DevControlPlane' -AutoCommit
    Full automated repair and push.
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$Failure,

        [string]$RepoPath = (Get-Location).Path,

        [switch]$AutoCommit
    )

    process {
        Write-Host "`n[$($Failure.Repository)] $($Failure.WorkflowName) @ $($Failure.CommitSha)" -ForegroundColor Cyan
        Write-Host "  Job     : $($Failure.JobName)" -ForegroundColor DarkCyan
        Write-Host "  Steps   : $($Failure.FailedSteps -join ', ')" -ForegroundColor DarkCyan
        Write-Host "  URL     : $($Failure.HtmlUrl)" -ForegroundColor DarkCyan

        # --- Try pattern engine first ---
        $repair = $null

        if ($Failure.KnownPattern) {
            $p = $Failure.KnownPattern
            Write-Host "`n  Pattern : $($p.PatternName)" -ForegroundColor Yellow
            Write-Host "  Diagnosis: $($p.Diagnosis)" -ForegroundColor Yellow
            Write-Host "  Sending to Claude Code for file-specific fix..." -ForegroundColor DarkYellow

            try {
                $repair = Invoke-ClaudeRepair -LogText $Failure.FullLog -RepoPath $RepoPath -FailedFile $Failure.FailedFile
                $repair | Add-Member -NotePropertyName 'Source' -NotePropertyValue 'Pattern+Claude'
            } catch {
                Write-Warning "Claude API unavailable: $_"
                $repair = [PSCustomObject]@{
                    Source        = 'PatternOnly'
                    diagnosis     = $p.Diagnosis
                    severity      = 'medium'
                    fixes         = @()
                    commit_message = "fix: $($p.PatternName -creplace '([A-Z])',' $1').Trim().ToLower()"
                    Instruction   = $p.Instruction
                }
            }
        } else {
            Write-Host "`n  No known pattern matched. Sending to Claude Code for analysis..." -ForegroundColor Magenta
            try {
                $repair = Invoke-ClaudeRepair -LogText $Failure.FullLog -RepoPath $RepoPath -FailedFile $Failure.FailedFile
                $repair | Add-Member -NotePropertyName 'Source' -NotePropertyValue 'Claude'
            } catch {
                Write-Warning "Claude API unavailable: $_"
                Write-Host "`n  Log excerpt for manual review:" -ForegroundColor Red
                Write-Host $Failure.LogExcerpt -ForegroundColor DarkRed
                return [PSCustomObject]@{ Repository = $Failure.Repository; Status = 'ManualReviewRequired'; Repair = $null }
            }
        }

        Write-Host "`n  Diagnosis : $($repair.diagnosis)" -ForegroundColor White
        Write-Host "  Severity  : $($repair.severity)" -ForegroundColor White

        # --- Apply fixes ---
        $appliedFixes = @()

        foreach ($fix in $repair.fixes) {
            $targetFile = Join-Path $RepoPath $fix.file
            if (-not (Test-Path $targetFile)) {
                Write-Warning "  File not found locally: $targetFile — skipping fix."
                continue
            }

            if ($PSCmdlet.ShouldProcess($targetFile, "Apply fix: $($fix.description)")) {
                $current = Get-Content $targetFile -Raw
                if ($fix.search -and $current -match [regex]::Escape($fix.search)) {
                    $updated = $current.Replace($fix.search, $fix.replace)
                    Set-Content -Path $targetFile -Value $updated -Encoding UTF8 -NoNewline
                    Write-Host "  FIXED : $($fix.file) — $($fix.description)" -ForegroundColor Green
                    $appliedFixes += $targetFile
                } else {
                    Write-Warning "  SKIPPED: Search string not found in $($fix.file)"
                }
            }
        }

        # --- Auto-commit ---
        if ($AutoCommit -and $appliedFixes.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($RepoPath, "git add, commit, and push")) {
                Push-Location $RepoPath
                try {
                    $appliedFixes | ForEach-Object { git add $_ 2>$null }
                    $msg = if ($repair.commit_message) { $repair.commit_message } else { "fix: auto-repair CI failure in $($Failure.Repository)" }
                    git commit -m $msg 2>$null
                    git push 2>$null
                    Write-Host "  PUSHED: $msg" -ForegroundColor Green
                } finally {
                    Pop-Location
                }
            }
        } elseif ($appliedFixes.Count -gt 0) {
            Write-Host "  Review changes then run: git add, git commit, git push" -ForegroundColor DarkYellow
        }

        [PSCustomObject]@{
            Repository    = $Failure.Repository
            Status        = if ($appliedFixes.Count -gt 0) { 'Fixed' } elseif ($repair.fixes.Count -eq 0) { 'DiagnosisOnly' } else { 'SkippedFileNotFound' }
            Source        = $repair.Source
            Diagnosis     = $repair.diagnosis
            Severity      = $repair.severity
            FilesFixed    = $appliedFixes
            CommitMessage = $repair.commit_message
        }
    }
}

#endregion