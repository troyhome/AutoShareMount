# AutoShareMount

**Keeps your network drives connected on macOS.** Shared drives from other Macs, Windows PCs and NAS boxes reconnect by themselves after sleep, restart or a Wi‑Fi change, usually in well under two seconds.

AutoShareMount lives in the menu bar. It finds the computers on your network for you, and connecting one takes a single click.

- **Reconnects fast.** It reacts to wake, login and network changes, checks in under a second whether each computer is reachable, then connects all drives at once.
- **Finds drives for you.** It sees Macs and NAS boxes (Bonjour), Windows PCs (a quick scan of your local network), drives you already have connected, and servers you've saved a password for.
- **Sets itself up.** On first launch it adopts the network drives you already have connected. Anything you connect later in Finder can be kept with one click.
- **Uses your Keychain.** It signs in exactly like Finder does. It never sees or stores your passwords.
- **Fixes the classic hang.** If macOS's network sign-in helper stops responding (connecting hangs everywhere, even in Finder), AutoShareMount restarts it and tries again.
- **Respects ejects.** If you eject a drive, it stays ejected until the next sleep or restart.

Requires macOS 13 Ventura or later. Works on Apple Silicon and Intel Macs.

---

## Install

1. Download **AutoShareMount.zip** from the [Releases](../../releases) page and open it.
2. Drag **AutoShareMount** into your **Applications** folder.
3. Open it. The first time, macOS may say it can't check the app. If it does, open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
4. When macOS asks whether AutoShareMount may **find devices on your local network**, click **Allow**.

A drive icon appears in the menu bar. AutoShareMount starts automatically every time you log in.

## Set up (about two minutes)

### 1. Turn on sharing on the computer that has the files

**On a Mac**
1. Open **System Settings › General › Sharing** and turn on **File Sharing**.
2. Click the **ⓘ** next to it. Under **Shared Folders**, click **+** and choose the drives or folders to share.
3. So it's there when you need it: **System Settings › Battery › Options** (or **Energy**) › turn on **Wake for network access**.

> Macs signed in to the same Apple ID connect to each other without a password.

**On a Windows PC**
1. **Settings › Network & internet › Advanced network settings › Advanced sharing settings**: turn on **Network discovery** and **File and printer sharing** for private networks.
2. Make sure your network is set to **Private**.
3. Right‑click the folder or drive › **Properties › Sharing › Advanced Sharing…** › tick **Share this folder**.
4. **Settings › System › Power**: set sleep to **Never** while plugged in.

> When you sign in from the Mac, use your Windows account. For a Microsoft account, the user name is your Microsoft email and the password is your Microsoft password (a PIN won't work).

### 2. Connect from your Mac

1. Click the menu bar icon › **Open…** › **Find Drives**. Your computers appear after a few seconds.
2. Click **Connect…** next to one. macOS asks you to sign in. Tick **Remember this password in my keychain**.
3. Pick the drives you want. They're added to **My Drives** automatically.

That's it. From now on they reconnect on their own.

Can't see the computer? Click **Connect by Address** and type its name (like `OFFICE-PC`) or IP address (like `192.168.1.20`).

## What the status messages mean

| Status | What to do |
|---|---|
| **Connected** | Nothing. Click it to open in Finder. |
| **Waiting for …** | The other computer is asleep, off, or on another network. It reconnects by itself once it's back. |
| **Needs your password** | Click **Sign In…** and tick *Remember this password*. |
| **Ejected** | You ejected it. It returns after the next sleep or restart, or click **Connect**. |
| **… isn't answering** | The computer is reachable but not sharing. Check that File Sharing is on. |

The **Activity** page shows everything AutoShareMount did, also saved to `~/Library/Logs/AutoShareMount.log`.

## How it works

| When | What happens |
|---|---|
| Login, wake from sleep, network change | Reconnect anything missing, retrying every 2 s for 90 s |
| Every 30 s | Quick check for computers that came online later |
| Before each connection | TCP check of the file-sharing port with a 0.9 s timeout, so offline computers never cause waits |
| Connecting | Apple's NetFS (the same as Finder) with your Keychain credentials and no dialogs, all drives at once, 20 s limit |
| Connection stalls | Restart macOS's network sign-in helper, then try the Finder "Connect to Server" path |

Windows computer names like `CRUSHER` are resolved with NetBIOS, and Macs by Bonjour. A Mac's two names (`Troy’s MacBook` and `Troys-MacBook.local`) are recognised as the same computer, so drives are never connected twice.

## Command line

```bash
/Applications/AutoShareMount.app/Contents/MacOS/AutoShareMount --status     # saved drives: connected? reachable?
/Applications/AutoShareMount.app/Contents/MacOS/AutoShareMount --scan       # what Find Drives sees
/Applications/AutoShareMount.app/Contents/MacOS/AutoShareMount --reconnect  # make the running app reconnect now
```

`--reconnect` is handy in Shortcuts or scripts.

## Build from source

Needs Xcode 15 or later (or the Command Line Tools).

```bash
git clone https://github.com/troyhome/AutoShareMount.git
cd AutoShareMount
./scripts/build-app.sh          # → dist/AutoShareMount.app and dist/AutoShareMount-1.0.0.zip
```

For a release other people can open without warnings, sign with a Developer ID and notarize:

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" VERSION=1.0.0 ./scripts/build-app.sh
xcrun notarytool submit dist/AutoShareMount-1.0.0.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/AutoShareMount.app
```

Project layout:

```
Sources/AutoShareMount/
  AutoShareMountApp.swift   app entry, menu bar + window, login item
  MountEngine.swift         keeps drives mounted (wake/network/timers, NetFS, recovery)
  Discovery.swift           Bonjour browse, port-445 sweep, NetBIOS names, Keychain servers
  Net.swift                 name resolution and fast reachability checks
  MountTable.swift          reads the current network mounts
  ShareURL.swift            share addresses and host-name matching
  ShareStore.swift          saved drive list and activity log
  CLI.swift                 --status / --scan / --reconnect
  Views/                    SwiftUI: menu, My Drives, Find Drives, How to Share, Activity, Settings
```

## Privacy

Everything stays on your Mac and your local network. AutoShareMount never reads passwords: macOS handles sign-in and stores passwords in your Keychain. To find computers that already have a saved password, it reads only the server *names* from Keychain.

## Uninstall

Quit AutoShareMount from its menu (⏻), drag it to the Trash, and optionally delete `~/Library/Application Support/AutoShareMount`.

## License

MIT. See [LICENSE](LICENSE).
