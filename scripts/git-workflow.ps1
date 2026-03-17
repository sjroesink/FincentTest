# Fincent Git Workflow Script
# Automates environment promotions, back-merges, and hotfix workflows via GitHub PRs.
# Dependency: gh CLI (authenticated)
#
# Usage:
#   .\scripts\git-workflow.ps1                                          # Interactive menu
#   .\scripts\git-workflow.ps1 -Action status                           # Show branch sync status
#   .\scripts\git-workflow.ps1 -Action promote -From master -To testing # Promote via PR
#   .\scripts\git-workflow.ps1 -Action promote -From master -To testing -DryRun  # Preview only

param(
    [ValidateSet('promote', 'backmerge', 'hotfix-create', 'hotfix-apply', 'status', 'menu')]
    [string]$Action = 'menu',
    [ValidateSet('master', 'testing', 'acceptatie', 'pre-productie', 'productie')]
    [string]$From,
    [ValidateSet('master', 'testing', 'acceptatie', 'pre-productie', 'productie')]
    [string]$To,
    [string]$HotfixName,
    [string]$CommitHash,
    [switch]$DryRun,
    [switch]$NoConfirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────

$script:Environments = @('master', 'testing', 'acceptatie', 'pre-productie', 'productie')

# ── Helper Functions ───────────────────────────────────────────────────────────

function Write-Status {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO', 'DRY-RUN')]
        [string]$Level,
        [string]$Message
    )

    $colors = @{
        'OK'      = 'Green'
        'WARN'    = 'Yellow'
        'FAIL'    = 'Red'
        'INFO'    = 'Cyan'
        'DRY-RUN' = 'Magenta'
    }

    Write-Host "[$Level] " -ForegroundColor $colors[$Level] -NoNewline
    Write-Host $Message
}

function Assert-Prerequisites {
    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghCmd) {
        Write-Status 'FAIL' 'gh CLI is not installed. Install from https://cli.github.com/'
        exit 1
    }

    $authStatus = gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Status 'FAIL' "gh CLI is not authenticated. Run 'gh auth login' first."
        Write-Host $authStatus -ForegroundColor Gray
        exit 1
    }

    Write-Status 'OK' 'gh CLI authenticated'
}

function Assert-CleanWorkingTree {
    # Only check for modified/staged files, not untracked ones
    $status = git diff --name-only HEAD 2>&1
    $staged = git diff --cached --name-only 2>&1
    if ($status -or $staged) {
        Write-Status 'FAIL' 'Working tree has uncommitted changes. Please commit or stash first.'
        git status --short
        exit 1
    }
}

function Sync-Branch {
    param([string]$Branch)

    git fetch origin $Branch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Status 'WARN' "Could not fetch origin/$Branch"
        return $false
    }

    # Fast-forward local branch if it exists
    $localRef = git rev-parse --verify $Branch 2>&1
    if ($LASTEXITCODE -eq 0) {
        $remoteRef = git rev-parse "origin/$Branch" 2>&1
        if ($localRef -ne $remoteRef) {
            git update-ref "refs/heads/$Branch" "origin/$Branch" 2>&1 | Out-Null
        }
    }

    return $true
}

function Get-CommitsBetween {
    param(
        [string]$Source,
        [string]$Target
    )

    $commits = @(git log --oneline "origin/$Target..origin/$Source" 2>&1)
    if ($LASTEXITCODE -ne 0) { return , @() }
    $commits = @($commits | Where-Object { $_ })
    return , $commits
}

function Get-DiffSummary {
    param(
        [string]$Source,
        [string]$Target
    )

    $diff = git diff --stat "origin/$Target..origin/$Source" 2>&1
    if ($LASTEXITCODE -ne 0) { return "" }
    return $diff
}

