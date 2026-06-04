# -*- coding: utf-8 -*-
<#
Install Codex Next Step to the current user's Codex home.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $HOME ".codex\next-step")
)

$ErrorActionPreference = "Stop"
$SourceDir = Split-Path -Parent $PSCommandPath

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "attachments") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "choices") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir "prompts") | Out-Null

Copy-Item -LiteralPath (Join-Path $SourceDir "ask_next_step.ps1") -Destination (Join-Path $InstallDir "ask_next_step.ps1") -Force
Copy-Item -LiteralPath (Join-Path $SourceDir "read_next_step.ps1") -Destination (Join-Path $InstallDir "read_next_step.ps1") -Force
Copy-Item -LiteralPath (Join-Path $SourceDir "AGENTS_TEMPLATE.md") -Destination (Join-Path $InstallDir "AGENTS_TEMPLATE.md") -Force

Write-Host "Installed Codex Next Step to: $InstallDir"
Write-Host "Add AGENTS_TEMPLATE.md rules to your project or global AGENTS.md, then call ask_next_step.ps1 after each delivery."
