---
name: frontend-design
description: Taste and craft rules for any interface you build or polish — websites, landing pages, web apps, dashboards, components, HTML prototypes — covering layout, type, colour, copy, states, responsiveness and motion. Use alongside awan-build-preview whenever the result will be looked at by a person.
---

# Frontend design

Build interfaces that look decided, not generated. Working first, then polish, then motion — and only
the motion that earns its place.

## Start from the domain

- Tools, dashboards, admin and ops screens: quiet, dense, scannable. Neutral surfaces, one accent,
  tables that align, numbers in tabular figures.
- Marketing pages, portfolios, launches: one strong idea, big confident type, generous space, real
  imagery or none.
- Reuse the project's framework, components and tokens when they exist. Don't import a UI kit for a
  one-pager.

## The tells of a generated UI — never ship these

- Purple/blue gradients, glowing blobs, glassmorphism on everything, rainbow icon tiles.
- Cards inside cards inside cards. A section is not a card; cards are for repeated items, modals and
  real tools.
- Three identical feature boxes with an icon, a two-word title and filler text.
- Fake stats ("10k+ happy users"), fake logos, lorem ipsum, "Revolutionize your workflow".
- Centred everything, every heading the same size, emoji as icons, drop shadows on flat UI.
- Font size scaling with the viewport (`vw` type) that breaks on phones.

## Type

- Two families at most (often one). A clear scale — e.g. 12 / 14 / 16 / 20 / 28 / 40 / 64 — with
  tight leading on display sizes (1.0–1.15) and relaxed on body (1.45–1.6).
- Body 15–18 px, line length 55–75 characters. Real hierarchy through size and weight, not colour
  alone.

## Colour and surface

- A near-black ink and an off-white ground beat pure #000 on #fff. One accent colour, used for the
  single key action or active state per view — if everything is highlighted, nothing is.
- Contrast: text ≥ 4.5:1, large text and UI edges ≥ 3:1. Check hint and placeholder text too.
- Define colours and spacing as CSS variables; support dark mode when the context calls for it.

## Layout

- An 8-px spacing rhythm; consistent gutters; align to a grid.
- Full-bleed or unframed sections; let whitespace do the grouping.
- Responsive from 360 px: no horizontal scroll, tap targets ≥ 44 px, text never overflows its box,
  tables scroll inside their own container.

## Controls and copy

- Real controls: buttons for actions, links for navigation, toggles for on/off, segmented controls or
  tabs for views, inputs with labels (not placeholder-as-label).
- Every interactive element has hover, focus-visible, active and disabled states; forms have loading,
  error and success states.
- Copy is specific to this product and this user. Short, concrete, verb-first buttons ("Book a call",
  not "Submit").

## Motion

- One strong idea beats many small ones. Animate `transform` and `opacity` only.
- 100–150 ms for feedback, 200–300 ms for state changes, 300–500 ms for larger transitions;
  ease-out on enter, ease-in on exit.
- Respect `prefers-reduced-motion`: provide a no-motion path.

## Check it

Look at it at ~390 px and ~1280 px (headless screenshots are fine). Tab through it with the keyboard.
If you couldn't look, say what you verified and what's left.
