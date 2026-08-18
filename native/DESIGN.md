# SongSmash design record

The app's visual language is "Stadium": solid team-color slabs with heavy
black rounded caps, arcade-weight accent buttons with a hard pressed edge
and a soft glow, a near-black canvas with dim ambient team-color blooms,
and the five-bar equalizer as the brand mark (it IS the play screen).

## v2 — Flame (hot orange), August 2026

Accent changed from green to hot orange `#FF5C00` — a nod to the
FlameEnterprise bundle ID, and a deliberate step away from the default
"music app = Spotify green on black" look.

- `DesignSystem.colors.primary`: `Color(red: 1.0, green: 0.36, blue: 0.0)`
- PrimaryButton pressed edge: `Color(red: 0.72, green: 0.26, blue: 0.0)`
- Warning color moved to yellow `#FFD60A` so error boxes don't collide
  with the new accent
- Orange removed from the team color picker (the accent owns it; the
  `Team.color` mapping keeps the case so previously saved orange teams
  still render)
- App icon bars recolored to match
- All glows kept, exactly as before, now in orange
- Middot (`·`) separators removed everywhere, replaced by a system:
  - `×` joins the music mix only: "ROCK × 1980s" (the collab-drop
    convention — the mix is rock crossed with the eighties)
  - commas in sentences: "TAP ONCE +1, TWICE +2" / "GUNS N' ROSES, 1987"
  - plain space for name-plus-score: "THE SHARKS 9"
  - round status pill: comma ("ROUND 1, FIRST TO 25")

## v1 — Stadium (green), August 2026

To see or restore the green version, it is exactly commit `fa14cec`:

    git diff fa14cec -- native/SongSmashApp/SongSmashApp.swift
    git checkout fa14cec -- native/SongSmashApp native/SongSmashApp.xcodeproj

Key values as shipped in v1:

- Accent green: `Color(red: 0.20, green: 0.84, blue: 0.44)` (#33D670)
- PrimaryButton pressed edge: `Color(red: 0.10, green: 0.52, blue: 0.26)`
- Warning orange: `Color(red: 1.0, green: 0.62, blue: 0.04)`
- Team palette: red, blue, green, orange, purple, pink, yellow, cyan, indigo
- Separators: middot (`·`) — "ROCK · 1980s", "ROUND 1 · FIRST TO 25"
- Icon: green equalizer bars (asset history at commit `b43f731`)

Unchanged across both versions: background `#0A0A0F`, team slab style,
scoreboard bar, countdown, ghost-year reveal watermark, winner
color-flood, confetti, SF Rounded heavy typography, spacing/radius scale.