function Confirm-Action {
    param([string]$Message)

    if ($NoConfirm) { return $true }

    Write-Host ""
    Write-Host "  $Message " -ForegroundColor Yellow -NoNewline
    Write-Host "(Y/n) " -NoNewline
    $response = Read-Host
    return ($response -eq '' -or $response -eq 'Y' -or $response -eq 'y')
}

function New-EnvironmentPR {
    param(
        [string]$Source,
        [string]$Target,
        [string]$Title,
        [string]$Body
    )

    if ($DryRun) {
        Write-Status 'DRY-RUN' "Would create PR: $Title ($Source -> $Target)"
        return -1
    }

    $result = gh pr create --base $Target --head $Source --title $Title --body $Body 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Check if PR already exists
        if ($result -match 'already exists') {
            Write-Status 'INFO' "PR already exists for $Source -> $Target"
            $existing = gh pr list --base $Target --head $Source --json number --jq '.[0].number' 2>&1
            if ($LASTEXITCODE -eq 0 -and $existing) {
                Write-Status 'INFO' "Using existing PR #$existing"
                return [int]$existing
            }
        }
        Write-Status 'FAIL' "Failed to create PR: $result"
        return $null
    }

    # Extract PR number from URL
    if ($result -match '/pull/(\d+)') {
        $prNumber = [int]$Matches[1]
        Write-Status 'OK' "Created PR #${prNumber}: $Title"
        return $prNumber
    }

    Write-Status 'FAIL' "Could not parse PR number from: $result"
    return $null
}

function Merge-PR {
    param([int]$PRNumber)

    if ($DryRun) {
        Write-Status 'DRY-RUN' "Would merge PR #$PRNumber with merge commit"
        return $true
    }

    Write-Status 'INFO' "Merging PR #$PRNumber..."

    $result = gh pr merge $PRNumber --merge --delete-branch=false 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($result -match 'merge conflict' -or $result -match 'not mergeable') {
            Write-Status 'FAIL' "PR #$PRNumber has merge conflicts. Resolve them manually in GitHub or locally."
            return $false
        }
        if ($result -match 'check' -or $result -match 'status') {
            Write-Status 'WARN' "PR #$PRNumber has failing checks. Check GitHub for details."
            if (-not (Confirm-Action "Try to merge anyway?")) {
                return $false
            }
            $result = gh pr merge $PRNumber --merge --delete-branch=false --admin 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Status 'FAIL' "Could not merge PR #${PRNumber}: $result"
                return $false
            }
        } else {
            Write-Status 'FAIL' "Failed to merge PR #${PRNumber}: $result"
            return $false
        }
    }

    Write-Status 'OK' "PR #$PRNumber merged successfully"
    return $true
}

function Invoke-CherryPickViaPR {
    param(
        [string]$Commit,
        [string]$TargetBranch,
        [string]$Description
    )

    $tempBranch = "hotfix-apply/$HotfixName"

    if ($DryRun) {
        Write-Status 'DRY-RUN' "Would cherry-pick $Commit to $TargetBranch via branch $tempBranch"
        return $true
    }

    Write-Status 'INFO' "Creating temporary branch $tempBranch from origin/$TargetBranch..."

    git checkout -b $tempBranch "origin/$TargetBranch" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Status 'FAIL' "Could not create branch $tempBranch"
        return $false
    }

    Write-Status 'INFO' "Cherry-picking $Commit..."
    $cherryResult = git cherry-pick $Commit 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Status 'FAIL' "Cherry-pick failed with conflicts:"
        Write-Host $cherryResult -ForegroundColor Gray
        Write-Host ""
        Write-Status 'INFO' "Resolve conflicts, commit, push $tempBranch, and create a PR to $TargetBranch manually."
        git cherry-pick --abort 2>&1 | Out-Null
        git checkout - 2>&1 | Out-Null
        git branch -D $tempBranch 2>&1 | Out-Null
        return $false
    }

    Write-Status 'INFO' "Pushing $tempBranch to origin..."
    git push -u origin $tempBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Status 'FAIL' "Could not push $tempBranch"
        git checkout - 2>&1 | Out-Null
        return $false
    }

    # Return to previous branch
    git checkout - 2>&1 | Out-Null

    $prNumber = New-EnvironmentPR -Source $tempBranch -Target $TargetBranch `
        -Title "Cherry-pick hotfix/$HotfixName to $TargetBranch" `
        -Body "Cherry-pick of commit ``$Commit`` ($Description) to $TargetBranch.`n`nPart of hotfix/$HotfixName workflow."

    if ($null -eq $prNumber) { return $false }

    if (-not (Confirm-Action "Merge cherry-pick PR #${prNumber} to ${TargetBranch}?")) {
        Write-Status 'INFO' "PR #$prNumber left open. Merge it manually when ready."
        return $true
    }

    $merged = Merge-PR -PRNumber $prNumber
    if ($merged) {
        # Clean up temporary branch
        git push origin --delete $tempBranch 2>&1 | Out-Null
        git branch -D $tempBranch 2>&1 | Out-Null
        Write-Status 'OK' "Cleaned up temporary branch $tempBranch"
    }

    return $merged
}

