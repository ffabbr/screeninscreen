# ScreenInScreen

A tiny macOS utility that mirrors an external monitor in a resizable window.

-----------------------------------------------------------------------

## Quick-Start
1. **Download** the latest `ScreenInScreen-<version>.dmg` from the
   [Releases](../../releases/latest) page, open it, and drag **ScreenInScreen**
   to **Applications**.  
2. First launch: **Right-click** → **Open** → **Open** (the app is ad-hoc
   signed, not notarized, so Gatekeeper asks once).  
3. Click **OK** when macOS asks for *Screen & System Audio Recording* access
   (or enable ScreenInScreen under System Settings ▸ Privacy & Security ▸
   Screen & System Audio Recording).  
4. The display icon appears in the menu bar—ready to use!

-----------------------------------------------------------------------

## How to Use
| Action                  | How                                                         |
|-------------------------|-------------------------------------------------------------|
| Show / hide preview     | **Left-click** menu bar icon **or** press **⌥ B**          |
| Switch mirrored display | **Right-click** menu bar icon → choose monitor             |
| Control the monitor     | **Click / drag / scroll inside the preview** — it lands on the mirrored monitor |
| Toggle click-through    | **Right-click** menu bar icon → **Click Through to Monitor** |
| Presenter mode          | **Right-click** menu bar icon → **Presenter Mode (Mac → Monitor)** |
| Hide windows from audience | **Right-click** menu bar icon → **Settings…** |
| Pin hidden windows on top (click-through) | Your recorded shortcut, **or** right-click → **Pin Windows** |
| Quit ScreenInScreen     | **Right-click** menu bar icon → **Quit ScreenInScreen**    |

*Window size & position are remembered across launches.*

### Click-through
With **Click Through to Monitor** enabled (default), the preview acts as a live
touch-pad for the mirrored display: left/right/middle clicks, double-clicks,
drags and scrolling inside the picture are forwarded to the matching spot on
the real monitor, with all modifier keys intact. After a drag the cursor snaps
back over the preview. Use the title bar to move or resize the window itself.
Requires **Accessibility** access (System Settings ▸ Privacy & Security ▸
Accessibility) — the app prompts on first launch and the menu offers a
shortcut until access is granted.

### Presenter mode (reverse mirroring)
The opposite direction: your **Mac's screen is mirrored onto the external
monitor**, but you choose windows the audience must never see. Set the
external display to *extended* (not mirrored) in System Settings ▸ Displays,
then enable **Presenter Mode**. A fullscreen mirror of your Mac screen appears
on the external display, and a floating **Hidden Windows** checklist opens:
tick a window and it vanishes from the audience's view instantly (it stays
visible to you). New windows appear in the mirror automatically; the checklist
refreshes itself. ScreenInScreen's own windows are never shown to the
audience. Turn the mode off via the same menu item, or it ends automatically
when the monitor is unplugged.

Ticked windows turn slightly **see-through on your own screen** — right away,
even before presenter mode is on — so you can tell at a glance what the
audience can't see. Set how see-through with the
**See-through on your screen** slider at the top of the Hidden Windows panel
(0 % = off, up to 90 %). Clicks still go to the window as normal.

**Pin on top, click-through.** Record a shortcut under **Pin on top,
click-through** in the Hidden Windows panel (click the button, press the
keys; ⌫ removes it, Esc cancels). Pressing it pins every ticked window: it
stays visible exactly where it was and floats above everything, but clicks and
scrolls go straight through to whatever is behind it — even when that window
becomes active. Press the shortcut again (or use **Pin Windows**
in the menu) to unpin. Under the hood the real window is moved into a screen
corner while a live copy is shown in its place; it is moved back when you
unpin or quit. Needs **Accessibility** access.

*The ⌥B shortcut works app-wide once macOS grants **Accessibility** access
(System Settings ▸ Privacy & Security ▸ Accessibility). Without it, the shortcut
only fires while the preview window is frontmost — the menu bar icon always works.*

-----------------------------------------------------------------------

## System Requirements
|                | Minimum                       |
|----------------|-------------------------------|
| **macOS**      | 13 (Ventura) or newer         |
| **CPU**        | Intel 64-bit **or** Apple Silicon |
| **Permissions**| Screen & System Audio Recording (asked once); Accessibility for click-through & global ⌥B |

*Xcode or developer tools are **not** required to run ScreenInScreen.*

-----------------------------------------------------------------------

## Troubleshooting
* **Black window?**  
  Enable ScreenInScreen under **System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording**.
  ScreenInScreen now prompts you and can open that pane directly.  
* **⌥B does nothing from another app? Clicks don't reach the monitor?**  
  Grant **Accessibility** access (see above), and check that
  **Click Through to Monitor** is ticked in the right-click menu.  
* **Gatekeeper blocked?**  
  Right-click → Open once; macOS remembers the choice.

-----------------------------------------------------------------------

## Building from source
Requires Xcode 15 or newer.

```sh
packaging/package.sh 0.2.0   # builds, ad-hoc signs, and creates a DMG
```

The app and DMG land in `build/dd/Build/Products/Release/`. To just build,
open `ScreenInScreen.xcodeproj` in Xcode and run the **ScreenInScreen** scheme.
