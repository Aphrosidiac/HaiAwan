---
name: obsidian
description: Read, search, create and edit notes in the user's Obsidian vault — a local folder of Markdown files set in Awan's Integrations. Handles wikilinks, tags, front matter, daily notes and backlinks. Use only when the vault path is configured (OBSIDIAN_VAULT_PATH).
---

# Obsidian vault

The vault is a plain folder of Markdown files on this Mac. Awan passes its path as
`OBSIDIAN_VAULT_PATH` and in your instructions ("Obsidian vault path: …").

- That path is the only vault root. Don't search the disk for other vaults.
- If it isn't set, tell the user to choose their vault in **Awan → Settings → Integrations →
  Obsidian**, and stop the vault part of the task.
- No Obsidian account, plugin API or sign-in is involved — just files.
- Paths may contain spaces: always quote them. Resolve the variable once and use the literal absolute
  path in commands.

## Find and read

```bash
rg --files "$OBSIDIAN_VAULT_PATH" -g '*.md' | head -200        # list notes
rg -n -i "query" "$OBSIDIAN_VAULT_PATH" -g '*.md'               # search content
rg -l "\[\[Note Name(\|[^]]*)?\]\]" "$OBSIDIAN_VAULT_PATH"     # backlinks to a note
```

Read only the notes the task needs. Skip `.obsidian/`, `.trash/` and attachment folders.

## Write

- Create or edit notes only when the user asked for a note, an edit, or a clean-up.
- Keep YAML front matter, `[[wikilinks]]`, `![[embeds]]`, `#tags`, block ids (`^id`) and callouts
  (`> [!note]`) intact. Match the note's existing style.
- Link related notes with `[[Note Name]]` (the filename without `.md`); add an alias with
  `[[Note Name|shown text]]`.
- Targeted edits: change the smallest span. For "add under heading X", insert after that heading's
  section rather than rewriting the file.
- Daily notes: follow the vault's existing pattern (look at recent files — e.g. `Daily/2026-09-29.md`).
  If there's no pattern, ask before inventing one.
- Readable, stable filenames; don't rename or move notes unless asked (renames break links unless you
  update them everywhere).

## Ask first

Deleting notes, bulk moves or renames, large rewrites, and anything under `.obsidian/`
(settings, plugins, themes).

## Finish

List the notes you read or changed, relative to the vault, and keep the summary short.
