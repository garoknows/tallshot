# Tallshot and your privacy

Tallshot needs two powerful permissions: **Screen Recording** (to see a window) and **Accessibility** (to find the scrolling area and scroll it). Here is exactly what it does with them, and how each promise is checked.

| Promise | How it's kept | How it's checked |
| --- | --- | --- |
| No network | The app contains no networking code and links no third-party code. | `scripts/check-privacy.sh` scans the source for networking APIs and the built app for network symbols and non-Apple libraries. CI runs it on every push and before every release. |
| Captures go only where you send them | The finished PNG is copied to the clipboard and saved to the folder you chose (Desktop by default). If you turn on PDF, Word or Markdown, those are built in memory and written straight into the same folder (no temp copy elsewhere). Those are the only files the app writes, apart from the optional diagnostic report below. | The privacy check fails if any other file write, an atomic write (which stages a temp copy), a temp folder or a cache appears in the source. A test exports all four formats and checks nothing appears anywhere but the chosen folder. |
| Text recognition stays on your Mac | For a searchable PDF, or Word and Markdown when the app doesn't share its text, Tallshot reads the words in the image with Apple's Vision framework, which runs on the Mac. | No network code (checked as above). |
| Diagnostics only if you ask | **Keep a diagnostic report when a capture stops early** is off by default. When you turn it on and a capture stops early, Tallshot saves a folder next to the capture with its frames and a step log, so you can share it if you choose. It is never sent anywhere. | A test checks that an early stop with the setting off keeps no frames and writes nothing; the privacy check fails if the report can be written without the setting, or if the setting isn't off by default. |
| Frames never touch the disk | Each picture taken during a capture lives in memory and is discarded when the capture ends. | Same check: no temp files, caches or logs in the code, and no temp-file symbols in the built app. |
| Captures only when you ask | The screen is read with one-shot screenshots between the hotkey and the end of that capture. There is no background stream and no timer. | The check fails on any continuous screen stream or background timer. macOS's purple screen-recording indicator shows only during a capture. |
| Protected windows stay protected | Windows macOS marks as private (password prompts, DRM video) come back blank from macOS. Tallshot uses them as returned. | macOS enforces this. |
| No analytics, no accounts | Settings are the only thing stored, in Tallshot's own preferences. | The check fails on analytics, crash-reporting or updater code, and on preferences other than settings. |

## Why not the App Sandbox?

The App Sandbox would let macOS itself block any network connection, which would be ideal. But Tallshot has to read the layout of *other* apps' windows through Accessibility and post scroll events to them, and save to the Desktop by default. The sandbox gets in the way of all three, and Tallshot can't work without them. So Tallshot uses Apple's **hardened runtime** with **no entitlements at all**, and the source and app scans above prove there is no networking code. A sandboxed build exists only as an experiment (`TALLSHOT_SANDBOX=1 scripts/build-direct.sh`) for checking whether a future macOS allows it.

## Browsers and Chromium/Electron apps

Chrome, Arc, Edge, Brave, Dia and Electron apps (many chat and notes apps) don't describe their windows to Accessibility until an assistive app asks. When you capture one, Tallshot turns that description on for that app (`AXManualAccessibility`, `AXEnhancedUserInterface`), the same switch screen readers use, and puts `AXEnhancedUserInterface` back the way it was when the capture ends. It only reads where the scrolling area is; it doesn't read the page's text.

## Link commands

`tallshot://capture` starts a capture of whatever is under the pointer, so tools like Raycast and Shortcuts can trigger it. A web page could ask to open such a link too, but browsers ask you first, and the result goes only to your clipboard and save folder, never back to the page.
