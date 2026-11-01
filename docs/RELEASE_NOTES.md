**Early preview.** Tallshot is being tested by its author; expect rough edges.

Tallshot turns any scrolling window into one tall screenshot with a single hotkey: point at it, press **⌃⌥⇧⌘T**, and it scrolls to the bottom, stitches the strips, saves a PNG to your Desktop and copies it to your clipboard. No box to draw, no editor.

**New in 0.1.1: browsers and chat apps**

- **No more overshoot.** Some apps treated Tallshot's scrolling like a trackpad flick and flew several screens at once, so nothing lined up and only one screen was saved. Tallshot now scrolls without momentum, measures every step, asks for less when an app goes too far, starts with small steps in browsers, and if a step still overshoots it walks back until the pictures overlap again.
- Exact scrolling through the scroll bar where an app offers it.
- The hotkey's keys no longer leak into the scroll (Shift turned it sideways and Control zoomed in some browsers).
- Chrome, Arc, Edge, Brave, Dia and Electron apps: Tallshot switches on their accessibility description so it finds the scrolling pane, and otherwise uses the page without the browser's tabs and toolbar.
- Captures of a whole window are cropped to the part that scrolled, so an app's sidebar is left out.
- Chat apps' floating buttons, fades and message boxes no longer break the line-up, and appear once at the bottom.
- **Capture from Top** waits for older messages to load, for exporting a whole chat.
- If a capture stops early, the pop-up says so and why. If an area doesn't scroll at all, it says "This area didn't scroll".
- Optional: **Keep a diagnostic report when a capture stops early** (Settings → Capture, off by default).
- Test page for browsers: https://garoknows.github.io/tallshot/test/chat/ (every row is barcoded, and the pop-up reports whether the capture came out right). The self-test also runs when you point at it and press the hotkey.

**Privacy:** no network code, no third-party code, no analytics. Frames stay in memory; only the finished PNG is saved, where you chose. Needs macOS 14 Sonoma or later.

**Install:** open the .dmg, drag Tallshot to Applications, open it, and follow the two setup steps. If you had 0.1.0, macOS may ask for Screen Recording and Accessibility again.
