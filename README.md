<img src="Resources/AppIcon.png" width="120" alt="Mirror icon">

# Mirror

Press Command Shift S to see yourself on your MacBook screen. Press it again to close.

The camera grows out of the notch and folds back into it. Mirror always opens on the MacBook's own screen, never on an external monitor, and the camera runs only while Mirror is open.

## Install

Mirror needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/sebxt/mirror.git
cd mirror
./install.sh
```

The first time you press Command Shift S, macOS asks for camera access.

Mirror starts at login and shows no icon in the menu bar or the Dock. To open it with a click as well, drag Mirror from Applications to your Dock.

## Keys

| Keys | Action |
| --- | --- |
| Command Shift S | Open or close |
| Command W or Escape | Close |

Command Shift S is Save As in many apps. While Mirror runs, those apps no longer receive it. To use another key, change `shortcutKey` at the top of `Sources/main.swift` and run `./install.sh` again.

## How it works

The camera needs about 430 ms after it starts to deliver its first picture, and its first frames are black. Mirror does not wait for it. The moment you press the keys, a panel grows out of the notch on a spring and shows a blurred frame saved the last time Mirror closed. When the first real picture arrives, the live video sharpens in over the blur. Only the panel's shape moves, so the desktop never shows through your face.

The whole app is one file, `Sources/main.swift`.

## Privacy

Mirror has no network code. The camera runs only while Mirror is open. Mirror keeps one small blurred frame from its last opening in `~/Library/Caches/com.sebastianturner.mirror`, to show while the camera starts. `./uninstall.sh` deletes it.

## Uninstall

```bash
./uninstall.sh
```

## License

MIT
