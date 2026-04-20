# Claum glass style guide

The aesthetic is drawn directly from `glass-browser-preview.html`. Use this
doc when you're styling a new surface (dialog, toolbar, panel) so Claum stays
visually consistent.

## Core principles

1. **Glass is a surface, not a theme.** Every piece of chrome is translucent
   with a heavy backdrop blur. The color comes from what's behind it — we
   just tint the glass.
2. **Soft edges everywhere.** Border-radius 12–18 px on surfaces, 8 px on
   inputs, 999 px (pill) on chips. No hard 90° corners anywhere in UI chrome.
3. **Shadow is cheaper than borders.** Prefer a soft `0 2px 12px rgba(0,0,0,.18)`
   drop-shadow over a 1 px border where possible.
4. **Orange is a signal, not a fill.** The Claude orange (`#D97757`) belongs
   on calls-to-action, active states, and the brand mark — never as a body
   background.
5. **Motion is whisper-light.** 100–200 ms transitions on hover / active /
   open states. Never spring-animate chrome — it feels fussy.

## Tokens

```css
:root {
  --claude-orange:        #D97757;
  --claude-orange-soft:   rgba(217, 119, 87, 0.18);
  --bg-base:              #1B1B1F;     /* page background behind glass */
  --bg-elevated:          rgba(255,255,255,0.06);
  --bg-glass:             rgba(255,255,255,0.10);
  --border-glass:         rgba(255,255,255,0.14);
  --text-primary:         rgba(255,255,255,0.92);
  --text-secondary:       rgba(255,255,255,0.62);
  --text-tertiary:        rgba(255,255,255,0.40);
  --shadow-deep:          0 12px 40px rgba(0,0,0,0.45);
  --shadow-soft:          0 2px 12px rgba(0,0,0,0.18);
  --radius-lg:            18px;
  --radius-md:            12px;
  --radius-sm:            8px;
}
```

These are defined in:

- `claum/extensions/claude-for-chrome/sidepanel.css` (authoritative)
- `claum/patches/02-claum-glass-ui.patch` (Chromium NTP fallback)
- Any new surface: import or copy them verbatim.

## The one required recipe: a glass surface

```css
.glass {
  background: var(--bg-glass);
  -webkit-backdrop-filter: saturate(180%) blur(28px);
          backdrop-filter: saturate(180%) blur(28px);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius-lg);
  box-shadow: var(--shadow-soft);
}
```

Any card, panel, toolbar, or dialog should start here.

## Typography

Use the system stack, not a web font. It keeps us honest to the OS glass:

```css
font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text",
             "Segoe UI", system-ui, sans-serif;
```

Sizes we've standardized on:

| Use case            | Size  | Weight |
|---------------------|-------|--------|
| Body                | 14 px | 400    |
| Panel heading       | 17 px | 600    |
| Large heading       | 22 px | 600    |
| Micro / eyebrow     | 10 px | 500, uppercase, 0.06em tracking |

## Icons

We use Lucide-style 1.6 px strokes everywhere. 22 px inline, 18 px inside
buttons, 16 px in tight rows. Keep `fill="none"` on the stroke icons so they
pick up `currentColor` from their parent.

## What breaks the glass

Avoid:

- ❌ Opaque, solid-color backgrounds in chrome.
- ❌ Drop-shadows combined with gradients (looks muddy over blur).
- ❌ Any saturation above the 180% we've tuned in `backdrop-filter`.
- ❌ 1-pixel-gray borders. Use the token or shadow instead.
- ❌ Pure-black or pure-white text. Always use the tokens — they have the
  right alpha.

## Inspiration file

Open `glass-browser-preview.html` in a browser. If something you're building
doesn't look like it belongs in that file, it doesn't belong in Claum.
