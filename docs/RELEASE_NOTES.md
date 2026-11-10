**Early preview.** Tallshot is being tested by its author; expect rough edges.

Tallshot turns any scrolling window into one tall screenshot with a single hotkey. Point at it, press **⌃⌥⇧⌘T**, and it scrolls to the bottom, stitches the strips, saves a PNG and copies it to your clipboard. No box to draw, no editor to close.

**New in 0.2.4**

- **File names that say what's in them, in every browser.** For example `Arc - example.com - Chat test - 2026-11-07 at 14.05 - Tallshot.png`. Nothing goes in from a password field that has the keyboard or a Chrome Incognito window. Prefer the date only? Settings → Output → File names.
- **The name stays out of the files.** The page title and site are only in the file names now. Before, a saved PDF kept the full name as its title inside the file, so it stayed there even after you renamed the file. The PDF's title is now just "Tallshot capture".
- **Very large captures use much less memory.** Saving no longer makes a full extra copy of the image, and a very wide capture now stops at 50 million pixels in all (about 14,400 pixels tall across a 16-inch MacBook Pro's whole screen) with "Stopped at the size limit", so memory stays well under 1 GB.

**Fixed**

- Pressing the hotkey over Tallshot's own Settings window could freeze Tallshot for a few seconds. An app that had stopped responding could also hold it up longer than it should.
- Capture from Top could start partway down in an app that shows a scroll bar but ignores it.
- In an app that ignores one kind of scrolling, a page that scrolled too far once could end the capture after one screen.
- Very tall captures copied the whole image on every step, which was slow and briefly doubled the memory used.
- A failed save (a full disk, a missing folder) left some files without saying so. Tallshot now keeps what it saved, says which, and removes any half-written file.
- Scrolling set to the opposite direction wasn't noticed when a capture started at the top of a page.
- A window or Tallshot's own pop-up over the middle of the pane could catch the scrolling.
- Recording a hotkey that Tallshot already uses started a capture instead, and the Capture from Top hotkey could type its letter into the app.
- After a capture, Electron apps kept their extra accessibility work switched on.
- Word: numbered lists didn't restart at 1, and line breaks inside text were lost. Markdown: text that looked like HTML or a numbered list changed meaning, and only web and mail links are kept.
- The pop-up thumbnail was stretched for short captures, and a diagnostic report that failed to save could leave a partial folder.

**For people building from source:** `scripts/install.sh` now checks the new build's signature before it quits the running Tallshot, so a refused build leaves your copy running, and `--remove-other-copies` can no longer delete the copy it just installed.

**Requirements:** macOS 14 Sonoma or later. Tallshot asks for Screen Recording and Accessibility on first launch, with pictures of where to click.
