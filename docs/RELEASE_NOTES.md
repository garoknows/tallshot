Tallshot turns any scrolling window into one tall screenshot with a single hotkey. Point at it, press **⌃⌥⇧⌘T**, and it scrolls to the bottom, stitches the strips, saves a PNG and copies it to your clipboard. No box to draw, no editor to close.

**Tallshot 1.0**

This is the first full release. It's signed with a Developer ID and notarized by Apple, so it opens with no warning.

- **Just the pane you point at.** A chat column, a mail message, one side of a split view. Sidebars, toolbars and the other pane stay out. Prefer the whole window? Settings → General → Capture.
- **Works where scrolling is awkward.** Browsers that glide past where they were asked to stop, chat apps with floating buttons and a see-through message box, and pages that load older messages at the top. Capture from Top starts at the very beginning.
- **Also save as PDF, Word and Markdown.** A searchable PDF on Letter or A4 pages, and Word and Markdown files with real headings, lists, links and code. Copy as text puts the Markdown on the clipboard.
- **File names that say what's in them.** For example `Arc - example.com - Chat test - 2026-11-07 at 14.05 - Tallshot.png`. Prefer the date only? Settings → Output → File names.
- **Private by design.** No network code, no analytics, no account. Captures go only to your clipboard and the folder you choose. Text recognition runs on your Mac.

**Fixed since 0.2.3**

- A failed save (a full disk, a missing folder) left some files without saying so. Tallshot now keeps what it saved, says which, and removes any half-written file.
- Scrolling set to the opposite direction (by a scroll-reversing utility, for example) wasn't noticed when a capture started at the top of a page.
- Very tall captures copied the whole image on every step, which was slow and briefly doubled the memory used.
- A window or Tallshot's own pop-up over the middle of the pane could catch the scrolling.
- An app that had stopped responding could freeze Tallshot for about ten seconds.
- Recording a hotkey that Tallshot already uses started a capture instead.
- The Capture from Top hotkey could type its letter into the app if the key was held.
- After a capture, Electron apps kept their extra accessibility work switched on.
- The setup window's permission check could keep running after the window closed.
- Word: numbered lists didn't restart at 1, and line breaks inside text were lost.
- Markdown: text that looked like HTML or a numbered list changed meaning, links could break, and only web and mail links are kept.
- PDF and Word text could treat every line as code after an earlier capture of a different page.
- The pop-up thumbnail was stretched for short captures.
- A diagnostic report that failed to save could leave a partial folder.

**Requirements:** macOS 14 Sonoma or later. Tallshot asks for Screen Recording and Accessibility on first launch, with pictures of where to click.
