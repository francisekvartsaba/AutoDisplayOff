# AutoDisplayOff

[English](README.md) · [Русский](README.ru.md)

A tiny macOS menu-bar app that lets you **choose which display is on** when an
external monitor is connected to your MacBook: only the laptop screen, only the
external monitor, or both. "Off" really means off (the display is disabled at the
system level, not just dimmed or painted black) — like clamshell mode, but with
the lid open and the keyboard and trackpad working.

Click the menu-bar icon to open a small window:

- a selector **Laptop / Monitor / Both**;
- a switch for the automatic mode: when you plug in a monitor, the app switches
  to it by itself (and turns the laptop screen off);
- the current status (is the laptop screen on, how many monitors are connected).

The whole app is a single Swift file (`Sources/AutoDisplayOff/main.swift`),
builds with plain `swift build`, and needs **no special permissions** (no
Accessibility, no Screen Recording, no admin rights to run).

> [!WARNING]
> **This software switches displays off and can leave you with a black screen.**
> The screen selector is new and has had limited testing (Apple Silicon only).
> The app has several safeguards (see [Safety measures](#safety-measures)), but
> if every display ever stays off, start the app again (it restores the
> displays on launch) or restart the Mac. Use at your own risk.

## ⚠️ Read this first: risks

- **It uses a private, undocumented macOS API** (`SLSConfigureDisplayEnabled`
  from `SkyLight.framework`, falling back to `CGSConfigureDisplayEnabled`).
  Apple can change or remove it in any macOS update without notice. If it stops
  working after an update, that is expected, not a bug in your setup.
- Because of that, the app **cannot be distributed through the Mac App Store**.
- **A mistake can leave your screens black.** The software is provided as-is,
  with no warranty — see the [LICENSE](LICENSE). Make sure you know how to get
  the screens back (see ["Getting your screen back"](#getting-your-screen-back)).
- Tested by the author on Apple Silicon only. Other setups (Intel, several
  external monitors, docks with DisplayLink adapters) are untested.

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
Dock — the app has no Dock icon while running). The icon turns red when only the
external monitor is on and orange when only the laptop screen is on.

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

## How to use it

| Mode | Built-in display | External monitor(s) |
| --- | --- | --- |
| **Laptop** | on | off |
| **Monitor** | off | on |
| **Both** | on | on |

The selector is available while at least one external monitor is connected.
With the automatic mode on, plugging in a monitor selects **Monitor**; with it
off, a newly connected monitor simply joins as **Both**. Unplug the last
monitor and everything is switched back on.

## How it works

macOS has no public API for "disable this one display". AutoDisplayOff
registers a display-reconfiguration callback
(`CGDisplayRegisterReconfigurationCallback`) and, ~1.5 s after the last change
(so macOS can settle), makes the displays match the selected mode through the
private SkyLight function inside a normal `CGBeginDisplayConfiguration` /
`CGCompleteDisplayConfiguration` transaction, scoped to the current session (a
reboot always resets it).

## Safety measures

- Every switch first turns the needed displays **on** and only afterwards turns
  the others **off**; the last working display is never turned off.
- If the built-in display is off and no external monitor is left (it was
  unplugged), everything is switched back on automatically.
- On quit — the **Quit** button, `pkill`, logout — all displays are switched
  back on.
- The list of displays the app has switched off is saved in
  `~/Library/Application Support/AutoDisplayOff/state.json`. If the app is
  killed or crashes while a display is off, **just start it again**: it restores
  those displays on launch.
- A background check every 15 seconds re-evaluates the situation.

## Getting your screen back

If a display stays black:

1. Start AutoDisplayOff again (or open it and choose **Both**) — it restores
   the displays it has switched off; or
2. Unplug and re-plug the external monitor; or
3. Restart the Mac (this always resets the display state).

## Known limitations

- If the app is killed with `kill -9` / Force Quit while a display is off, the
  display stays off until you start the app again (it recovers on launch) or
  restart the Mac.
- If you unplug a monitor while the app has it switched off (**Laptop** mode)
  and plug the same monitor in again, the app may switch it off again. Choose
  **Both** or **Monitor** to bring it back.
- Mirrored displays and sleep/wake cycles are only handled in a basic way.
- With several external monitors, **Laptop** turns all of them off and
  **Monitor** keeps all of them on; there is no per-monitor choice yet.

Pull requests that improve these are welcome.

## Uninstall

```bash
./uninstall_autostart.sh   # only if you enabled autostart
rm -rf AutoDisplayOff      # source and build output
rm -rf /Applications/AutoDisplayOff.app   # if you copied the app there
rm -rf ~/Library/"Application Support"/AutoDisplayOff   # saved state
```

The app changes no system files; the only things it creates are its own state
file (above), one preference key for the switch (`AutoModeEnabled`) and — if you
enabled autostart — a LaunchAgent in `~/Library/LaunchAgents/`.

## Credits

The idea of using `SLSConfigureDisplayEnabled` / `CGSConfigureDisplayEnabled` to
disable displays was validated by the open-source project
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
