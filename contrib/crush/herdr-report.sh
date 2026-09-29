#!/usr/bin/env bash

# Crush → Herdr agent-state reporter.
#
# Reports Crush as agent "crush" with state "working" on tool calls while
# Crush runs inside a Herdr pane. Outside Herdr it is a strict no-op.
# Idle and blocked detection stays with Herdr's screen detection: Crush has
# no turn-end hook, so this source never reports idle/blocked itself.
#
# Rate limiting: only reports when the tool name changes within a session,
# so a long run of same-tool calls does not spam the Herdr socket. A new
# session (or a new session id) always reports once.
#
# Registered via crushrc:
#   hook add PreToolUse --command "$HOME/.config/crush/hooks/herdr-report.sh" \
#     --name herdr-report --timeout 5
#
# Protocol: https://herdr.dev/docs/add-herdr-support/
set -u

if [[ "${HERDR_ENV:-}" != "1" || -z "${HERDR_PANE_ID:-}" || -z "${HERDR_BIN_PATH:-}" ]]; then
	exit 0
fi

command -v perl >/dev/null 2>&1 || exit 0

# Millisecond epoch; increases across hook runs, Herdr drops older seqs.
seq=$(perl -MTime::HiRes=time -e 'printf "%d", time() * 1000' 2>/dev/null) || exit 0
[ -n "$seq" ] || exit 0

tool=${CRUSH_TOOL_NAME:-unknown}
session=${CRUSH_SESSION_ID:-nosession}

# Skip when this session already reported the same tool name.
state_dir=${XDG_CACHE_HOME:-$HOME/.cache}/crush-herdr
state_file=$state_dir/$session
if [[ -f "$state_file" ]] && IFS= read -r last_tool <"$state_file" 2>/dev/null \
	&& [[ "$last_tool" == "$tool" ]]; then
	exit 0
fi

# Fire-and-forget with a hard timeout so the report never slows the tool
# call down; failures (server down, socket missing) are silently ignored.
(
	timeout 3 "$HERDR_BIN_PATH" pane report-agent "$HERDR_PANE_ID" \
		--source crush \
		--agent crush \
		--state working \
		--seq "$seq" \
		${CRUSH_SESSION_ID:+--agent-session-id "$CRUSH_SESSION_ID"} \
		>/dev/null 2>&1
) </dev/null >/dev/null 2>&1 &

mkdir -p "$state_dir" 2>/dev/null || exit 0
printf '%s\n' "$tool" >"$state_file" 2>/dev/null

# No output and exit 0 = no opinion; Crush proceeds normally.
exit 0
