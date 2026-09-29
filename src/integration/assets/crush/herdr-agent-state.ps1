# installed by herdr
# managed by herdr; reinstalling or updating the integration overwrites this file.
# add custom hooks beside this file instead of editing it.
# HERDR_INTEGRATION_ID=crush
# HERDR_INTEGRATION_VERSION=1

param([string]$Action = "")

if ($Action -ne "session") { exit 0 }
if ($env:HERDR_ENV -ne "1") { exit 0 }
if ([string]::IsNullOrWhiteSpace($env:HERDR_PANE_ID)) { exit 0 }

$inputText = [Console]::In.ReadToEnd()
try {
    $payload = if ([string]::IsNullOrWhiteSpace($inputText)) { $null } else { $inputText | ConvertFrom-Json }
} catch {
    exit 0
}

# Crush only exposes PreToolUse; it has no session-start or turn-end hook,
# so this integration reports session identity only. Agent state stays with
# Herdr's screen detection.
if ($payload.event -ne "PreToolUse") { exit 0 }
if ([string]::IsNullOrWhiteSpace($payload.session_id)) { exit 0 }

$seq = [DateTimeOffset]::UtcNow.Ticks
$herdr = if ([string]::IsNullOrWhiteSpace($env:HERDR_BIN_PATH)) { "herdr" } else { $env:HERDR_BIN_PATH }
try {
    & $herdr pane report-agent-session $env:HERDR_PANE_ID `
        --source "herdr:crush" `
        --agent "crush" `
        --seq "$seq" `
        --agent-session-id "$($payload.session_id)" 2>$null | Out-Null
} catch {
}
