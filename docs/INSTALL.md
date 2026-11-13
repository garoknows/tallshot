# Installing Tallshot

## From the download

1. Download `Tallshot-<version>.dmg` from [Releases](https://github.com/garoknows/tallshot/releases).
2. Open the .dmg and drag **Tallshot** onto **Applications**.
3. Open Tallshot from Applications. It appears in the menu bar as a tall, narrow rounded icon. There's no Dock icon.

### If macOS says it can't check Tallshot

Releases from 1.0 on are signed with a Developer ID and notarized by Apple, so they open with no warning. Older pre-releases (0.x) weren't. If one of those says *"Tallshot" can't be opened because Apple cannot check it for malicious software*:

1. Click **Done** (not Move to Trash).
2. Open **System Settings → Privacy & Security**.
3. Scroll down to the message about Tallshot and click **Open Anyway**.
4. Confirm with your password or Touch ID, then click **Open**.

You only do this once. Signed and notarized releases open with no warning.

## With Homebrew

```
brew install --cask garoknows/tap/tallshot
```

This installs the same signed and notarized release into Applications. `brew upgrade --cask tallshot` updates it to a newer release.

## The two permissions

On first launch, Tallshot shows a setup window with pictures of exactly where to click.

![Step 1: Screen Recording](images/step1-screen-recording.png)

1. Click **Open Screen Recording**. In System Settings, turn on the switch next to **Tallshot**. macOS may ask you to quit and reopen Tallshot; do that with the **Quit & Reopen Tallshot** button, which appears in the setup window when the switch is on but Tallshot still reads it as off.

![The Quit & Reopen Tallshot button in step 1](images/setup-reopen.png)

![Step 2: Accessibility](images/step2-accessibility.png)

2. Click **Open Accessibility** and turn on the switch next to **Tallshot**.

Each step turns green by itself. Then click **Run Self-Test** (later: menu → Troubleshooting → Run Self-Test): Tallshot captures its own test page and tells you whether every row came out once, in order.

## Using it

- Point at any scrolling area and press **⌃⌥⇧⌘T**.
- **Capture from Top** in the menu scrolls to the top first. From the menu, Tallshot captures the front window; with a hotkey, the window under the pointer.
- **Terminals and documents give you their text.** When the pane is a terminal, Notes, TextEdit or a code editor that shares all its text with macOS, Tallshot copies the text as Markdown and saves it (plus PDF and Word if those are on) without scrolling or taking pictures. Browsers and most chat apps share only what's on screen, so they get a scrolling screenshot. The pop-up says which one ran.
- **The ChatGPT app gives you the whole conversation as text**, with You and ChatGPT before each turn, because it keeps every message. Claude keeps only what's near the screen, so it gets a scrolling screenshot. For another chat app: click its window, then **Troubleshooting → Check This App…** in the menu. The check shows the first and last message it found; if the first is the chat's real first message, choose **Yes, Use Text Capture**. Settings → General → Apps lists the answers and has **Forget Checked Apps**. Browsers aren't offered text capture: each site keeps its text differently.
- **Troubleshooting → Run Self-Test** in the menu runs the self-test again. Tallshot's windows always open in front, on the display with the pointer.
- **Capture as Image** in the menu always takes a scrolling screenshot, even of a terminal.
- The bottom of Settings shows which version you have. **Release Notes…** in the menu opens the releases page in your browser.
- Esc, a click, a key or moving the mouse stops it and keeps what was captured.
- Settings (menu → Settings…):
  - **General:** the hotkeys, including an optional one for Capture as Image (with a warning under the field only when macOS refuses the keys or uses them for its own shortcut), and a **Test Hotkey** button that confirms a hotkey reaches Tallshot. Every hotkey row has **Clear** (the menu works without hotkeys), the main Capture hotkey also has **Reset to Default**, and keys another row already uses aren't saved; When an app shares its text (Copy the text, no scrolling, or Always take a scrolling screenshot); Capture (pane under the pointer, or the whole window); Open at login.
  - **Output:** the save folder; File names (app, title and date, or the date only); Also save as PNG, PDF, Word (.docx), Markdown (.md); Copy as image or text; PDF page size; the preview pop-up; the shutter sound.
  - **Capture:** scroll speed, the height and time limits (a very wide capture also stops at 50 million pixels in all), and the optional diagnostic report and where it goes.

## Building from source

Needs Xcode (free in the Mac App Store) and, optionally, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
git clone https://github.com/garoknows/tallshot
cd tallshot
scripts/install.sh
```

It installs to `~/Applications`, and replaces a running Tallshot only after the new build passes its signature check. Set `TALLSHOT_DEST=/Applications` to install for all users.

## Uninstalling

Quit Tallshot from its menu, then drag it from Applications to the Trash. To remove its settings too: `defaults delete io.github.garoknows.tallshot`. If you installed it with Homebrew, `brew uninstall --cask tallshot` removes the app, and `brew uninstall --zap --cask tallshot` removes its settings too. You can also remove it from the Screen Recording and Accessibility lists in System Settings.
