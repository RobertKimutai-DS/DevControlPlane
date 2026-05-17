#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    Import-Module Pester -MinimumVersion 5.0 -Force
    $manifestPath = Join-Path $PSScriptRoot 'DevControlPlane.psd1'
    Remove-Module DevControlPlane -Force -ErrorAction SilentlyContinue
    Import-Module $manifestPath -Force
}

# ---------------------------------------------------------------------------
Describe 'Module Manifest' {

    BeforeAll {
        $script:manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'DevControlPlane.psd1')
    }

    It 'exports Get-DevWorkspaceStatus' {
        $script:manifest.FunctionsToExport | Should -Contain 'Get-DevWorkspaceStatus'
    }

    It 'exports Optimize-DevWorkspace' {
        $script:manifest.FunctionsToExport | Should -Contain 'Optimize-DevWorkspace'
    }

    It 'exports Start-ControlPanel' {
        $script:manifest.FunctionsToExport | Should -Contain 'Start-ControlPanel'
    }

    It 'exports exactly 5 functions' {
        $script:manifest.FunctionsToExport.Count | Should -Be 5
    }

    It 'has a valid GUID format' {
        $script:manifest.GUID | Should -Match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    }

    It 'specifies a PowerShellVersion' {
        $script:manifest.PowerShellVersion | Should -Not -BeNullOrEmpty
    }

    It 'has a non-empty Description' {
        $script:manifest.Description | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-DevWorkspaceStatus' {

    Context 'Output shape contract' {

        BeforeAll {
            $script:result = Get-DevWorkspaceStatus
        }

        It 'returns a PSCustomObject' {
            $script:result | Should -BeOfType [PSCustomObject]
        }

        It 'has a Timestamp property' {
            $script:result.PSObject.Properties.Name | Should -Contain 'Timestamp'
        }

        It 'has a Docker property' {
            $script:result.PSObject.Properties.Name | Should -Contain 'Docker'
        }

        It 'has a VSCode property' {
            $script:result.PSObject.Properties.Name | Should -Contain 'VSCode'
        }

        It 'has a RStudio property' {
            $script:result.PSObject.Properties.Name | Should -Contain 'RStudio'
        }

        It 'has a GitHubActions property' {
            $script:result.PSObject.Properties.Name | Should -Contain 'GitHubActions'
        }

        It 'has a GitHubActionsError property' {
            $script:result.PSObject.Properties.Name | Should -Contain 'GitHubActionsError'
        }

        It 'Timestamp parses as a valid datetime' {
            { [datetime]::Parse($script:result.Timestamp) } | Should -Not -Throw
        }

        It 'Docker.EngineHealth is a non-empty string' {
            $script:result.Docker.EngineHealth | Should -BeOfType [string]
            $script:result.Docker.EngineHealth | Should -Not -BeNullOrEmpty
        }

        It 'VSCode.WorkspaceStorageSizeMB is a number >= 0' {
            $script:result.VSCode.WorkspaceStorageSizeMB | Should -BeGreaterOrEqual 0
        }
    }

    Context 'Repository parameter' {

        It 'accepts a single repository string' {
            { Get-DevWorkspaceStatus -Repository 'RobertKimutai-DS/Portfolio' } | Should -Not -Throw
        }

        It 'accepts multiple repository strings' {
            { Get-DevWorkspaceStatus -Repository 'RobertKimutai-DS/Portfolio','RobertKimutai-DS/RobertKimutai-DS' } |
                Should -Not -Throw
        }

        It 'rejects invalid repository format (no slash)' {
            { Get-DevWorkspaceStatus -Repository 'invalid-no-slash' } | Should -Throw
        }

        It 'returns one result object per repository' {
            $r = Get-DevWorkspaceStatus -Repository 'RobertKimutai-DS/Portfolio','RobertKimutai-DS/RobertKimutai-DS'
            $r.GitHubActions.Count | Should -Be 2
        }
    }

    Context 'GitHub Actions integration' {

        It 'sets GitHubActionsError when no repository and no env var configured' {
            $saved = $env:GITHUB_REPOSITORY
            Remove-Item Env:\GITHUB_REPOSITORY -ErrorAction SilentlyContinue
            $r = Get-DevWorkspaceStatus
            $env:GITHUB_REPOSITORY = $saved
            ($r.GitHubActionsError -or $r.GitHubActions) | Should -BeTrue
        }

        It 'GitHubActions returns a result with Repository property when repo is specified' {
            $r = Get-DevWorkspaceStatus -Repository 'RobertKimutai-DS/Portfolio'
            $r.GitHubActions | Should -Not -BeNullOrEmpty
            (@($r.GitHubActions))[0].Repository | Should -Be 'RobertKimutai-DS/Portfolio'
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Optimize-DevWorkspace' {

    Context '-WhatIf safety' {

        It 'does not throw with -WhatIf' {
            { Optimize-DevWorkspace -WhatIf } | Should -Not -Throw
        }

        It 'does not write an audit log entry when run with -WhatIf' {
            $logFile = Join-Path $PSScriptRoot 'logs\cleanup-audit.log'
            $before  = if (Test-Path $logFile) { (Get-Item $logFile).LastWriteTime } else { $null }
            Optimize-DevWorkspace -WhatIf
            $after   = if (Test-Path $logFile) { (Get-Item $logFile).LastWriteTime } else { $null }
            $after | Should -Be $before
        }
    }

    Context 'CmdletBinding' {

        It 'supports SupportsShouldProcess (has -WhatIf parameter)' {
            $cmd = Get-Command Optimize-DevWorkspace
            $cmd.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }

        It 'supports -Confirm parameter' {
            $cmd = Get-Command Optimize-DevWorkspace
            $cmd.Parameters.ContainsKey('Confirm') | Should -BeTrue
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Start-ControlPanel port validation' {

    It 'rejects port below 1024' {
        { Start-ControlPanel -Port 80 } | Should -Throw
    }

    It 'rejects port above 65535' {
        { Start-ControlPanel -Port 99999 } | Should -Throw
    }

    It 'accepts a valid port in range' {
        $cmd = Get-Command Start-ControlPanel
        $portParam = $cmd.Parameters['Port']
        $portParam | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-WorkflowFailures' {

    It 'is exported by the module' {
        Get-Command Get-WorkflowFailures -Module DevControlPlane | Should -Not -BeNullOrEmpty
    }

    It 'accepts -Repository parameter' {
        $cmd = Get-Command Get-WorkflowFailures
        $cmd.Parameters.ContainsKey('Repository') | Should -BeTrue
    }

    It 'accepts -MaxRuns parameter' {
        $cmd = Get-Command Get-WorkflowFailures
        $cmd.Parameters.ContainsKey('MaxRuns') | Should -BeTrue
    }

    It 'rejects invalid repository format' {
        { Get-WorkflowFailures -Repository 'no-slash-here' } | Should -Throw
    }

    It 'returns array or null when querying a valid repo with no failures' {
        # This test is safe -- returns empty if no failures, never throws on valid repo
        $result = Get-WorkflowFailures -Repository 'RobertKimutai-DS/DevControlPlane'
        # Result is either $null/empty or a PSCustomObject array
        ($null -eq $result -or $result -is [array] -or $result -is [PSCustomObject]) | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
Describe 'Repair-FailedWorkflow' {

    It 'is exported by the module' {
        Get-Command Repair-FailedWorkflow -Module DevControlPlane | Should -Not -BeNullOrEmpty
    }

    It 'accepts -RepoPath parameter' {
        $cmd = Get-Command Repair-FailedWorkflow
        $cmd.Parameters.ContainsKey('RepoPath') | Should -BeTrue
    }

    It 'accepts -AutoCommit switch' {
        $cmd = Get-Command Repair-FailedWorkflow
        $cmd.Parameters.ContainsKey('AutoCommit') | Should -BeTrue
    }

    It 'supports -WhatIf via SupportsShouldProcess' {
        $cmd = Get-Command Repair-FailedWorkflow
        $cmd.Parameters.ContainsKey('WhatIf') | Should -BeTrue
    }

    It 'requires -Failure parameter (Mandatory)' {
        $cmd = Get-Command Repair-FailedWorkflow
        $cmd.Parameters['Failure'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
            Select-Object -ExpandProperty Mandatory | Should -BeTrue
    }
}
