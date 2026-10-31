# Tallshot and your privacy

Tallshot needs two powerful permissions: **Screen Recording** (to see a window) and **Accessibility** (to find the scrolling area and scroll it). Here is exactly what it does with them, and how each promise is checked.

| Promise | How it's kept | How it's checked |
| --- | --- | --- |
| No network | The app contains no networking code and links no third-party code. | `scripts/check-privacy.sh` scans the source for networking APIs and the built app for network symbols and non-Apple libraries. CI runs it on every push and before every release. |
| Captures go only where you send them | The finished PNG is copied to the clipboard and saved to the folder you chose (Desktop by default). That one save is the only file the app writes. | The privacy check fails if any other file write, temp folder or cache appears in the source. |
| Frames never touch the disk | Each picture taken during a capture lives in memory and is discarded when the capture ends. | Same check: no temp files, caches or logs in the code, and no temp-file symbols in the built app. |
| Captures only when you ask | The screen is read with one-shot screenshots between the hotkey and the end of that capture. There is no background stream and no timer. | The check fails on any continuous screen stream or background timer. macOS's purple screen-recording indicator shows only during a capture. |
| Protected windows stay protected | Windows macOS marks as private (password prompts, DRM video) come back blank from macOS. Tallshot uses them as returned. | macOS enforces this. |
| No analytics, no accounts | Settings are the only thing stored, in Tallshot's own preferences. | The check fails on analytics, crash-reporting or updater code, and on preferences other than settings. |

## Why not the App Sandbox?

The App Sandbox would let macOS itself block any network connection, which would be ideal. But Tallshot has to read the layout of *other* apps' windows through Accessibility and post scroll events to them, and save to the Desktop by default. The sandbox gets in the way of all three, and Tallshot can't work without them. So Tallshot uses Apple's **hardened runtime** with **no entitlements at all**, and the source and app scans above prove there is no networking code. A sandboxed build exists only as an experiment (`TALLSHOT_SANDBOX=1 scripts/build-direct.sh`) for checking whether a future macOS allows it.

## Link commands

`tallshot://capture` starts a capture of whatever is under the pointer, so tools like Raycast and Shortcuts can trigger it. A web page could ask to open such a link too, but browsers ask you first, and the result goes only to your clipboard and save folder, never back to the page.
