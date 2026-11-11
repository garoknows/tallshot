Tallshot turns any scrolling window into one tall screenshot with a single hotkey. Point at it, press **⌃⌥⇧⌘T**, and it scrolls to the bottom, stitches the strips, saves a PNG and copies it to your clipboard. No box to draw, no editor to close.

Signed with a Developer ID and notarized by Apple, so it opens with no warning.

**Changed in 1.1.3**

- **The version shows only at the bottom of Settings.** The menu starts with Capture Now; the version line is gone from its top.
- **The three hotkey rows in Settings behave alike.** Each has Clear, the main Capture hotkey also has Reset to Default, and keys another row already uses aren't saved.

**Fixed in 1.1.2**

- **Scrolling captures and the self-test work again.** 1.1.0 and 1.1.1 parked the pointer with a real "mouse moved" event before the first picture, and the page under it reacted while the pictures were compared, so captures could stop with "the page jumped or changed". The pointer now moves silently during a capture, and gets its real mouse move only after the last picture, so it still never stays a crosshair.
- **Text captures in Ghostty no longer scroll.** The check that a terminal shared its whole history was too strict, so Tallshot fell back to a scrolling screenshot. It now proves the text is complete without moving anything (a history far longer than the pane holds), and the pop-up says why whenever it can't.
- **Terminal and code text is copied exactly**: one fenced code block with single line breaks, no Markdown escapes such as `\*\*`, spaces at line ends trimmed. That also applies to the text read during a scrolling screenshot.
- **Notes, TextEdit and other documents** no longer get a blank line after every line: lines of a paragraph stay together, and blank lines separate paragraphs.
- **No more guessed hotkey warnings.** Settings warns only when macOS refuses a hotkey or uses it for its own shortcut, not because an app such as Raycast is running. A new **Test Hotkey** button confirms a hotkey reaches Tallshot.

**New in 1.1**

- **Text captures.** Point at Ghostty, Terminal, Notes, TextEdit or a code editor that shares all its text with macOS and press the hotkey. Tallshot copies the whole text as Markdown and saves it (plus PDF and Word if those are on), with no scrolling and no screenshots.
- **Only when the text is complete.** Browsers and chat apps share only what's on screen, so they still get a scrolling screenshot.
- **Capture as Image** in the menu (optional hotkey, `tallshot://capture?as=image`) always takes the scrolling screenshot. Settings → General → When an app shares its text chooses the default.
- **The pop-up says which mode ran.** The bottom of Settings shows the version; **Release Notes…** in the menu opens this page in your browser.
- **The pointer never stays a crosshair** after a capture (Ghostty shows one while Option, part of the hotkey, is held).

**Requirements:** macOS 14 Sonoma or later. Tallshot asks for Screen Recording and Accessibility on first launch, with pictures of where to click.