function Get-EnvironmentRange {
    param(
        [string]$FromEnv,
        [string]$ToEnv
    )

    $fromIdx = $script:Environments.IndexOf($FromEnv)
    $toIdx = $script:Environments.IndexOf($ToEnv)

    if ($fromIdx -eq -1 -or $toIdx -eq -1) {
        return @()
    }

    if ($fromIdx -lt $toIdx) {
        # Forward (promote)
        return $script:Environments[$fromIdx..$toIdx]
    } else {
        # Backward (backmerge) - reverse order
        $range = $script:Environments[$toIdx..$fromIdx]
        [array]::Reverse($range)
        return $range
    }
}

# ── Workflow Functions ─────────────────────────────────────────────────────────

function Invoke-Promote {
    param(
        [string]$FromEnv,
        [string]$ToEnv
    )

    $fromIdx = $script:Environments.IndexOf($FromEnv)
    $toIdx = $script:Environments.IndexOf($ToEnv)

    if ($fromIdx -ge $toIdx) {
        Write-Status 'FAIL' "Cannot promote backwards. Use back-merge instead."
        return
    }

    Write-Host ""
    Write-Host "=== Promote $FromEnv -> $ToEnv ===" -ForegroundColor Cyan
    Write-Host ""

    # Fetch all involved branches
    $range = Get-EnvironmentRange -FromEnv $FromEnv -ToEnv $ToEnv
    foreach ($branch in $range) {
        Sync-Branch -Branch $branch | Out-Null
    }

    # Process each step
    for ($i = 0; $i -lt ($range.Count - 1); $i++) {
        $source = $range[$i]
        $target = $range[$i + 1]

        Write-Host ""
        Write-Host "--- Step $($i + 1): $source -> $target ---" -ForegroundColor Yellow

        $commits = Get-CommitsBetween -Source $source -Target $target
        if ($commits.Count -eq 0) {
            Write-Status 'OK' "$target is already in sync with $source"
            continue
        }

        Write-Status 'INFO' "$($commits.Count) commit(s) to promote:"
        foreach ($c in $commits) {
            Write-Host "    $c" -ForegroundColor Gray
        }

        $diff = Get-DiffSummary -Source $source -Target $target
        if ($diff) {
            Write-Host ""
            Write-Host $diff -ForegroundColor Gray
        }

        if (-not (Confirm-Action "Create PR to promote ${source} to ${target}?")) {
            Write-Status 'INFO' "Skipped $source -> $target"
            return
        }

        $prNumber = New-EnvironmentPR -Source $source -Target $target `
            -Title "Promote $source to $target" `
            -Body "Environment promotion: merge $source into $target.`n`n$($commits.Count) commit(s) included."

        if ($null -eq $prNumber) { return }
        if ($prNumber -eq -1) { continue } # dry-run

        if (-not (Confirm-Action "Merge PR #${prNumber}?")) {
            Write-Status 'INFO' "PR #$prNumber left open. Merge it manually when ready."
            return
        }

        $merged = Merge-PR -PRNumber $prNumber
        if (-not $merged) { return }

        # Refresh local state
        Sync-Branch -Branch $target | Out-Null
    }

    Write-Host ""
    Write-Status 'OK' "Promotion $FromEnv -> $ToEnv complete!"
}

