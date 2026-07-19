http://screeninscreen.app

# ScreenInScreen

A tiny macOS utility that mirrors an external monitor in a resizable window.

-----------------------------------------------------------------------

## Quick-Start
1. **Download** `ScreenInScreen.zip` and extract.  
2. Drag **ScreenInScreen.app** to **Applications** (optional).  
3. First launch: **Right-click** → **Open** → **Open** (bypass Gatekeeper).  
4. Click **OK** when macOS asks for *Screen & System Audio Recording* access. (or go to seetings->privacy&security->screen&system audio recording and turn on for screeninscreen) 
5. The display icon appears in the menu bar—ready to use!

-----------------------------------------------------------------------

## How to Use
| Action                  | How                                                         |
|-------------------------|-------------------------------------------------------------|
| Show / hide preview     | **Left-click** menu bar icon **or** press **⌥ B**          |
| Switch mirrored display | **Right-click** menu bar icon → choose monitor             |
| Control the monitor     | **Click / drag / scroll inside the preview** — it lands on the mirrored monitor |
| Toggle click-through    | **Right-click** menu bar icon → **Click Through to Monitor** |
| Presenter mode          | **Right-click** menu bar icon → **Presenter Mode (Mac → Monitor)** |
| Hide windows from audience | **Right-click** menu bar icon → **Choose Hidden Windows…** |
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

## License
**[CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/deed.en)**  
© 2026 the ScreenInScreen developers
