# Changelog

## v1.0.2 — 2026-05-12

Setup-helper visibility fix + extends the managed-files set to cover the full launcher experience.

**`_Setup_Helper.ps1`** (now manifest-managed; was previously unmanaged):

- Removed `-WindowStyle Hidden` from the desktop-shortcut arguments. Shortcuts created by `First_Time_Setup.bat` from now on open a visible PowerShell window so friends see the update output. (Existing friends who already ran setup keep working via v1.0.1's self-promote.)

**`First_Time_Setup.bat`** (now manifest-managed; was previously unmanaged):

- No content changes; added to the manifest so future tweaks to first-time setup propagate automatically.

**Build (`build-release.ps1`):**

- `_Setup_Helper.ps1` and `First_Time_Setup.bat` added to `$ManagedFiles`. Total managed files now 4.

## v1.0.1 — 2026-05-12

UX pass on the update flow. Friends now see what the launcher did on every launch, including the boring "already up to date" case.

**Launcher (`Launch_EQ.ps1`):**

- **Visible console output.** "Up to date at vX.Y" on no-op runs (green); "Update available: vX.Y → vA.B. Applying…" on real updates (cyan); clear error messaging on failures (yellow/red).
- **"Press any key to launch the game" prompt** before every EQ start, so friends can read the update output. Falls through automatically in non-interactive hosts.
- **Self-promote to visible window.** If PowerShell was started with `-WindowStyle Hidden` (older `Play_EQ.bat` versions or pre-v1.0.1 desktop shortcuts), the launcher detects that, relaunches itself visible, and exits the hidden process. Existing friends keep working without re-running setup.
- **Heartbeat log line on every launch.** `theo_and_co_updater.log` now gets a line per launch (`Check OK: up to date at vX.Y` / `Update OK: ...` / `Update FAILED: ...`), so we can debug from screenshots without needing a "did it run" check.
- Renamed launch message "Launching EQ..." → "Launching EverQuest..." (cosmetic).

**`Play_EQ.bat`** (now manifest-managed; was previously unmanaged in v1.0):

- Removed `-WindowStyle Hidden` from the PowerShell invocation so updater output is visible from the start. (The self-promote path in the launcher handles existing friends until they pick up this new bat file.)

**Build (`build-release.ps1`):**

- `Play_EQ.bat` added to `$ManagedFiles`.

## v1.0 — 2026-05-12

Initial release. Bootstraps the auto-update channel for the Theo and Co private EQEmu server.

**New launcher** (`Launch_EQ.ps1`):

- Auto-updater logic — checks GitHub releases on launch, downloads + applies any newer bundle, falls through gracefully on network error.
- `$LockedSettings` enforced after every EQ exit:
  - `MouseTurnZoom = 0` — disables auto-zoom-while-turning (universal comfort-of-defaults preference).
  - `MaxFPS = 60`
  - `MaxMouseLookFPS = 60` — pair with `MaxFPS=60` to even out EQ's intrinsic 2:1 horizontal/vertical mouse-look disparity at high frame rates.
- Path-traversal safety: manifest entries with install paths escaping the EQ root are rejected.
- SHA256 hash verification on every downloaded asset before replacing the on-disk file.
- Updater log next to the launcher (`theo_and_co_updater.log`) for debugging friends' update failures from screenshots.

**Removed from previous launcher's `$LockedSettings`:**

- `MouseSensitivity` — the old `=100` lock was a silent no-op (the client clamps the loaded value to `[1, 8]` in `loadOptions`, so 100 became 8 on every launch). With the locking mechanic understood, the right call is to not lock at all: EQ already persists the slider's position to `eqclient.ini` between sessions on its own, and sensitivity is personal preference (8 discrete buckets giving a 0.5x-2.0x multiplier range). Friends now keep whatever sensitivity they choose in-game.
