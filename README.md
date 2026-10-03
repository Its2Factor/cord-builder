# Cord Builder

Cord Builder is a Windows GUI for installing build tools, setting up, building, updating, and injecting a local Vencord or Equicord source checkout. The GUI itself uses built-in Windows components and streams command output into the app.

The window layout lives in `CordBuilder.xaml`. `VencordEquicordBuilder.ps1` loads it and runs the app; it dot-sources `CordBuilder.Readiness.ps1` (step completion and source tracking), `CordBuilder.Discord.ps1` (Discord channels, injection and restore), `CordBuilder.Plugins.ps1` (the Plugins page) and `CordBuilder.Updates.ps1` (the update notice). The bundled `assets/cord-builder-logo.png` is used in the setup assistant and as the Windows window/taskbar icon.

## The window

- **Setup assistant** (first run only): four steps (Required tools, Source, Build, Install into Discord) with Back/Continue. It opens on the first unfinished step and moves forward when a step succeeds. While it's open, the tabs are replaced by a *First-time setup* label. Settings › **Open setup assistant** brings it back. Anyone upgrading with an existing verified build skips it.
- **Home**: one sentence about what matters now and a single button for the best next action, such as *Build & restart Discord*, *Install into Discord* or *Update & rebuild*. While source files are still being scanned it says *Checking files…* instead of claiming it's ready. A timeline card shows tools, source, build and Discord, with **Check again**, **Update**, **Re-inject** and **Restore stock** links. Discord reads *Patched with this folder* when it loads this checkout's build, or *Patched from a different folder* when another checkout patched it. Tiles summarise plugins, the Discord target and the last build, and **Recent** lists the last few verified steps (kept in `%LOCALAPPDATA%\CordBuilder\history.json`). **Run all steps** updates the source, builds and installs in one go.
- **Plugins**: every item in `src/userplugins`, with a green check, a red cross plus the exact reason it can't build, or an orange warning when two plugins use the same `definePlugin` name (only one of them loads) or a plugin replaces a built-in one. Each row shows when it last changed; hovering shows **Open** (VS Code if installed, otherwise File Explorer) and **Reveal**. The switch turns a plugin off by renaming it with a leading `_`, which the client's build skips; nothing is deleted, and turned-off plugins are listed separately. Search filters by folder or plugin name. Dot-folders such as `.vscode` and hidden files are ignored.
- **Activity**: the full command output, with **Next issue** (jumps to the next error or failure), **Copy**, **Open log file** and **Clear**. An empty log shows a short explanation, and actions that need output stay disabled. Every session is also written to `%LOCALAPPDATA%\CordBuilder\logs` (the 20 newest are kept). The on-screen log keeps the latest ~6,000 lines and only auto-scrolls when you are already at the bottom.
- **Settings**: client (the only place to switch between Vencord and Equicord), source folder, Discord target with **Rescan**, development builds, shortcuts to the logs and Discord backup folders, and the app version.
- The **activity bar** along the bottom always shows the current status, the latest output line and, while a task runs, a progress bar and elapsed time. Click it to open Activity.

The window has rounded corners: Windows 11 draws them itself, and on Windows 10 the window is clipped to the same shape. It can be resized, snapped and maximized (maximized windows have square corners). Only one copy of Cord Builder can run at a time, so two builds can't touch the same checkout at once. Tool checks run in parallel in the background, so the window never freezes while Git, Node.js or pnpm is slow to answer.

## Run it

Double-click **`Launch Cord Builder.vbs`**. It launches the GUI without leaving a Command Prompt window open.

`Launch Cord Builder.cmd` remains as a compatibility fallback and immediately hands off to the hidden launcher.

