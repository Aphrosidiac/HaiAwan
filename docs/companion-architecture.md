# The voice companion

How Awan hears you, thinks, answers and acts when you hold **Control + Option** (or double-tap **Control** and type).

## The shape

```
hold keys ──► mic + on-device speech-to-text ──┐
          ──► screenshots of every display ────┤   (captured when you start talking)
          ──► the front window's document ─────┤   (read in parallel, 2.5 s budget)
          ──► what you circle while talking ───┘

release ──► ONE ongoing conversation (CompanionConversation)
            ├─ silent context notes, only when they changed:
            │    [time] [app] [awans] [awan progress] [home] [suggestions] [open document] [drawing]
            ├─ screenshots, only when the screen changed since the model last saw it
            └─ your words
                    │
                    ▼
        POST /v1/companion/turn   (one streamed model round: text + tool calls)
                    │
          speech starts on the first sentence
                    │
          tool calls run on the Mac (CompanionTools) ──► results go back into the conversation ──► next round
                    │
          ask_deeper ──► POST /v1/companion/deeper (frontier vision model: full screenshots, whole document,
                         your drawing) ──► points, draws, arms a walkthrough target, types, shows pictures,
                         or starts an Awan; the voice model then says the answer in its own voice
```

Two models, like a person with a sharp friend on call:

- **The voice model** (`VOICE_MODEL`, fast) holds the conversation. It answers anything it can in a sentence or two,
  and it decides what to do: look closer, look again, start or steer an Awan, search the web, remember something,
  type, copy, open.
- **The deeper pass** (`COMPANION_MODEL`, frontier vision) is called through `ask_deeper` for anything that depends on
  exactly what or where something is on screen, on the open document, or on harder reasoning. It owns the
  pointing/drawing/typing tag protocol (see `app/Sources/Awan/Companion/CompanionTags.swift`). Its visuals are timed to
  the sentences the voice model speaks next.

## One conversation, remembered

`CompanionConversation` keeps every user turn, reply, tool call, tool result, screenshot and note of the current
session. That is why "and what's it called?", "tell it to add a section", "which one was cheapest?" and "do that
again" work.

- A session that sits idle for 20 minutes is rebuilt on the next turn. The new session starts with an
  **[earlier conversation]** note, the plain transcript of what was said (up to 24 lines, with times), so the
  thread carries on without old screenshots and tool chatter.
- The transcript is kept on disk (`HomeSpaceCache/companion-transcript.json`, last 40 lines, a week at most), so a
  relaunch doesn't wipe it. Signing out or deleting the account clears it.
- Durable facts go to `Memory/PROFILE.md` through the `remember` tool. Every Awan reads that file too.
- Only the two newest screenshot submissions carry pixels in a request. Older ones become a one-line placeholder.

## Context notes

Notes are facts about the moment, sent as bracketed messages the instructions tell the model never to answer on
their own. Each is re-sent only when it changed:

| Note | What it says |
|---|---|
| `[time]` | local date and time; "treat it as now" (every turn) |
| `[app]` | the front app and its window title |
| `[awans]` | every Awan by `awan_slug`: job, what it's doing, what it's waiting on (PENDING REQUEST), the MOST RECENT REPORT, and whose chat you JUST LOOKED AT, so a follow-up with no name goes to the right one |
| `[awan progress]` | what working Awans said since your last turn |
| `[home]` | Home is open; if you're looking at one Awan's chat, your words go to that Awan and Awan stays silent |
| `[suggestions]` | the suggestion cards on screen, with ids, for "yes, do it" / "next" |
| `[open document]` | a document is open and its full text is with the deeper pass |
| `[drawing]` | what you circled, scribbled or lined while talking, where on which screen, and what Accessibility says is under it |
| `[attachments]` | files dropped on the mascot, with their paths and how to route them: up to two small images are seen directly; anything else goes to an Awan with the files (reading tools are withheld that turn) |
| `[voice style, this turn]` | the one-beat preamble ("one sec.", "okay.", or silence) allowed before a slow tool; never talk between tool calls |
| `[awan update]` | an Awan finished or needs you (spoken in Awan's own words, or kept silently if you were busy) |
| `[walkthrough]` | the next step after you clicked a walkthrough target |
| `[earlier conversation]` | the transcript that seeds a new session |

## Tools

| Tool | Does |
|---|---|
| `ask_deeper` | the deeper pass (see above) |
| `look_at_screen` | fresh screenshots, attached right after the result |
| `start_awan_task` | real work to the Awan whose job fits, or founds a new Awan (`new_awan`); wraps the task in a `<voice_handoff>` with your words and the recent conversation |
| `message_awan` / `stop_awan` | follow up with, or stop, an Awan |
| `awans_status` / `awan_memory` | what the Awans are doing, made, know (AGENTS.md notes + recent chat) |
| `answer_awan_request` | yes / no / always for an Awan waiting on you |
| `open_file` / `open_home` | open or reveal what an Awan made; open or close Home |
| `web_search` | a short sourced answer in local units (`POST /v1/companion/search`) |
| `remember` | a durable fact into `Memory/PROFILE.md` (never secrets) |
| `type_text` / `copy_to_clipboard` | type into the focused field (refuses password fields and blind pastes) or copy |
| `open_link` | open a URL |
| `read_file` / `list_files` | read-only file access (keys, keychains, `.env` and friends are refused) |
| `account_status` | plan, usage, permissions, shortcuts |
| `decide_suggestion` | approve or skip a suggestion on screen |

Speech: the first model round streams to the voice at once; rounds after a tool result are spoken only when they end
the turn, so narration that only leads into another tool call stays unspoken.

Rules the loop enforces: at most 6 tool calls and 8 model rounds per turn (then the model must answer with what it
has), a new turn cancels the old one, and any unanswered tool call gets a "cancelled" result so the conversation stays
well-formed. If you cut Awan off, what it had already said stays in the conversation.

## Silence is not a question

Holding the keys and saying nothing does nothing:

- On-device speech recognition is the transcriber. If it ran and heard no words, that is the answer, and the audio
  never goes to the server.
- The server transcriber is only a fallback for when on-device recognition can't run, and only when the mic level
  shows speech. The server also refuses audio whose loudest 50 ms is below −46 dBFS, and its prompt returns
  `[no speech]` for noise. (Audio models given silence invent words; ours echoed the spelling hints back as "Hai Awan",
  which Awan then answered.)
- A transcript of only filler ("um", "uh") is dropped. A real hold with no words gets one quiet line on the notch
  ("I didn't catch that"), never a spoken reply.

## Testing

```bash
.build/debug/Awan --voice-selftest                         # pure checks: conversation, notes, gate, hand-off, file guard
AWAN_TOKEN=… .build/debug/Awan --voice-live --fake-screen "where's the export button?" "and what's the page called?"
```

`--voice-live` runs a real multi-turn conversation through `CompanionEngine` against the API, headless and silent, with
every side-effect tool in dry-run. It prints each turn's notes, tool calls, results, reply and timing. Turns can also be
`@update <slug> <summary>` (an Awan finished), `@home <slug>` / `@home-close`.

Server: `npm test` in `server/` covers the turn stream, tool filtering, conversation sanitising, the deeper pass, search
and the silence gate (`test/companion.test.ts`).