function Invoke-BackMerge {
    param(
        [string]$FromEnv,
        [string]$ToEnv
    )

    $fromIdx = $script:Environments.IndexOf($FromEnv)
    $toIdx = $script:Environments.IndexOf($ToEnv)

    if ($fromIdx -le $toIdx) {
        Write-Status 'FAIL' "Cannot back-merge forwards. Use promote instead."
        return
    }

    Write-Host ""
    Write-Host "=== Back-merge $FromEnv -> $ToEnv ===" -ForegroundColor Cyan
    Write-Host ""

    # Fetch all involved branches (from high to low)
    $range = Get-EnvironmentRange -FromEnv $FromEnv -ToEnv $ToEnv
    foreach ($branch in $range) {
        Sync-Branch -Branch $branch | Out-Null
    }

    # Process each step (high to low)
    for ($i = 0; $i -lt ($range.Count - 1); $i++) {
        $source = $range[$i]
        $target = $range[$i + 1]

        Write-Host ""
        Write-Host "--- Step $($i + 1): $source -> $target ---" -ForegroundColor Yellow

        $commits = Get-CommitsBetween -Source $source -Target $target
        if ($commits.Count -eq 0) {
            Write-Status 'OK' "$target is already in sync with $source"
            continue
        }

        Write-Status 'INFO' "$($commits.Count) commit(s) to back-merge:"
        foreach ($c in $commits) {
            Write-Host "    $c" -ForegroundColor Gray
        }

        # Warn if there are file changes (indicates wrong workflow)
        $diff = Get-DiffSummary -Source $source -Target $target
        if ($diff) {
            Write-Host ""
            Write-Status 'WARN' "File changes detected during back-merge (expected: only merge commits):"
            Write-Host $diff -ForegroundColor Yellow
            Write-Host ""
            Write-Status 'WARN' "This may indicate changes were squashed to multiple branches independently."
        }

        if (-not (Confirm-Action "Create PR to back-merge ${source} into ${target}?")) {
            Write-Status 'INFO' "Skipped $source -> $target"
            return
        }

        $prNumber = New-EnvironmentPR -Source $source -Target $target `
            -Title "Back-merge $source into $target" `
            -Body "Back-merge: sync $source into $target.`n`n$($commits.Count) commit(s) included."

        if ($null -eq $prNumber) { return }
        if ($prNumber -eq -1) { continue } # dry-run

        if (-not (Confirm-Action "Merge PR #${prNumber}?")) {
            Write-Status 'INFO' "PR #$prNumber left open. Merge it manually when ready."
            return
        }

        $merged = Merge-PR -PRNumber $prNumber
        if (-not $merged) { return }

        # Refresh local state
        Sync-Branch -Branch $target | Out-Null
    }

    Write-Host ""
    Write-Status 'OK' "Back-merge $FromEnv -> $ToEnv complete!"
}

