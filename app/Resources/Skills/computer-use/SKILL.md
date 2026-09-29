---
name: computer-use
description: Operate native Mac apps and browser windows in the background through Awan's local `computer-use` MCP server — snapshot a window's accessibility tree, act on elements by token, verify by re-snapshotting. Use only for real GUI work (a native app, or a web page with no API/connector route), never as a substitute for a connector the user hasn't connected.
---

# Computer use

Awan runs a small MCP server named `computer-use` inside the Awan app. Its tools
see and operate other apps **in the background**: the user keeps typing in their
own app while you work in another window. Call the tools directly by name. Never
drive the GUI through `open`, `osascript`/AppleScript, `cliclick`, or other shell
shims — they steal focus and bypass the user's consent.

## Pick the route first

1. Files, CLI, web fetch or an API can do it → do that; no GUI.
2. A connected integration (another MCP server in your tool list) covers the app →
   use it. If the app *should* have a connector but it isn't connected, say so and
   tell the user to connect it in **Awan → Settings → Integrations**. Don't click
   through their account in its place, and never operate Awan's own Settings.
3. Real GUI work in a native app, or a page that only works in a browser → this skill.

## Consent

- Observation tools always work: `check_permissions`, `list_apps`, `list_windows`,
  `get_window_state`, `page` (screenshot / get_text), `get_screen_size`,
  `get_config`, `health_report`.
- Input tools (`launch_app`, `click`, `right_click`, `type_text`, `set_value`,
  `press_key`, `hotkey`, `scroll`, `page` execute_javascript) are refused until the
  user approves computer use for this turn. If one is refused: don't retry and
  don't work around it. Do everything that doesn't need the screen, then end your
  reply with
  `<COMPUTER_USE_REQUEST>what you'd do, in which app, and why</COMPUTER_USE_REQUEST>`.
  Awan shows the user an Allow / Not now card. A turn that starts with
  "[Computer use approved for this turn]" may use input tools.
- Even when approved, stop and ask before anything irreversible: sending,
  posting, purchasing, deleting, submitting a form, changing account settings.

## The loop

```
launch_app({bundle_id})            → pid + windows[]   (idempotent; reuses a running app)
get_window_state({window_id})      → tree with [s12e4] tokens + screenshot
click({element_token: "s12e4", delivery_mode: "background"})
get_window_state({window_id})      → verify: did the tree change the way you expected?
```

- **Snapshot before and after every action.** Each `get_window_state` of a window
  replaces that window's tokens; an old token fails with "stale element token".
  Re-snapshot and pick the fresh one.
- Name the window. `get_window_state({pid})` alone picks the pid's frontmost
  window; prefer `window_id` from `launch_app` / `list_windows`.
- Read both halves: the tree says what is clickable, the screenshot says which one
  (repeated "OK" buttons, unlabeled icons, web content the tree only sketches).
- Big trees: pass `query` (substring on role/label/value), `max_elements`, or
  `max_depth` instead of paging through hundreds of lines.

### Reading results honestly

Every action returns `path` (`ax`, `ax_scrollbar`, `cgevent`, `pixel`), `verified`,
and `effect`:
- `confirmed` + `verified: true` — Awan read the change back. Real evidence.
- `unverifiable` — normal for key presses, pixel clicks and web content. The
  post-action snapshot is your proof.
- `suspected_noop` / `element_gone` — treat as failed or changed; re-snapshot.

If nothing changed, the action failed. Say what you tried and what you saw —
never report "done" on an unverified action.

## Acting

| Intent | Call |
|---|---|
| Press a button, link, menu item, row | `click({element_token})` (AXPress, background) |
| Double-click / open an item | `click({element_token, action: "open"})` or `count: 2` |
| Context menu | `right_click({element_token})` |
| Replace a field's whole value, move a slider, tick a checkbox | `set_value({element_token, value})` |
| Type at the caret | `type_text({element_token, text})` |
| Return / Tab / Escape / arrows | `press_key({element_token or window_id, key, modifiers?})` |
| Shortcut (copy, save, new window) | `hotkey({window_id, keys: ["cmd","s"]})` |
| Scroll a list or page | `scroll({element_token, direction: "down", amount: 5})` |
| Target has no element (canvas, video) | `click({window_id, x, y})` — pixels read off **this** window's latest screenshot |

Every input call takes `delivery_mode: "background"` (the only allowed value).
Pixel coordinates are image pixels from the latest `get_window_state` of that
window — never element frames, never screen coordinates. `scope: "desktop"` is
refused because it would move the user's real pointer.

Refused shortcuts (they steal focus or flip the user's tabs even in the
background): cmd/ctrl+L, cmd+shift+G, cmd+1…9, cmd+[ / cmd+], cmd+option+←/→,
ctrl+tab, cmd+tab, cmd+`, cmd+space, ctrl+arrows.

## Browsers: work in your own window

- Never click, type or navigate in the user's existing tabs. Their windows are
  read-only context: you may snapshot one to read it.
- Open your own window in their default browser:
  `launch_app({bundle_id: "com.google.Chrome", creates_new_application_instance: true, additional_arguments: ["--new-window", "https://…"]})`
  (Chrome, Arc, Brave, Edge, Dia and other Chromium browsers). Plain `urls: [...]`
  on a running Chromium browser opens a tab in the user's active window — don't.
  Safari only takes `urls`, which may land as a tab; say so if it does.
- Pick your window from the returned `windows` (title matches your page), then
  drive it by `window_id`. Tell the user in one clause that you used a separate
  window they can close.
- To go to another URL, open another window the same way; don't use the address bar.
- Web content's accessibility tree is often sparse on the first snapshot — take a
  second one. For text the tree drops, use `page({window_id, action: "get_text"})`.
  `page` `execute_javascript` works in Safari and Chrome-family browsers when the
  user has enabled "Allow JavaScript from Apple Events"; don't ask them to change
  that setting just for you.
- Web fields often echo an AX write they never applied (`unverifiable`). Confirm by
  re-snapshot or `get_text`.

## Native apps

- "Open X" means `launch_app`, never `open -a`. Launching doesn't bring the app
  forward; if the user wants it in front, tell them to click it in the Dock.
- Menu bars belong to the frontmost app; don't drive a background app's menu bar.
  Use in-window buttons, toolbars, or shortcuts.
- Minimized windows ignore Return/Space commits: use `set_value` or click the
  commit button instead.
- Drag-and-drop, drawing and multi-touch aren't available. Say so rather than
  faking it.

## When things go wrong

- `check_permissions` says Accessibility or Screen Recording is off → stop and ask
  the user to allow Awan in System Settings → Privacy & Security. Awan never
  raises those prompts itself.
- No windows for a pid → `launch_app` it (with `urls` if it needs a document).
- Anything systemic → one `health_report` call, then explain.
- Quitting an app or closing a window the user didn't ask about → ask first.
