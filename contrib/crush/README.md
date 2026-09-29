# Crush integration for Herdr

Reports [Crush](https://github.com/charmbracelet/crush) as a first-class
agent inside [Herdr](https://herdr.dev): the pane shows `crush` with a
working state on tool calls, and `herdr agent list` / `herdr agent wait`
see it.

What it does NOT do (yet): native session restore and idle/blocked
reporting. Crush currently only offers a `PreToolUse` hook, so there is
no turn-end event to report `idle` and no session-start event to pin a
resume command. Herdr's screen detection keeps handling those.

## Install

Copy the hook and register it in your global crushrc:

```sh
mkdir -p ~/.config/crush/hooks
cp contrib/crush/herdr-report.sh ~/.config/crush/hooks/
chmod +x ~/.config/crush/hooks/herdr-report.sh
```

Append to `~/.config/crush/crushrc`:

```bash
hook add PreToolUse \
  --command "$HOME/.config/crush/hooks/herdr-report.sh" \
  --name herdr-report \
  --timeout 5
```

Then start (or restart) Crush inside a Herdr pane and check:

```sh
herdr agent list
herdr agent wait <pane-id> --until working --timeout 5000
```

## Behavior

- Strict no-op outside Herdr (`HERDR_ENV`, `HERDR_PANE_ID`,
  `HERDR_BIN_PATH` must all be set).
- Reports `working` through `herdr pane report-agent` with
  `--source crush`, `--agent crush`, the Crush session id, and a
  millisecond-epoch `--seq`.
- Rate limited: reports only when the tool name changes within a
  session (state kept under `~/.cache/crush-herdr/<session-id>`), so a
  long run of same-tool calls does not hit the socket.
- Fire-and-forget with a 3 s timeout; Herdr being down never slows or
  fails a tool call.

## Where a native integration belongs

Per Herdr's [Add Herdr support to your agent](https://herdr.dev/docs/add-herdr-support/)
guide, agent-side integrations need no PR. To make Crush fully native
(`herdr integration install crush` with session restore), the change
would go upstream to herdrdev/herdr, which owns the built-in
integration layer; Crush itself only needs to keep exposing hooks.