function Invoke-HotfixCreate {
    param(
        [string]$Name,
        [string]$Environment
    )

    Write-Host ""
    Write-Host "=== Create Hotfix ===" -ForegroundColor Cyan
    Write-Host ""

    Sync-Branch -Branch $Environment | Out-Null

    $branchName = "hotfix/$Name"

    if ($DryRun) {
        Write-Status 'DRY-RUN' "Would create branch $branchName from origin/$Environment"
        return
    }

    git checkout -b $branchName "origin/$Environment" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Status 'FAIL' "Could not create branch $branchName"
        return
    }

    git push -u origin $branchName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Status 'FAIL' "Could not push $branchName to origin"
        return
    }

    Write-Status 'OK' "Created and pushed $branchName from $Environment"
    Write-Host ""
    Write-Status 'INFO' "Next steps:"
    Write-Host "  1. Make your fix, commit, and push to $branchName" -ForegroundColor Gray
    Write-Host "  2. Create a PR from $branchName to $Environment and merge it (squash merge)" -ForegroundColor Gray
    Write-Host "  3. Run: .\scripts\git-workflow.ps1 -Action hotfix-apply -From $Environment -HotfixName $Name" -ForegroundColor Gray
}

function Invoke-HotfixApply {
    param(
        [string]$Environment,
        [string]$Name,
        [string]$Commit
    )

    Write-Host ""
    Write-Host "=== Apply Hotfix ===" -ForegroundColor Cyan
    Write-Host ""

    $envIdx = $script:Environments.IndexOf($Environment)
    if ($envIdx -le 0) {
        Write-Status 'FAIL' "Hotfix apply only needed for environments above master."
        return
    }

    # Fetch latest
    Sync-Branch -Branch $Environment | Out-Null
    Sync-Branch -Branch 'master' | Out-Null

    # Find the commit to cherry-pick if not specified
    if (-not $Commit) {
        Write-Status 'INFO' "Looking for the hotfix merge commit on $Environment..."
        $recentCommits = git log --oneline -10 "origin/$Environment" 2>&1
        Write-Host ""
        Write-Host "  Recent commits on $Environment`:" -ForegroundColor Yellow
        $idx = 0
        $commitList = @()
        foreach ($c in $recentCommits) {
            $idx++
            $commitList += $c
            Write-Host "    [$idx] $c" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "  Select the hotfix commit to cherry-pick to master (1-$idx): " -ForegroundColor Yellow -NoNewline
        $selection = Read-Host
        if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $idx) {
            $selectedLine = $commitList[[int]$selection - 1]
            $Commit = ($selectedLine -split ' ', 2)[0]
            Write-Status 'INFO' "Selected commit: $selectedLine"
        } else {
            Write-Status 'FAIL' "Invalid selection."
            return
        }
    }

    # Step 1: Cherry-pick to master
    Write-Host ""
    Write-Host "--- Step 1: Cherry-pick to master ---" -ForegroundColor Yellow
    $commitMsg = git log --oneline -1 $Commit 2>&1
    Write-Status 'INFO' "Cherry-picking: $commitMsg"

    $result = Invoke-CherryPickViaPR -Commit $Commit -TargetBranch 'master' -Description "hotfix/$Name"
    if (-not $result) {
        Write-Status 'FAIL' "Cherry-pick to master failed. Fix manually and continue with promote."
        return
    }

    # Step 2: Promote master forward to the environment below the hotfix
    if ($envIdx -gt 1) {
        $promoteTo = $script:Environments[$envIdx - 1]
        Write-Host ""
        Write-Host "--- Step 2: Promote master -> $promoteTo ---" -ForegroundColor Yellow

        if (-not $DryRun) {
            Sync-Branch -Branch 'master' | Out-Null
        }

        Invoke-Promote -FromEnv 'master' -ToEnv $promoteTo
    }

    Write-Host ""
    Write-Status 'OK' "Hotfix apply complete!"
    Write-Status 'INFO' "$Environment already has the fix (hotfix was merged there)."
    if ($envIdx -lt ($script:Environments.Count - 1)) {
        $nextEnv = $script:Environments[$envIdx + 1]
        Write-Status 'INFO' "$nextEnv will get the fix via the next regular promotion."
    }
}

