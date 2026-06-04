# Codex Project Rules

## Highest Priority: Next-Step Prompt Loop

- After every non-final response, first deliver the result, then call `$env:USERPROFILE\.codex\next-step\ask_next_step.ps1`.
- The outer command must use `timeout_ms >= 86400000`; do not use the default 10-second timeout or a short 10-minute timeout.
- Pass a stable user-facing `-DialogName` and dynamic `-OptionsJson` for the current turn. Do not hard-code the same four options, do not prefill the previous answer, and do not make "end/pause" a checkbox option.
- `-DialogName` is shown in the title `下一步选项（...）`. Use a readable conversation title and keep it stable within the thread.
- Only stop when the custom input explicitly says the conversation should end or pause. Otherwise, treat `selected` and `custom_answer` as the next task, execute it, then ask again.
- If returned JSON includes `attachments`, inspect those local image paths before continuing.
