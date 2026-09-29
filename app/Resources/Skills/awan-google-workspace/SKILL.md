---
name: awan-google-workspace
description: Work in the user's Gmail, Google Calendar, Drive, Docs and Sheets through Awan's Google connectors — search and read, create and edit docs and sheets, find free time and schedule events, share and organise files, export to text. Use whenever a task touches the user's Google Workspace data rather than the public web.
---

# Awan Google Workspace

Google Workspace reaches you as separate MCP servers that Awan itself hosts, one per app the user
connected in **Awan → Settings → Integrations**: `gmail`, `google-calendar`, `google-drive`,
`google-docs`, `google-sheets`. They already run as the user's Google account — never ask for
tokens, passwords or API keys. Check your tool list for which ones are present.

## Tools

- **gmail** — `search_messages`, `get_message`, `list_labels`, `modify_labels`, `create_draft`,
  `reply_draft`, `send_draft`. Mail work follows `awan-email-assistant`.
- **google-calendar** — `list_calendars`, `list_events`, `find_free_time`, `create_event`,
  `update_event`, `delete_event`.
- **google-drive** — `search_files`, `get_file_metadata`, `download_text`, `upload_file`,
  `share_file`, `move_file`.
- **google-docs** — `create_document`, `get_document_text`, `append_text`, `replace_text`.
- **google-sheets** — `create_spreadsheet`, `get_values`, `append_rows`, `update_values`,
  `add_sheet`.

Call them with the exact argument names from their schemas (`spreadsheet_id`, `document_id`,
`file_id`, `calendar_id`, `event_id`…). Find a Doc or Sheet by name with `google-drive` →
`search_files`; its `id` is the `document_id` / `spreadsheet_id`.

## Route

1. The matching server is present → use it.
2. It's missing, or a call says "isn't connected" / "access was revoked" → name the specific app
   ("Google Sheets isn't connected yet — press Connect next to it in Awan → Settings →
   Integrations") and stop that part. Don't run OAuth, `gcloud`, or a browser sign-in yourself.
3. Clicking through Docs/Sheets/Gmail in a browser (`computer-use`) only when the user explicitly
   wants that route or accepts it as a fallback.
4. "Too many Google calls" → wait a minute and continue with fewer, larger calls (bigger ranges,
   higher `max_results`).

## Approval

- Reads are fine once connected.
- Writes the user asked for — edit a doc, append rows, create an event, share with someone they
  named — just do them. The request is the approval.
- Ask first only for: `delete_event` they didn't ask for, overwriting content they didn't ask you to
  replace (`update_values`, `replace_text`), `share_file` with type `anyone`, inviting attendees
  (`send_updates: "all"`) they didn't name, and anything that costs money.

## Write, then read back

A "success" response isn't proof. After every write, read the result back:
- **Docs**: `create_document` / `append_text` / `replace_text` → `get_document_text` and confirm the
  body is really there; `replace_text` reports `occurrencesChanged` — 0 means nothing matched.
- **Sheets**: write rectangular 2-D arrays to an explicit A1 range (quote tabs with spaces:
  `'Q3 Sales'!A1`). When replacing a longer table, use a fresh tab (`add_sheet`) or overwrite the
  whole old range. Then `get_values` and check headers, row and column counts and one sample cell.
- **Calendar**: before booking, `find_free_time` (with `working_hours` for "during the day"). After
  `create_event` / `update_event`, `list_events` over that window and confirm date, time zone,
  attendees and title. Say times in the user's time zone.
- **Drive**: after `upload_file` / `move_file` / `share_file`, `get_file_metadata` and confirm the
  parent folder and permissions.

## Local files

`download_text` gives Docs as text, Sheets as CSV (first tab only — use `get_values` for other
tabs) and text files as-is; PDFs and images are refused. Save exports under
`output/google/<slug>/`; use `spreadsheet`, `doc` and `pdf` for local work and give the absolute
paths as `File:` lines. To put a local file into Drive, base64 it into `upload_file` (≤ 20 MB,
`convert_to_google: true` for an editable Doc/Sheet).
