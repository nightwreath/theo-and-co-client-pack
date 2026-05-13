# Changelog

## v1.0.7 — 2026-05-12

Two small polish fixes.

**`MouseTurnZoom` removed from `$LockedSettings`.** The key has an in-game UI toggle (Options → Mouse), so locking it to a fixed value forces a personal preference on friends with no in-game way to opt out. Removed for the same reason `MouseSensitivity` was removed in v1.0 — friend-owned preferences shouldn't be re-stamped from outside the game. Remaining locked settings (`MaxFPS=60`, `MaxMouseLookFPS=60`) are the Path A frame-rate cap pair for the H/V mouse-look disparity fix; neither has an in-game UI, both live in ini only.

**Progress-bar color flicker suppressed.** `$ProgressPreference = 'SilentlyContinue'` set at the top of the script. PowerShell 5.1's `Invoke-WebRequest` (and other web cmdlets) paint a colored ASCII progress bar across the terminal during downloads — visible for ~50ms each, which looked like a glitch flickering in and out during the update check. Suppressing the progress bar removes the visual artifact; downloads still happen, they just no longer paint over the terminal.

## v1.0.6 — 2026-05-12

Console window now actually closes when the game launches.

**Bug:** v1.0.5's `Add-Type` + Win32 `ShowWindow(SW_HIDE)` console-hide approach works in classic Windows console (`conhost.exe`) but not in **Windows Terminal**, which is the default host on Windows 11. In WT, the visible window belongs to the Terminal process, not the PowerShell process — `ShowWindow` on PowerShell's pseudo-console handle has no visible effect. Result: the launcher window stayed open for the entire EQ session.

**Fix:** redesigned the post-exit `eqclient.ini` re-stamp so the launcher doesn't need to stay alive at all. The locked-settings application now happens *before* launching EQ rather than *after exit*. Same end state (locked keys stay locked across sessions; any drift gets caught on the next launch), much simpler. PowerShell launches EQ and exits immediately — visible terminal closes, EQ runs independently. Works in conhost, Windows Terminal, and any other PowerShell host.

Side effect: removed the `Add-Type` P/Invoke block entirely. One less AV-heuristic-flaggable pattern in the launcher script.

## v1.0.5 — 2026-05-12

Two real bugs caught, both critical.

**THE BIG ONE — manifest BOM made every auto-update a silent no-op since v1.0.1.**

PowerShell 5.1's `Set-Content -Encoding UTF8` writes a UTF-8 BOM (`EF BB BF`) at the start of the file. `Invoke-RestMethod` in PS 5.1 **cannot parse JSON that starts with a BOM** — it silently fails and returns the raw response as a *string* instead of the parsed object. The launcher's `foreach ($entry in $manifest.files)` then iterated zero times (a string has no `.files` property), no files were ever downloaded or hash-verified, but `$allOk` stayed true so the version stamp advanced anyway. The integrity check inside the same loop also ran zero times — couldn't catch the lie.

Three fixes, layered:

1. **`build-release.ps1`** now writes `manifest.json` as UTF-8 **without** BOM via `[System.IO.File]::WriteAllText` + `UTF8Encoding($false)`. Root cause squashed at the source.
2. **Launcher: defensive BOM stripping** via new `Get-JsonFromUrl` function. Downloads JSON as raw bytes, strips a leading `EF BB BF` if present, then `ConvertFrom-Json`. Belt and suspenders in case anyone writes a manifest with a BOM later.
3. **Launcher: manifest sanity check**. After parsing, verify `$manifest.tag` is non-empty AND `$manifest.files` has at least one entry. If either is missing, the update is skipped and the version stamp is NOT advanced. This is the assertion that would have caught v1.0.1-v1.0.4's silent no-ops three releases ago.

**Console window now hides during gameplay.**

The visible PowerShell window correctly showed the update flow at launcher start, but then stuck around for the entire EQ session because `Start-Process -Wait` keeps the launcher alive for the post-exit `eqclient.ini` re-stamp. Matches no other Windows game launcher. Fixed by hiding the console (Win32 `ShowWindow(hwnd, SW_HIDE)` via `Add-Type` P/Invoke) immediately before launching `eqgame.exe`. The PowerShell process keeps running in the background, waits for EQ to exit, does the silent re-stamp, then exits cleanly. No more visible launcher window during gameplay. Wrapped in try/catch so a failed `Add-Type` (e.g., AV intervention) falls through gracefully — console stays visible rather than blocking launch.

## v1.0.4 — 2026-05-12

Self-promote no longer triggers a spurious flicker on visible launches.

**Bug:** The v1.0.1-v1.0.3 self-promote check used `Process.MainWindowHandle == IntPtr.Zero` as a proxy for "PowerShell was started hidden". But on a freshly-started visible PowerShell process, `MainWindowHandle` stays at `IntPtr.Zero` for the first ~50-100ms while the .NET `Process` object catches up to the Win32 window creation — so the self-promote check fired during that window, even though we were already visible. Result: a brief flash of the parent process before the (correctly-visible) child appeared.

**Fix:** Inspect our own process's command line via `Get-CimInstance Win32_Process` and look for a literal `-WindowStyle Hidden` argument. That's the definitive test for "was I launched hidden" — no race condition, no false positives. Falls back to the old `MainWindowHandle` proxy if CIM is unavailable (defensive only; CIM should work on all supported Windows versions).

The regex accepts variations: `-WindowStyle Hidden`, `-w hidden`, `-W "Hidden"`, etc. — anything PowerShell itself would accept.

## v1.0.3 — 2026-05-12

Bug-fix release. Three issues caught by the first auto-update tests on Alex's install.

**Launcher (`Launch_EQ.ps1`):**

- **Fix: self-promote path quoting** (v1.0.2 regression). When `$PSCommandPath` contained spaces (`Theo and Co\Launch_EQ.ps1`), the `Start-Process powershell.exe -ArgumentList @(...)` array-join produced an unquoted path on the child's command line — the child PowerShell parsed only up to the first space and failed to find the script. Two PowerShell windows would flash and vanish, EQ wouldn't launch. Now wraps `$PSCommandPath` in explicit quotes.
- **Fix: self-promote infinite-loop guard.** Set `THEO_LAUNCHER_PROMOTED=1` env var before spawning the visible child; child inherits it and skips the self-promote check. Prevents recursion if the new visible PowerShell hasn't fully materialized its window handle by the time it runs the check.
- **Fix: silent `Move-Item` failure.** `Move-Item` without `-ErrorAction Stop` raises a non-terminating error on failure, but the code didn't check `$?`, so a failed replacement (most commonly: the running launcher trying to replace itself with a file the OS still has a lock on) would proceed as if successful — the version stamp advanced even though the file didn't update. Now: `-ErrorAction Stop` + per-file try/catch; on failure the `.new` is **kept on disk** and `$allOk` is marked false. The new `Resolve-PendingUpdates` function at launcher start picks up leftover `.new` files on the next launch (when the file is no longer locked) and applies them.
- **New: post-update integrity verification.** After the download loop, re-hash every managed file and compare against the manifest. Any mismatch fails the update (version stamp held at old value) regardless of whether `Move-Item` reported success. Defense-in-depth against the silent-failure scenario above and against externally-modified files (AV revert, manual edit).
- **New: `Resolve-PendingUpdates`** — checked at script start, before the network update check. Applies any `*.new` files left in the EQ root or `Theo and Co\` subfolder by a previous run.

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
