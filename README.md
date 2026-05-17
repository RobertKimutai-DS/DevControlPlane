# DevControlPlane

A modular PowerShell environment manager built for developers who work across Docker, GitHub, VS Code, and RStudio daily. Instead of jumping between terminals and dashboards to check what is going on with your machine, this gives you one command that tells you everything.

---

## Why I Built This

When you are deep in a project, the last thing you want is to stop and manually check if Docker has zombie containers eating resources, whether your VS Code workspace cache has ballooned to a gigabyte, or whether your latest GitHub Actions push actually passed. DevControlPlane pulls all of that into a single status object you can query, clean up with, or pipe into anything else.

---

## What It Does

**`Get-DevWorkspaceStatus`** queries your environment and returns a clean PowerShell object with:

- Docker engine health and count of exited/zombie containers
- VS Code workspace storage size
- RStudio history and data file presence
- GitHub Actions run history across all your repositories (public and private)

**`Optimize-DevWorkspace`** cleans things up:

- Prunes dangling Docker volumes and removes exited containers
- Deletes VS Code workspace cache folders older than 7 days
- Removes RStudio `.Rhistory` and `.RData` artifacts
- Writes every action to an append-only audit log so you always know what was touched

**`Start-ControlPanel`** spins up a lightweight REST API on port 8080 using [Pode](https://github.com/Badgerati/Pode):

- `GET /health` - unauthenticated liveness check
- `GET /status` - full workspace status as JSON (requires API key)
- `GET /clean`  - triggers cleanup remotely (requires API key)

**`Invoke-ClaudeContext`** (via the `cctx` alias) generates a structured `.claude-context.md` file combining your workspace status with the current git state. Useful when you want to hand AI assistants accurate, up-to-date context about your environment.

---

## Requirements

- PowerShell 7.0 or later
- Docker Desktop (for Docker checks and cleanup)
- Git (for context generation)
- A GitHub Personal Access Token with `repo` scope (for Actions polling)

---

## Setup

**1. Clone the repo**

```powershell
git clone https://github.com/RobertKimutai-DS/DevControlPlane.git
cd DevControlPlane
```

**2. Install the module**

```powershell
$dst = "$HOME\Documents\PowerShell\Modules\DevControlPlane\1.1.0"
New-Item -ItemType Directory -Path $dst -Force | Out-Null
Copy-Item *.psd1, *.psm1, *.ps1, *.json $dst -Force
```

**3. Install dependencies**

```powershell
Install-Module Microsoft.PowerShell.SecretManagement -Scope CurrentUser -Force
Install-Module Microsoft.PowerShell.SecretStore       -Scope CurrentUser -Force
Install-Module Pode                                   -Scope CurrentUser -Force
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
```

**4. Store your GitHub token securely**

```powershell
Import-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore

Register-SecretVault -Name DevVault -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
Set-SecretStoreConfiguration -Authentication None -Confirm:$false

Set-Secret -Name GitHubToken -Secret 'your_token_here' -Vault DevVault
```

Your token needs `repo` scope to read private repository Actions data.

**5. Set up your repositories**

Edit `DevControlPlane.config.json` to list the repos you want to monitor:

```json
{
  "repositories": [
    "your-username/repo-one",
    "your-username/repo-two"
  ],
  "apiKey": "change-this-to-something-strong",
  "port": 8080
}
```

**6. Wire up your shell**

```powershell
& .\ProfileConfig.ps1
```

Restart your terminal. You now have three short commands available globally.

---

## Daily Usage

```powershell
# Check everything at once
dstatus

# See what would be cleaned without actually doing it
dclean -WhatIf

# Run the cleanup
dclean

# Generate a context file for your current project
cctx

# Start the REST API
Start-ControlPanel
```

Query a specific set of repos without changing your config:

```powershell
dstatus -Repository 'your-username/repo-one', 'your-username/repo-two'
```

Hit the API from anywhere:

```powershell
$key = 'your-api-key'
Invoke-RestMethod http://localhost:8080/health
Invoke-RestMethod http://localhost:8080/status -Headers @{ 'X-Api-Key' = $key }
```

---

## Running Tests

```powershell
Import-Module Pester -MinimumVersion 5.0 -Force
Invoke-Pester -Path .\DevControlPlane.Tests.ps1
```

30 tests covering the manifest, output shape contracts, WhatIf safety, port validation, and GitHub Actions integration.

---

## Security Notes

- The GitHub token is stored in the Windows SecretStore vault, not in environment variables or config files
- The REST API requires an `X-Api-Key` header on all routes except `/health`
- The config file holds the API key in plaintext; for production use consider moving it to the SecretStore vault as well
- Rotate your GitHub token every 90 days

---

## Audit Log

Every real run of `dclean` appends a row to `logs/cleanup-audit.log` (CSV format):

```
Timestamp, Action, Target, Result, User
```

The logs directory is excluded from git via `.gitignore`.

---

## Project Structure

```
DevControlPlane/
├── DevControlPlane.psd1          Module manifest
├── DevControlPlane.psm1          Core logic (3 exported functions)
├── DevControlPlane.config.json   Repo list, API key, port
├── DevControlPlane.Tests.ps1     Pester 5 test suite
├── Start-ControlPanel.ps1        Pode REST API server
├── Invoke-ClaudeContext.ps1      Context file generator
└── ProfileConfig.ps1             Shell alias installer
```

---

## License

MIT