function Show-BranchStatus {
    Write-Host ""
    Write-Host "=== Branch Sync Status ===" -ForegroundColor Cyan
    Write-Host ""

    # Fetch all branches
    Write-Status 'INFO' "Fetching all environment branches..."
    foreach ($branch in $script:Environments) {
        Sync-Branch -Branch $branch | Out-Null
    }
    Write-Host ""

    # Header
    $fmt = "{0,-20} {1,-20} {2}"
    Write-Host ($fmt -f "Branch", "vs Previous", "Status") -ForegroundColor White
    Write-Host ($fmt -f "------", "-----------", "------") -ForegroundColor Gray

    for ($i = 0; $i -lt $script:Environments.Count; $i++) {
        $branch = $script:Environments[$i]

        if ($i -eq 0) {
            Write-Host ($fmt -f $branch, "-", "base branch") -ForegroundColor Gray
            continue
        }

        $prev = $script:Environments[$i - 1]

        # Count commits ahead/behind using rev-list
        $counts = git rev-list --left-right --count "origin/$prev...origin/$branch" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host ($fmt -f $branch, "vs $prev", "error") -ForegroundColor Red
            continue
        }

        $parts = $counts -split '\s+'
        $ahead = [int]$parts[0]   # commits in prev not in branch (branch is behind)
        $behind = [int]$parts[1]  # commits in branch not in prev (branch is ahead)

        $statusParts = @()
        $color = 'Green'

        if ($ahead -gt 0) {
            $statusParts += "$ahead to promote"
            $color = 'Yellow'
        }
        if ($behind -gt 0) {
            $statusParts += "$behind to back-merge"
            $color = 'Yellow'
        }
        if ($ahead -eq 0 -and $behind -eq 0) {
            $statusParts += "in sync"
        }

        $statusStr = $statusParts -join ', '
        $vsStr = "vs $prev"

        Write-Host ($fmt -f $branch, $vsStr, $statusStr) -ForegroundColor $color
    }

    Write-Host ""
}

# ── Interactive Menu ───────────────────────────────────────────────────────────

function Select-Environment {
    param(
        [string]$Prompt,
        [string[]]$Exclude = @()
    )

    $available = $script:Environments | Where-Object { $_ -notin $Exclude }

    Write-Host ""
    Write-Host "  $Prompt" -ForegroundColor Yellow
    $idx = 0
    foreach ($env in $available) {
        $idx++
        Write-Host "    [$idx] $env" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Select (1-$idx): " -ForegroundColor Yellow -NoNewline
    $selection = Read-Host

    if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $idx) {
        return $available[[int]$selection - 1]
    }

    Write-Status 'FAIL' "Invalid selection."
    return $null
}

