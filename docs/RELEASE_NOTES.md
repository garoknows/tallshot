**Early preview.** Tallshot is being tested by its author; expect rough edges.

Tallshot turns any scrolling window into one tall screenshot with a single hotkey: point at it, press **⌃⌥⇧⌘T**, and it scrolls to the bottom, stitches the strips, saves a PNG to your Desktop and copies it to your clipboard. No box to draw, no editor.

**New in 0.2.1**

- **Quit & Reopen Tallshot.** macOS keeps telling a running app that Screen Recording is off until the app restarts. The setup window now notices when the switch is on, and offers a button that relaunches Tallshot.
- **Permissions that last, for builds from source.** With a Developer ID certificate set up in `Config/Signing.xcconfig`, `scripts/install.sh` signs with it and stops rather than quietly building ad hoc, so macOS keeps Tallshot's permissions across rebuilds.
- **New app icon.** The menu bar icon's shape in white on a dark rounded square, with light, dark, tinted and clear versions on current macOS. The site and docs use it too.

**New in 0.2.0**

- **Just the pane you point at.** New setting, Capture: *Pane under the pointer* (default) or *Whole window*. Pane mode never includes an app's sidebar, a browser's toolbar or the other half of a split view. The outline that flashes first shows exactly what will be captured; press Esc if it's wrong.
- **Also save as PDF, Word and Markdown** (Settings → Output). The PDF splits the tall image into Letter or A4 pages, cut between lines of text, with a searchable text layer. Word and Markdown get the words with headings, nested bullets, links and code blocks: read from the app's accessibility tree when it shares them, otherwise recognized from the image on your Mac. Each export says which. Option: include the image in the Word file.
- **Copy as text:** put the Markdown on the clipboard instead of the image.
- **Settings in three tabs:** General, Output, Capture. "Show a toast" is now **Show a preview pop-up**, and clicking it opens the file.
- **Hotkey warnings:** if macOS refuses a hotkey, it isn't kept, and the field says so; if macOS or a running app such as Raycast is known to use it, a warning says which.

**Also in 0.1.1:** scrolling without overshoot in browsers and chat apps, a test page at https://garoknows.github.io/tallshot/test/chat/, and an optional diagnostic report.

**Privacy:** no network code, no third-party code, no analytics. Text recognition runs on your Mac. Frames stay in memory; only the files you chose are saved, in the folder you chose. Needs macOS 14 Sonoma or later.

**Install:** open the .dmg, drag Tallshot to Applications, open it, and follow the two setup steps. If you had an earlier version, macOS may ask for Screen Recording and Accessibility again.
