# Installed Mods — Guide

**Car Dealer Simulator · v1.0 · by Luka's Mods**

See your installed UE4SS mods and switch them on or off from the game's title menu. Installed Mods adds an INSTALLED MODS button to the title menu, and it opens a list of your mods. This page is the full reference. The short version is on [the mod's Nexus page](https://www.nexusmods.com/cardealersimulator/mods/59).

- [Requirements](#requirements)
- [Install](#install)
- [Check That It Loaded](#check-that-it-loaded)
- [Everything It Does](#everything-it-does)
- [What It Changes on Disk](#what-it-changes-on-disk)
- [Questions](#questions)
- [Uninstall](#uninstall)
- [Known Issues](#known-issues)
- [Report a Bug / Request a Feature](#report-a-bug--request-a-feature)

## Requirements

- Car Dealer Simulator on PC, the Steam version. The Microsoft Store / Xbox PC version is untested.
- UE4SS, an **EXPERIMENTAL** build: 3.0.1 experimental, Git SHA `44afb36d`, the same build Parts Manager uses. The stable release doesn't support this game's version of Unreal Engine. With Vortex, it's installed for you.
- No DLC needed.

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save. Installed Mods works on the title menu and never opens a save, but back up your saves before you install any mod: copy `%LOCALAPPDATA%\CarDealerSimulator\Saved\` somewhere safe. Switching another mod off or on is the same as renaming its `enabled.txt` yourself: what that mod does to your save when it's missing is up to that mod.

## Install

### With Vortex

1. Set Car Dealer Simulator to be managed by Vortex (Games, then Manage).
2. Drag this mod's zip onto Vortex's Mods page and enable it. Vortex puts it in the right folder and installs UE4SS for you if it's missing.

### By Hand

1. Install the UE4SS build above, if you don't already have it for another mod.
2. Copy the `InstalledMods` folder from this mod's zip into the game's UE4SS Mods folder, so that you have

   ```
   <game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\InstalledMods\Scripts\main.lua
   ```

   The folder already holds an `enabled.txt`, so UE4SS starts it. Nothing to add to `mods.txt`.

## Check That It Loaded

Start the game. On the title menu, INSTALLED MODS sits just above QUIT. Or open `<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\UE4SS.log`. It should contain:

```
[InstalledMods] v1.0 loaded
```

## Everything It Does

### The INSTALLED MODS Button

On the title menu, the screen you see when the game starts, just above QUIT. It's in the game's own style and grows on hover like the game's buttons. The button is on the title menu only: there's no Installed Mods app on the tablet or the office computer.

### The List

Click INSTALLED MODS and the list opens as a page of the title menu. Back, or Esc, takes you back to the menu. The top of the page always shows "Installed Mods — by Luka's Mods" and "Added by a mod. Not part of Car Dealer Simulator.", so it's clear it isn't the game's.

Each mod folder in your UE4SS Mods folder gets a row:

- **Mod:** the name the mod gives in its `mod-support.json`, or else its folder name.
- **Status:** ON or OFF, and whether a change is waiting (see below).
- **Version:** from the mod's `mod-support.json`, or else the version the mod wrote to UE4SS.log when it loaded. A mod that gives neither shows `–`.

UE4SS's own built-in mods (such as ConsoleEnablerMod and Keybinds) aren't listed. They stay in the bug report, and they can't be switched.

### Switching a Mod On or Off

1. Click **Turn On** or **Turn Off** on its row. The status now reads `ON, not saved` or `OFF, not saved`. Click again to undo.
2. Press **Apply**. The status reads `ON at next start` or `OFF at next start`.
3. A box asks **Quit the Game?** Press **Quit Game** to quit now, or **Later** (or Esc) to carry on. Either way, your changes take effect the next time you start the game.

Switches you haven't applied are lost if the game quits first.

### Rows Without a Switch

- `(this mod)`: Installed Mods itself.
- `(set in mods.txt)`: the mod is switched by a line in UE4SS's `mods.txt`. Installed Mods only changes a mod's `enabled.txt`, so it leaves these alone. Change the line in `mods.txt` yourself if you need to.
- `(no mod files)`: the folder has nothing UE4SS can start and no `enabled.txt`.
- `MIXED (see mods.txt)`: the mod has an `enabled.txt`, but `mods.txt` says 0. Which of the two UE4SS follows hasn't been checked, so the list shows MIXED instead of guessing. Remove the mod's line from `mods.txt`, or its `enabled.txt`, so only one remains.

### If the Page View Doesn't Work

The page is built on the game's own menu, so a game update could break it. Then the list opens as a window over the title menu instead, and says: "Opened as a window over the menu: this game version wouldn't open it as a menu page." Everything else works the same. Please [report it](#report-a-bug--request-a-feature) if you see that line.

## What It Changes on Disk

- **A mod's `enabled.txt`, only when you press Apply.** Turning a mod off renames its `enabled.txt` to `enabled.txt.off`, replacing any older `enabled.txt.off` in that folder. Turning it on renames it back, or writes an empty `enabled.txt` if there's none to restore. Nothing else in a mod's folder is touched. It never switches UE4SS's built-in mods or itself, and never changes `mods.txt`.
- **Its own bug report**, only when you press Report a Bug: `InstalledMods-bug-<date>-<time>.txt` in this mod's folder.
- **Nothing online.** It makes no web requests of its own. Report a Bug and Request a Feature open GitHub's forms in your browser.
- **Nothing in your saves.** It never opens a save.

## Questions

### Why Doesn't My Mod Show a Version?

The mod gives none that Installed Mods can read.

### Why Can't I Switch One of My Mods?

Its row says why: `(set in mods.txt)`, `(no mod files)`, `(this mod)` or `MIXED`. See [Rows Without a Switch](#rows-without-a-switch).

### I Use Vortex. Can I Switch My Vortex Mods Here?

If Vortex installed a mod, switch it on or off in Vortex instead. Vortex keeps track of that mod's files, `enabled.txt` included.

### Does It Turn Mods Off While I Play?

No. Every change takes effect the next time you start the game.

### Why Is It in English When My Game Isn't?

Installed Mods' own words are English only. Mod names come from each mod.

## Uninstall

Delete `<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\InstalledMods\`. In Vortex, disable or remove it on the Mods page.

**Removing Installed Mods doesn't undo your switches.** A mod you switched off stays off. Switch it back on before you uninstall, or afterwards rename that mod's `enabled.txt.off` back to `enabled.txt`.

## Known Issues

- Which wins when a mod has an `enabled.txt` and `mods.txt` says 0 hasn't been checked. Such mods show `MIXED` and have no switch.
- A game update could stop the list opening as a menu page. It then opens over the title menu instead (see [If the Page View Doesn't Work](#if-the-page-view-doesnt-work)).
- What Vortex does with a Vortex-installed mod that was switched here hasn't been checked. Switch those mods in Vortex.
- Linux / Steam Deck (Proton) is untested.
- The Microsoft Store / Xbox PC version is untested.

## Report a Bug / Request a Feature

The buttons are at the top of the Installed Mods page.

- **Report a Bug** saves a report file in this mod's folder, opens the folder with the file selected when it can, and opens GitHub's bug form in your browser. Alt-tab to the browser, drag the report file into the form and press Submit. The report lists your installed mods and holds no file paths, so your Windows user name isn't in it.
- **Request a Feature** opens GitHub's feature request form in your browser.

GitHub needs a free account. You can also post on the Bugs tab of [the mod's Nexus page](https://www.nexusmods.com/cardealersimulator/mods/59).
