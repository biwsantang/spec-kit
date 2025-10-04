#!/usr/bin/env pwsh
# Create a new feature
[CmdletBinding()]
param(
    [switch]$Json,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FeatureDescription
)
$ErrorActionPreference = 'Stop'

if (-not $FeatureDescription -or $FeatureDescription.Count -eq 0) {
    Write-Error "Usage: ./create-new-feature.ps1 [-Json] <feature description>"
    exit 1
}
$featureDesc = ($FeatureDescription -join ' ').Trim()

# Check if we're in a worktree structure
function Test-WorktreeStructure {
    param([string]$CurrentDir)

    $parentDir = Split-Path $CurrentDir -Parent
    $grandparentDir = Split-Path $parentDir -Parent

    # Check if we're in workspace/source/ or workspace/worktree/[branch]/
    if ((Split-Path $parentDir -Leaf) -eq "workspace" -and (Split-Path $CurrentDir -Leaf) -eq "source") {
        return "source"
    } elseif ((Split-Path $grandparentDir -Leaf) -eq "workspace" -and (Split-Path $parentDir -Leaf) -eq "worktree") {
        return "worktree"
    }
    return $null
}

# Migrate existing repo to worktree structure
function Move-ToWorktreeStructure {
    param([string]$RepoRoot)

    $workspaceDir = Join-Path (Split-Path $RepoRoot -Parent) "workspace"
    $sourceDir = Join-Path $workspaceDir "source"
    $worktreeDir = Join-Path $workspaceDir "worktree"

    Write-Output "Migrating to worktree structure..."

    # Create workspace structure
    New-Item -ItemType Directory -Path $workspaceDir -Force | Out-Null
    New-Item -ItemType Directory -Path $worktreeDir -Force | Out-Null

    # Move current repo to source
    Move-Item $RepoRoot $sourceDir -Force

    Write-Output "Migration complete. Repository moved to $sourceDir"
    return $sourceDir
}

# Resolve repository root and handle worktree structure
function Find-RepositoryRoot {
    param(
        [string]$StartDir,
        [string[]]$Markers = @('.git', '.specify')
    )
    $current = Resolve-Path $StartDir
    while ($true) {
        foreach ($marker in $Markers) {
            if (Test-Path (Join-Path $current $marker)) {
                return $current
            }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) {
            # Reached filesystem root without finding markers
            return $null
        }
        $current = $parent
    }
}
$fallbackRoot = (Find-RepositoryRoot -StartDir $PSScriptRoot)
if (-not $fallbackRoot) {
    Write-Error "Error: Could not determine repository root. Please run this script from within the repository."
    exit 1
}

try {
    $repoRoot = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0) {
        $hasGit = $true
    } else {
        throw "Git not available"
    }
} catch {
    $repoRoot = $fallbackRoot
    $hasGit = $false
}

# Determine current context and handle migration
$worktreeType = Test-WorktreeStructure $repoRoot
if ($worktreeType) {
    # Already in worktree structure
    if ($worktreeType -eq "source") {
        $sourceDir = $repoRoot
        $workspaceDir = Split-Path $repoRoot -Parent
    } else {
        # We're in a feature worktree, find the source
        $workspaceDir = Split-Path (Split-Path $repoRoot -Parent) -Parent
        $sourceDir = Join-Path $workspaceDir "source"
    }
} else {
    # Need to migrate
    if (-not $hasGit) {
        Write-Error "Error: Git worktrees require a git repository. Please initialize git first."
        exit 1
    }
    $sourceDir = Move-ToWorktreeStructure $repoRoot
    $workspaceDir = Split-Path $sourceDir -Parent
}

Set-Location $sourceDir

$specsDir = Join-Path $sourceDir 'specs'
New-Item -ItemType Directory -Path $specsDir -Force | Out-Null

$highest = 0
if (Test-Path $specsDir) {
    Get-ChildItem -Path $specsDir -Directory | ForEach-Object {
        if ($_.Name -match '^(\d{3})') {
            $num = [int]$matches[1]
            if ($num -gt $highest) { $highest = $num }
        }
    }
}
$next = $highest + 1
$featureNum = ('{0:000}' -f $next)

$branchName = $featureDesc.ToLower() -replace '[^a-z0-9]', '-' -replace '-{2,}', '-' -replace '^-', '' -replace '-$', ''
$words = ($branchName -split '-') | Where-Object { $_ } | Select-Object -First 3
$branchName = "$featureNum-$([string]::Join('-', $words))"

$worktreePath = Join-Path $workspaceDir "worktree" $branchName

if ($hasGit) {
    try {
        # Create worktree for the new feature branch
        git worktree add -b $branchName $worktreePath | Out-Null

        # Switch to the new worktree
        Set-Location $worktreePath
    } catch {
        Write-Warning "Failed to create git worktree: $branchName"
    }
} else {
    Write-Warning "[specify] Warning: Git repository not detected; skipped worktree creation for $branchName"
    New-Item -ItemType Directory -Path $worktreePath -Force | Out-Null
    Set-Location $worktreePath
}

$featureDir = Join-Path $worktreePath "specs" $branchName
New-Item -ItemType Directory -Path $featureDir -Force | Out-Null

$template = Join-Path $sourceDir '.specify/templates/spec-template.md'
$specFile = Join-Path $featureDir 'spec.md'
if (Test-Path $template) { 
    Copy-Item $template $specFile -Force 
} else { 
    New-Item -ItemType File -Path $specFile | Out-Null 
}

# Set the SPECIFY_FEATURE environment variable for the current session
$env:SPECIFY_FEATURE = $branchName

if ($Json) {
    $obj = [PSCustomObject]@{
        BRANCH_NAME = $branchName
        SPEC_FILE = $specFile
        FEATURE_NUM = $featureNum
        WORKTREE_PATH = $worktreePath
        HAS_GIT = $hasGit
    }
    $obj | ConvertTo-Json -Compress
} else {
    Write-Output "BRANCH_NAME: $branchName"
    Write-Output "WORKTREE_PATH: $worktreePath"
    Write-Output "SPEC_FILE: $specFile"
    Write-Output "FEATURE_NUM: $featureNum"
    Write-Output "HAS_GIT: $hasGit"
    Write-Output "SPECIFY_FEATURE environment variable set to: $branchName"
}