You can also run the PowerShell entry point directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\VencordEquicordBuilder.ps1
```

Do not run the app as Administrator. Equicord's official guide warns that using an administrator terminal for its build commands can break a Discord installation.
Cord Builder enforces this for every action that changes, builds, or injects a project. It also rejects source locations inside Windows, Program Files, ProgramData, or a drive root.

## Personal folders and settings

Cord Builder uses the current Windows account's folders, not the account that supplied the app. It asks Windows for the user's Documents location, including OneDrive or redirected Documents. It checks for a matching Vencord/Equicord source checkout in Documents, local or OneDrive Documents, Documents/GitHub, source/repos, the user profile, and Desktop. If none is found, it proposes `<your Documents>\Vencord` or `<your Documents>\Equicord`; Prepare creates it later.

Use **Browse** for a checkout in a different location. That choice and the Discord channel are saved per Windows user in `%LOCALAPPDATA%\CordBuilder\settings.json`, tagged to the current account. A custom saved location is retained even if it has not been created yet or its drive is temporarily unavailable.

Old `builder.settings.json` files next to the launcher are no longer written. On first run, the app can migrate an existing source checkout from that file only when it is inside the current user's profile or known personal folders. Another user's saved paths and preferences are ignored, even if their source folders still exist on the computer. Legacy custom locations outside those personal folders must be selected once with Browse. Copying the app does not copy active personal settings.

## Guided workflow

Before the numbered steps, **Required tools** must verify Git, Node.js, and pnpm. Missing or broken tools lock every project action, even when an existing project has successful dependency or build markers.

1. Click **Install missing tools** once. The app installs missing or broken tools in order: Git, Node.js LTS (including npm), then pnpm. Working tools are reused.
2. Each tool is verified before the next one starts. No browser, terminal, system-wide installer, or app restart is needed.
3. Once all three pass, **Prepare project** unlocks. If a download or check fails, review the in-app output and click the same setup button to retry. **Stop running task** cancels setup and prevents the next tool from starting.

The project workflow then runs in this order:

1. **Prepare project** clones or safely updates the selected source repository and downloads dependencies. Before an update, tracked and untracked custom changes are placed in a verified Git safety stash, restored after the update, checked for unresolved conflicts, and left in the stash as a recovery copy. It uses `pnpm install --frozen-lockfile` for Vencord and `pnpm install --no-frozen-lockfile` for Equicord.
2. **Build** runs `pnpm build`, optionally with `--dev`, after dependencies are ready. A successful build automatically restarts the selected Discord channel. Build then shows **Build up to date** until source/plugin contents or the build mode change.
3. **Repair & inject into Discord** targets the selected installed Discord channel and runs the appropriate installer command. Before injection, Cord Builder closes only that selected channel and inspects its active version's resources. If `app.asar` is missing but the recoverable `_app.asar` remains, it creates a SHA-256-verified backup, restores the original file, and continues. It only unlocks when verified build output still matches the source. Injection also restarts the selected channel automatically.

**Open userplugins folder** (on the Plugins page and in the assistant's Build step) unlocks after preparation and opens the selected project's `src/userplugins` folder, creating that folder if needed. Add, edit, update, or remove plugin files there; the Plugins page only displays them.

**Restore stock** runs the client's own `pnpm uninject` for the selected channel after the same pre-check used for injection, confirms first, verifies the patch is gone, and restarts Discord.

**Source updates.** The source line on Home shows the branch, commit and how many upstream commits you are behind. Cord Builder checks upstream with a background `git fetch` (remote-tracking refs only, never your files) at start-up and every 30 minutes. When pnpm has rewritten `pnpm-lock.yaml` during an install, Prepare resets that generated file before updating so it can't conflict with upstream's new lockfile. Safety stashes are still created for your real changes, and the 10 newest Cord Builder backups are kept; older Cord Builder backups are dropped, and stashes you made yourself are never touched.

The Discord selector lists detected Desktop installations and defaults to **Discord Stable** when it is available. This selection affects only injection, patch verification, and restart; Vencord/Equicord source setup, plugins, and building remain shared. Stable, PTB, and Canary are passed to the installer by branch, while Discord Development is targeted by its installation location.

Restart is automatic; there is no restart checkbox, and old saved opt-out settings are ignored. After every verified build, the selected installed Discord channel is restarted. If it is not yet patched for this source checkout, the app explains that **Inject** is still needed to load the build. Failed, cancelled, or outdated builds do not restart Discord. With no installed target selected, the app reports that there is nothing to restart.

Immediately before restart, source contents and output are checked again. The restart helper first requests a graceful close, force-closes only the selected Discord channel if it does not exit, relaunches it through Discord's updater, and verifies that the process returns.

Changing the client, source folder, build mode, or plugin files updates the workflow state automatically. Cord Builder records successful dependency and build steps with tiny marker files inside the normally ignored `node_modules` and `dist` folders, so the enforced order survives reopening the app. An existing checkout must complete **Prepare project** once before later steps unlock.

Every completed step is verified before its checkmark appears:

- Required tools must run and report successful version checks. Git and Node downloads must match their official SHA-256 checksums. Node also checks its bundled npm before activating the runtime.
- Preparation verifies `package.json`, the required build/inject scripts, `pnpm-lock.yaml`, and pnpm's installed dependency store.
- Plugin folders are checked for valid entry-file layout before building; errors identify the items to fix through the folder button.
- A build must produce non-empty JavaScript output written after its input snapshot was captured. Source file contents must still match that snapshot after compilation.
- Injection is marked complete only while verified build output remains present and a matching Vencord/Equicord patch is found in the selected Discord Desktop channel. Existing valid injection is recognized, so rebuilding normally requires only a full Discord restart.
- Discord resource repair is limited to the exact known recoverable state. Missing or contradictory files stop the workflow with a clear error; the app does not guess, delete an installation, or touch roaming Discord data.

## Prerequisites



- [Git for Windows MinGit](https://gitforwindows.org/mingit.html) — when Git is missing or broken, the app downloads the official portable package designed for applications, verifies the release's SHA-256 checksum, and checks Git plus its HTTPS helper. No WinGet or administrator access is required.
- [Node.js](https://nodejs.org/) — if Node is missing, or Equicord detects a non-LTS release, the GUI downloads a private current-LTS Windows runtime from the official Node.js archive and verifies its published SHA-256 checksum. It does not replace the system installation.
- pnpm — when missing, the GUI installs a private copy under Cord Builder's Local AppData runtime folder

Managed tools are stored under `%LOCALAPPDATA%\CordBuilder\runtime`. Existing system installations and the system PATH are not changed. Only Cord Builder and its child commands use its private tool paths. Git/Node downloads use HTTPS, have time limits, validate extraction paths, and activate only after verification. pnpm installs from the official npm registry with package install scripts disabled. An internet connection is required; network restrictions or security-software blocks are reported in the app rather than bypassed.

The app checks tool output and exit codes, not just whether files exist. Equicord requires Node.js LTS; Vencord keeps its existing support for other working Node.js releases. **Check again** remains available if tools were changed outside the app. A broken cached npm installation triggers a fresh private Node.js repair instead of repeatedly reusing the broken copy.

## Detecting file changes

The app scans source contents in the background, with a short pause between scans. It compares SHA-256 content hashes and relative filenames, so additions, removals, renames, and same-size edits with unchanged timestamps are detected. No Refresh button or app restart is needed. The project's generated root `dist` directory is excluded, along with `node_modules`, `.git`, `.cache`, `.pnpm-store`, and `coverage` directories at every level. A plugin's nested `dist` files are still tracked as potential build inputs.

The last successful input snapshot is saved in `dist/.cord-builder-ready` together with the client, source location, and development mode. It survives reopening the app. Older timestamp-only markers require one new verified build. Source scans run off the UI thread. Linked plugin folders are tracked too; unreadable files, broken links, and directory-link loops are reported rather than silently omitted.

A fresh capture runs immediately before compilation, with another full comparison afterwards and before injection/restart. If files change during a build, it is not marked complete; finish editing and Build again.

## Plugin layout caveat

Place individual plugin folders directly under `src/userplugins`, each with a non-empty `index.ts` or `index.tsx`. Equicord folder names must use camelCase. Vencord also accepts standalone `.ts`/`.tsx` plugins. For a multi-plugin collection, copy its individual plugin folders rather than nesting the entire collection. The app does not edit plugin code or automatically repair layouts; the only change it makes is the `_` rename when you switch a plugin off or on.

You choose the client, Discord channel, and source location in the GUI and manage trusted plugins through the folder button. The app handles tool installation, building, injection, verification, and automatic restart. Discord itself must already be installed. Artifact and process checks do not prove that every plugin behaves correctly inside Discord.

## Update notice

`$script:UpdateRepository` in `VencordEquicordBuilder.ps1` names the GitHub repository (`owner/name`) whose latest release is compared with `$script:AppVersion`. When a newer, non-prerelease version is published, a *Cord Builder x.y available* notice appears in the title bar and opens that release's page. The check runs in the background at start-up and every 12 hours. It sends no personal data. Leaving the repository empty turns the check off.

## Optional `.exe` packaging

The `.ps1` is the actual app and the `.cmd` is a convenient launcher. If you later want a single-file executable, it can be wrapped with a PowerShell-to-EXE packager; the workflow does not require that packaging to run.

## Checks for developers

These checks do not install software or modify a Discord/source installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\VencordEquicordBuilder.ps1 -SelfTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\VencordEquicordBuilder.ps1 -StartupSelfTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Test-Prerequisites.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Settings.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Test-BuildTracking.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ProcessRunner.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-InjectionRepair.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-SafeSourceUpdate.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\InstallGit.ps1 -SelfTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\InstallNodeLts.ps1 -SelfTest
```

The same checks run on every push in GitHub Actions (`.github/workflows/self-tests.yml`). `-StartupSelfTest -PreviewPath <file.png>` also renders a PNG of each page next to that path.

The process-runner test starts and stops only its own test processes. Run it in a normal, non-administrator Windows session; restricted sandboxes may block Windows taskkill.

## Sources

- [Vencord: building from source](https://docs.vencord.dev/installing/)
- [Vencord: custom plugins](https://docs.vencord.dev/installing/custom-plugins/)
- [Equicord: building from source](https://docs.equicord.org/building-from-source)
- [Equicord: user plugins](https://docs.equicord.org/plugins)
