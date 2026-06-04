# Codex Next Step

A lightweight Windows WPF next-step prompt for Codex Desktop. It lets an agent deliver a result, open a native-looking prompt, wait for the user's next instruction, return structured JSON, and continue the loop.

## Features

- Four dynamic checkbox options from `-OptionsJson`
- One custom instruction box
- Image attachments by drag-and-drop or `Ctrl+V`
- Structured JSON output
- Smooth fade-in and fade-out animations
- Long blocking wait for flow-state work sessions
- Keeps only the latest full response by default

## Requirements

- Windows
- Windows PowerShell 5.1
- Codex Desktop or another agent surface that can run PowerShell commands

## Install

```powershell
git clone https://github.com/yufanwu345-eng/codex-next-step.git
cd codex-next-step
.\install.ps1
```

The default install location is:

```text
%USERPROFILE%\.codex\next-step
```

Copy the rules from `AGENTS_TEMPLATE.md` into your project `AGENTS.md` or global Codex instructions.

## Wire It Into Codex

Add this rule near the top of your project or global instructions:

```text
After every non-final response, first deliver the result, then call
%USERPROFILE%\.codex\next-step\ask_next_step.ps1 with a stable -DialogName
and dynamic -OptionsJson. The outer tool timeout must be at least 86400000 ms.
Continue from the returned selected/custom_answer unless the custom answer
explicitly says to end or pause.
```

The prompt is intentionally blocking. This is what keeps the conversation alive until the user replies.

## Usage

```powershell
$options = '["Check current status","Continue editing","Handle figures or materials","Run code or data checks"]'
& "$env:USERPROFILE\.codex\next-step\ask_next_step.ps1" `
  -OptionsJson $options `
  -Message "Choose what to do next, or type a custom instruction" `
  -DialogName "Draft Review"
```

`-OptionsJson` can be either an array of strings or an array of objects with a `label` field:

```powershell
$options = @(
  @{ label = "Review status"; description = "Optional agent-side detail" },
  @{ label = "Run checks"; description = "Optional agent-side detail" }
) | ConvertTo-Json -Depth 5 -Compress
```

The tool writes and returns JSON like:

```json
{
  "status": "submitted",
  "selected": ["Check current status"],
  "custom_answer": "Also verify the latest chart.",
  "attachments": [],
  "dialog_name": "Draft Review",
  "choice_path": "C:\\Users\\you\\.codex\\next-step\\last_choice.json",
  "submitted_at": "2026-06-04T19:00:00+08:00"
}
```

When calling from Codex tool execution, set a long outer timeout such as `timeout_ms: 86400000`. Otherwise the caller may time out before the user submits the prompt.

Example agent-side call shape:

```json
{
  "command": "& \"$env:USERPROFILE\\.codex\\next-step\\ask_next_step.ps1\" -OptionsJson $options -DialogName \"Draft Review\"",
  "timeout_ms": 86400000
}
```

## Read Latest Choice

```powershell
& "$env:USERPROFILE\.codex\next-step\read_next_step.ps1"
```

## Optional Font

By default, the UI uses system fonts. To use a local font file:

```powershell
$env:CODEX_NEXT_STEP_FONT_PATH = "C:\Path\To\YourFont.ttf"
$env:CODEX_NEXT_STEP_FONT_FAMILY = "Your Font Family Name"
```

Do not redistribute proprietary fonts unless you have the right to do so.

## Privacy

Only `last_choice.json` keeps the latest full reply. Per-run choice files are temporary and are deleted after the parent process reads them. Logs store metadata such as counts and text length, not full custom text.

Use `-KeepChoiceHistory` if you need full per-run JSON files for debugging.

Runtime files are ignored by `.gitignore`, so accidental commits should not include prompts, choices, attachments, logs, screenshots, or the latest answer.

## Test

```powershell
$options = '["Test option A","Test option B","Test option C","Test option D"]'
& .\ask_next_step.ps1 -Mode test-submit -OptionsJson $options -DialogName "Test"
& .\ask_next_step.ps1 -Mode test-empty -OptionsJson $options -DialogName "Test"
```

## License

MIT
