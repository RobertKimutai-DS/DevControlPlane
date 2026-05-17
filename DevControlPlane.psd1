@{
    ModuleVersion     = '1.1.0'
    GUID              = 'a3f1c2d4-5e6b-7890-abcd-ef1234567890'
    Author            = 'Robert Kimutai'
    CompanyName       = 'DevControlPlane'
    Copyright         = '(c) 2026 Robert Kimutai. All rights reserved.'
    Description       = 'Enterprise-grade PowerShell environment manager for Docker, GitHub, VS Code, and RStudio.'
    PowerShellVersion = '7.0'

    RootModule        = 'DevControlPlane.psm1'

    FunctionsToExport = @(
        'Get-DevWorkspaceStatus',
        'Optimize-DevWorkspace',
        'Start-ControlPanel'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('DevOps', 'Docker', 'GitHub', 'VSCode', 'RStudio', 'Workspace')
            ProjectUri = 'https://github.com/robertkimutai/DevControlPlane'
        }
    }
}
