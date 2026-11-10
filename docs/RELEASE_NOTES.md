Tallshot turns any scrolling window into one tall screenshot with a single hotkey. Point at it, press **⌃⌥⇧⌘T**, and it scrolls to the bottom, stitches the strips, saves a PNG and copies it to your clipboard. No box to draw, no editor to close.

Signed with a Developer ID and notarized by Apple, so it opens with no warning.

**New in 1.1: terminals and documents give you their text**

- **Text captures.** Point at Ghostty, Terminal, Notes, TextEdit or a code editor that shares all its text with macOS and press the hotkey. Tallshot copies the whole text as Markdown and saves it (plus PDF and Word if those are on), with no scrolling, no screenshots and no pointer movement. A terminal's text keeps its exact spacing.
- **Only when the text is complete.** Tallshot uses the text only when the app shows it includes the part scrolled out of view. Browsers and chat apps share only what's on screen, so they still get a scrolling screenshot, as before.
- **Capture as Image.** A new menu item, with an optional hotkey in Settings, that always takes the scrolling screenshot. Also `tallshot://capture?as=image`.
- **Your choice.** Settings → General → When an app shares its text: **Copy the text (no scrolling)** (the default) or **Always take a scrolling screenshot**.
- **The pop-up says which mode ran**, and, when an app's text couldn't be used, why.
- **Which version you have** is the first line of the menu, and at the bottom of Settings. **Release Notes…** in the menu opens this page in your browser (Tallshot itself still makes no network connections).

**Fixed**

- **The pointer could stay a crosshair after a capture** until you clicked or moved away. Some apps change the pointer while a modifier key is down: Ghostty shows a crosshair while Option is held, for block selection, and Tallshot's default hotkey includes Option. Tallshot now waits until you've let go of the hotkey's keys, tells the app under the pointer they're up, and moves the pointer in place, after every capture: finished, Esc, an error, an early stop or a text capture.
- **A refused hotkey names the likely culprit.** If macOS won't give Tallshot a hotkey because another app took it first, and Shottr or CleanShot X is running, the warning says so.
- In 1.0, a terminal sitting at the bottom of its history was scrolled up and back down before the capture gave up. A terminal that shares its text now gets a text capture instead, with no scrolling.

Everything from 1.0 is still here, including the review fixes: lower memory for very large captures, nothing private inside saved files, no freeze when pointing at Tallshot's own windows, and the safer `install.sh`.

**Requirements:** macOS 14 Sonoma or later. Tallshot asks for Screen Recording and Accessibility on first launch, with pictures of where to click.
