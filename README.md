# theo-and-co-client-pack

Auto-update channel for client-side files used on the **Theo and Co** private EQEmu server (RoF2 client, PoP era).

## What this is

A versioned bundle of client-side files that friends' launchers pull on every EQ launch. Each release tag (`v1.0`, `v1.1`, ...) ships:

- `Launch_EQ.ps1` — the launcher itself, with auto-updater logic + `$LockedSettings` for ini stability
- `Play_EQ.bat`, `_Setup_Helper.ps1`, `First_Time_Setup.bat` — supporting launcher scripts (`Theo and Co/` subfolder)
- `Zeal.asi` (since v1.1.0) — compiled [Zeal-RoF2](https://github.com/nightwreath/Zeal-RoF2) DLL; Miles Sound System auto-loads any `.asi` in the EQ root and applies the bundled patches at startup. Currently: H/V mouse-look parity. Future patches (3rd-person camera, FOV, mouse smoothing) layer in here.
- `manifest.json` — declares each managed file's install path + SHA256 hash

Future asset classes (UI mods, map overlays) plug into the same bundle without additional infrastructure.

## How friends get updates

On every launch, the launcher:

1. Queries `https://api.github.com/repos/nightwreath/theo-and-co-client-pack/releases/latest`
2. If the remote tag differs from `theo_and_co.version` next to the launcher: downloads `manifest.json`, hashes each managed file locally, and downloads + replaces only the mismatches
3. Network errors fall through without blocking launch — friends with no internet still get into EQ
4. Launches `eqgame.exe`
5. After EQ exits, re-stamps `eqclient.ini` with `$LockedSettings`

## Managed-files allowlist

The updater touches **only files declared in `manifest.json`**. Friend-owned files (their personal `eqclient.ini` tweaks beyond `$LockedSettings`, custom UI XML, screenshots, character data) are never overwritten. The launcher also rejects any manifest entry whose resolved install path escapes the EQ root directory.

## First-time install

Friends drop the new `Launch_EQ.ps1` into their `Full_RoF2_for_friends/Theo and Co/` folder one time (manual Discord drop). From then on, the launcher auto-updates itself and the rest of the bundle.

## License

MIT.
