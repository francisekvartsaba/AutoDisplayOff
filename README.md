# AutoDisplayOff

[English](README.md) · [Русский](README.ru.md)

A tiny macOS menu-bar app that **actually turns off your MacBook's built-in
display** (not just dims it or paints it black) whenever an external monitor is
connected — and turns it back on when the monitor is unplugged. The lid stays
open, and the keyboard and trackpad keep working, like clamshell mode without
closing the lid.

Click the menu-bar icon to open a small window with the current status, a
switch for the automatic mode, and a manual "turn off / turn on now" button.

The whole app is a single Swift file (`Sources/AutoDisplayOff/main.swift`),
builds with plain `swift build`, and needs **no special permissions** (no
Accessibility, no Screen Recording, no admin rights to run).

> [!WARNING]
> **Known safety issue.** If the app is force-killed or crashes while the
> built-in display is off (for example `pkill`, Force Quit, or a crash), the
> screen may stay black until you restart the Mac, and simply relaunching the
> app will **not** bring it back. Always quit with the **Quit** button in the
> app window. Use at your own risk. Details: [Known limitations](#known-limitations).

## ⚠️ Read this first: risks

- **It uses a private, undocumented macOS API** (`SLSConfigureDisplayEnabled`
  from `SkyLight.framework`, falling back to `CGSConfigureDisplayEnabled`).
  Apple can change or remove it in any macOS update without notice. If it stops
  working after an update, that is expected, not a bug in your setup.
- Because of that, the app **cannot be distributed through the Mac App Store**.
- **A mistake can leave your laptop screen black.** The app has several
  safeguards (see below), but it is provided as-is, with no warranty — see the
  [LICENSE](LICENSE). Use it at your own risk and make sure you know how to get
  the screen back (see ["Getting your screen back"](#getting-your-screen-back)).
- Tested by the author on Apple Silicon with macOS 13+ only. Other setups
  (Intel, multiple external monitors, docks with DisplayLink adapters) are
  untested.

## Requirements

- macOS 13 (Ventura) or newer.
- Xcode Command Line Tools (the full Xcode.app is **not** required):

  ```bash
  xcode-select --install
  ```

  If the build fails with a message about the Xcode license, accept it once:

  ```bash
  sudo xcodebuild -license
  ```

## Build and run

```bash
git clone https://github.com/francisekvartsaba/AutoDisplayOff.git
cd AutoDisplayOff
./build.sh
.build/release/AutoDisplayOff
```

An icon of a monitor appears in the menu bar (top of the screen, **not** the
Dock — the app has no Dock icon while running). Plug in an external monitor:
after about 1.5 seconds the built-in display switches off. Unplug the monitor:
it switches back on.

## Make a double-clickable app

```bash
./package_app.sh
```

This creates `AutoDisplayOff.app` next to the scripts. Drag it to
`/Applications`, and optionally to the Dock, to launch it with one click.

The app is not signed with a developer certificate, so on first launch macOS may
refuse to open it. Right-click (or Control-click) the app → **Open** → **Open**.
You only need to do this once.

## Start at login (optional)

```bash
./install_autostart.sh      # enable
./uninstall_autostart.sh    # disable and stop
```

## How it works

macOS has no public API for "disable this one display while the lid is open".
AutoDisplayOff registers a display-reconfiguration callback
(`CGDisplayRegisterReconfigurationCallback`), and when an external monitor
appears it waits ~1.5 s for macOS to settle, then disables the built-in display
through the private SkyLight function inside a normal
`CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` transaction,
scoped to the current session (a reboot always resets it).

## Safety measures

The built-in display is switched back on automatically when:

1. the last external monitor is disconnected;
2. you quit the app using the **Quit** button in its window (or ⌘Q);
3. you switch the automatic mode off in the window;
4. a background check (every 15 seconds) finds the display off with no external
   monitor present.

The manual "turn off" button refuses to work when no external monitor is
connected.

## Getting your screen back

If the built-in display stays black:

1. Unplug and re-plug the external monitor, or
2. Restart the Mac (this always resets the display state).

## Known limitations

- **If the app is force-killed or crashes while the screen is off**
  (for example `pkill`, Activity Monitor → Force Quit, or a crash), the safeguards
  above cannot run, and the built-in display may stay off until you restart the
  Mac. Always quit with the **Quit** button.
- After a crash, simply relaunching the app does **not** restore the screen,
  because the app only looks for the built-in display among currently active
  displays. Restart the Mac in that case.
- The automatic mode only reacts to displays being connected or removed; it does
  not handle sleep/wake cycles specially.

Pull requests that improve these are welcome.

## Uninstall

```bash
./uninstall_autostart.sh   # only if you enabled autostart
rm -rf AutoDisplayOff      # source and build output
rm -rf /Applications/AutoDisplayOff.app   # if you copied the app there
```

The app changes no system files; the only thing it can create is its own
LaunchAgent in `~/Library/LaunchAgents/` (if you enabled autostart) and one
preference key (`AutoModeEnabled`) for the switch state.

## Credits

The idea of using `SLSConfigureDisplayEnabled` / `CGSConfigureDisplayEnabled` to
disable the built-in display was validated by the open-source project
[InternalDisplayOff](https://github.com/RonaldPark89/InternalDisplayOff), which
is a more feature-rich alternative (global hotkey, brightness-key rerouting,
multi-display control). The code in this repository is an independent,
minimal implementation written from scratch.

## Contact

Questions, bug reports, ideas:

- Email: [varcabafrancisek@gmail.com](mailto:varcabafrancisek@gmail.com)
- Telegram: [@Franzishek](https://t.me/Franzishek)

You can also open an issue on GitHub.

## License

[MIT](LICENSE)
