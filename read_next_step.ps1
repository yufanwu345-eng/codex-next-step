# -*- coding: utf-8 -*-
<#
Purpose:
  Read the last next-step choice produced by ask_next_step.ps1.

Output:
  The raw JSON content from last_choice.json.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$ToolDir = Split-Path -Parent $PSCommandPath
$JsonPath = Join-Path $ToolDir "last_choice.json"

if (-not (Test-Path -LiteralPath $JsonPath)) {
    [ordered]@{
        status = "missing"
        selected = @()
        custom_answer = ""
        submitted_at = ""
    } | ConvertTo-Json -Depth 8
    exit 0
}

Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8

