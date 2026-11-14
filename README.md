
<img width="5136" height="350" alt="hazel_banner" src="https://github.com/user-attachments/assets/93bfc851-540f-4331-a227-e27c9f1f2929" />

## What's Hazel?
A free & open source macOS live wallpaper app that plays videos as your desktop background

## Features

- Set any video as your live wallpaper
- Loop or play once options
- Mute/unmute audio
- App Hides into menu bar
- Low resource usage
- Settings window (`Cmd+,` or menu bar > Hazel Settings): menu bar icon picker, wallpaper fit, system-wallpaper sync, cycling, screensaver + lockscreen
- Wallpaper cycling: None, On Unlock, presets (Every 30 Minutes / Every Hour / Every 5 Hours), Daily time, or Custom interval
- Optional system-wallpaper sync so the desktop stays consistent when Hazel quits or the screen locks
- Hazel screensaver + video lockscreen: one toggle plays the current video in the screensaver and on the lock screen, with Re-apply and Restore backup
- Customizable menu bar icon (Hazel Light/Dark plus minimal shapes)
- Stability hardening: seamless playback, no black windows on missing files, launch prewarms the first frame before heavy follow-up work

## Installation

1. Download the latest release from GitHub
2. Open `hazel.dmg`
3. Drag and move the app to the Applications folder

> [!NOTE]
> The Hazel app may not appear in Spotlight search. To open it, simply open Finder and navigate to the Applications folder, then double click Hazel

## Usage

- Click the menu bar icon and choose the "Hazel" option to open the library window
- Click "+" to add videos
- Select a video to set it as your wallpaper
- Right click a wallpaper for options (loop, mute, remove)
- Use the menu bar to change wallpaper fit or toggle open on startup
- Open Settings (`Cmd+,`) to pick a menu bar icon, toggle system-wallpaper sync, or configure cycling (None / On Unlock / presets / Daily / Custom)
- To use the video screensaver + lockscreen: Settings > Screensaver and lockscreen > turn it on (Re-apply refreshes it, Restore backup returns to the system default)

## Requirements

- macOS 13.0 or later
- Video lockscreen + Hazel screensaver integration requires macOS 26

## Feedback

I’d love to hear your thoughts and feedback!  
You can open an **issue** to share your ideas or suggestions

If you enjoy Hazel, consider giving the repo a ⭐️

## Credits
Special thanks to the original artist for the app icon used in Hazel ❤️
<br></br>
Pinterest: https://in.pinterest.com/kyurakatsuya/
<br></br>
Instagram: https://www.instagram.com/_lunara28
<br></br>
**All rights belong to the respective creator**

### Third-party code
- Wallpaper extension ported from Phosphene (MIT, © 2026 kageroumado) — see `hazel-appex/LICENSE.Phosphene`
- System wallpaper/saver store access via vendored PaperSaverKit (MIT, © 2025 PaperSaver Contributors) under `hazel/Vendor/PaperSaverKit`
