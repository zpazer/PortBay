# Port Bay

A tiny macOS menu bar app that shows which TCP ports are listening on your Mac, and stops the process behind one with a click.

No more `lsof -i :3000` and `kill -9` to find the dev server you forgot in another terminal.

## Features

- **Dev servers first.** Things you started yourself (Vite, Next.js, Laravel, Django, Postgres, …) are listed at the top with their port, a friendly name and the folder they run in. Ports owned by apps and macOS (VS Code, Discord, Control Center, …) are tucked under a collapsed "Apps and system" section.
- **One click to stop.** The ⊗ button sends `SIGTERM`. If the process is still running after 3 seconds, the button turns into **Force**, which sends `SIGKILL`. App and system processes ask for a second click, because stopping one can quit the whole app.
- **Notices restarts.** If something brings the port straight back (for example `brew services` or a file watcher), Port Bay tells you.
- **Actions menu.** Click (or right-click) a row to open it in the browser, show its folder in Finder, copy the PID or the full command, or force kill it.
- **Shows exposed ports.** An orange Wi-Fi icon marks servers listening on all interfaces, which other devices on your network can reach.
- **Open at login**, if you want it.

## Install

Port Bay needs macOS 13 Ventura or later, on Apple Silicon or Intel.

### Download

1. Download `PortBay-<version>.zip` from the [latest release](https://github.com/zpazer/PortBay/releases/latest).
2. Unzip it and drag `PortBay.app` into your Applications folder.
3. Open it. The first time, macOS blocks it because the app isn't notarized by Apple. Click **Done**, open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the message about PortBay, then confirm. You only need to do this once.

   Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/PortBay.app`

Port Bay lives in the menu bar (look for the stacked squares icon) and has no Dock icon.

### Build from source

You need Xcode or the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/zpazer/PortBay.git
cd PortBay
./build.sh
```

`build.sh` compiles the app, signs it ad hoc for your machine, copies it to `~/Applications/PortBay.app` and starts it. Run it again after changing the code; it replaces the installed copy and restarts it.

`./build.sh --release` builds the app for both Apple Silicon and Intel and zips it as `build/PortBay-<version>.zip`, ready to attach to a GitHub release.

## How it works

Port Bay runs the same tools you would:

- `lsof -nP -iTCP -sTCP:LISTEN` to find listening ports (every 2 seconds while the panel is open, every 5 seconds otherwise)
- `ps` and `lsof -d cwd` to get each process's command line and working folder (cached per process)

A process counts as a **dev server** unless its executable lives inside an `.app` bundle or under `/System`, `/usr/libexec` or `/usr/sbin`. It only sees and stops processes owned by your user, and it never sends anything over the network.

## Uninstall

Quit Port Bay from its panel, then delete `PortBay.app` from your Applications folder. To remove its settings too:

```sh
defaults delete app.portbay
```

## License

[MIT](LICENSE)