function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "=== Fincent Git Workflow ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  [1] Promote     - Push changes forward (master -> ... -> productie)" -ForegroundColor White
        Write-Host "  [2] Back-merge  - Sync back (productie -> ... -> master)" -ForegroundColor White
        Write-Host "  [3] Hotfix      - Create or apply a hotfix" -ForegroundColor White
        Write-Host "  [4] Status      - Show branch sync status" -ForegroundColor White
        Write-Host "  [Q] Quit" -ForegroundColor White
        Write-Host ""
        Write-Host "  Select: " -ForegroundColor Yellow -NoNewline
        $choice = Read-Host

        switch ($choice.ToUpper()) {
            '1' {
                $from = Select-Environment -Prompt "Promote FROM:" -Exclude @('productie')
                if (-not $from) { continue }
                $fromIdx = $script:Environments.IndexOf($from)
                $toOptions = $script:Environments[($fromIdx + 1)..($script:Environments.Count - 1)]
                $to = Select-Environment -Prompt "Promote TO:"
                if (-not $to) { continue }
                if ($script:Environments.IndexOf($to) -le $fromIdx) {
                    Write-Status 'FAIL' "Target must be after $from in the environment chain."
                    continue
                }
                Invoke-Promote -FromEnv $from -ToEnv $to
            }
            '2' {
                $from = Select-Environment -Prompt "Back-merge FROM:" -Exclude @('master')
                if (-not $from) { continue }
                $fromIdx = $script:Environments.IndexOf($from)
                $to = Select-Environment -Prompt "Back-merge TO:"
                if (-not $to) { continue }
                if ($script:Environments.IndexOf($to) -ge $fromIdx) {
                    Write-Status 'FAIL' "Target must be before $from in the environment chain."
                    continue
                }
                Invoke-BackMerge -FromEnv $from -ToEnv $to
            }
            '3' {
                Write-Host ""
                Write-Host "  [A] Create a new hotfix branch" -ForegroundColor White
                Write-Host "  [B] Apply a merged hotfix (cherry-pick + promote)" -ForegroundColor White
                Write-Host ""
                Write-Host "  Select: " -ForegroundColor Yellow -NoNewline
                $hotfixChoice = Read-Host

                switch ($hotfixChoice.ToUpper()) {
                    'A' {
                        $env = Select-Environment -Prompt "Create hotfix from environment:"
                        if (-not $env) { continue }
                        Write-Host "  Hotfix name (e.g. FIN-1234): " -ForegroundColor Yellow -NoNewline
                        $name = Read-Host
                        if (-not $name) {
                            Write-Status 'FAIL' "Hotfix name is required."
                            continue
                        }
                        Invoke-HotfixCreate -Name $name -Environment $env
                    }
                    'B' {
                        $env = Select-Environment -Prompt "Hotfix was merged to which environment:" -Exclude @('master')
                        if (-not $env) { continue }
                        Write-Host "  Hotfix name: " -ForegroundColor Yellow -NoNewline
                        $name = Read-Host
                        if (-not $name) {
                            Write-Status 'FAIL' "Hotfix name is required."
                            continue
                        }
                        Invoke-HotfixApply -Environment $env -Name $name
                    }
                    default {
                        Write-Status 'WARN' "Invalid choice."
                    }
                }
            }
            '4' {
                Show-BranchStatus
            }
            'Q' {
                Write-Host "Bye!" -ForegroundColor Cyan
                return
            }
            default {
                Write-Status 'WARN' "Invalid choice."
            }
        }
    }
}

# ── Entry Point ────────────────────────────────────────────────────────────────

Assert-Prerequisites
Assert-CleanWorkingTree

switch ($Action) {
    'promote' {
        if (-not $From) {
            Write-Status 'FAIL' "-From is required for promote."
            exit 1
        }
        if (-not $To) {
            Write-Status 'FAIL' "-To is required for promote."
            exit 1
        }
        Invoke-Promote -FromEnv $From -ToEnv $To
    }
    'backmerge' {
        if (-not $From) {
            Write-Status 'FAIL' "-From is required for backmerge."
            exit 1
        }
        if (-not $To) {
            Write-Status 'FAIL' "-To is required for backmerge."
            exit 1
        }
        Invoke-BackMerge -FromEnv $From -ToEnv $To
    }
    'hotfix-create' {
        if (-not $From) {
            Write-Status 'FAIL' "-From (environment) is required for hotfix-create."
            exit 1
        }
        if (-not $HotfixName) {
            Write-Status 'FAIL' "-HotfixName is required for hotfix-create."
            exit 1
        }
        Invoke-HotfixCreate -Name $HotfixName -Environment $From
    }
    'hotfix-apply' {
        if (-not $From) {
            Write-Status 'FAIL' "-From (environment where hotfix was merged) is required for hotfix-apply."
            exit 1
        }
        if (-not $HotfixName) {
            Write-Status 'FAIL' "-HotfixName is required for hotfix-apply."
            exit 1
        }
        Invoke-HotfixApply -Environment $From -Name $HotfixName -Commit $CommitHash
    }
    'status' {
        Show-BranchStatus
    }
    'menu' {
        Show-Menu
    }
}
