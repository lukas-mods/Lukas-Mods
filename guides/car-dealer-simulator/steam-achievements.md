# Steam Achievements — Guide

**Car Dealer Simulator · v1.0.1 · by Luka's Mods**

Every Steam achievement in the game, in an app on your tablet and office computer, and the ones you care about on a small panel while you play. This page is the full reference. The short version is on [the Nexus page](https://www.nexusmods.com/cardealersimulator/mods/56).

- [Requirements](#requirements)
- [Install](#install)
- [Check That It Loaded](#check-that-it-loaded)
- [Everything It Does](#everything-it-does)
- [Settings](#settings)
- [Questions](#questions)
- [Uninstall](#uninstall)
- [Compatibility](#compatibility)
- [Known Issues](#known-issues)
- [Report a Bug / Request a Feature](#report-a-bug--request-a-feature)

## Requirements

- Car Dealer Simulator on PC, the Steam version, played signed in to Steam. Tested on game build 26053251. The Microsoft Store / Xbox PC version is untested.
- UE4SS (the mod loader), an **EXPERIMENTAL** build: the game runs on Unreal Engine 5.4, which the stable UE4SS release doesn't support. Tested with the build whose log says `UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d`. This is the file on Nexus as "UE4SS v3.0.1-1150-g61b0e95e - Required Modding Framework" (Car Dealer Simulator mod 53). Despite its name, its log reports `#44afb36d`.

  UE4SS goes in `<game folder>\CarDealerSimulator\Binaries\Win64\`, so that `dwmapi.dll` and the `ue4ss\` folder sit next to `CarDealerSimulator-Win64-Shipping.exe`. With [Vortex](#vortex), it's installed for you.
- No DLC needed.

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save, and this one is no exception: it has been tested, but not on every setup. Back up your saves before you install it, and now and then while you play. They live in `%LOCALAPPDATA%\CarDealerSimulator\Saved\`.

## Install

### Vortex

In Vortex, find Car Dealer Simulator under Games and click Manage. Then download this mod's zip from [Nexus Mods](https://www.nexusmods.com/cardealersimulator/mods/56), drag it onto Vortex's Mods page and enable it. Vortex puts it in the right folder, and installs UE4SS for you if it's missing.

### Windows (by Hand)

Copy the `SteamAchievements` folder into

```
<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\
```

so that you have `...\ue4ss\Mods\SteamAchievements\enabled.txt`. `enabled.txt` is what turns the mod on. There's nothing else to set up: the mod finds your Steam folder and account by itself.

### Linux / Steam Deck (Proton)

Untested. If you try it, please report how it went.

1. Install UE4SS and this mod into the same folders as on Windows (inside the game's Steam install folder).
2. In Steam: right-click Car Dealer Simulator > Properties > General > Launch Options, and enter exactly:
   ```
   WINEDLLOVERRIDES="dwmapi=n,b" %command%
   ```
   This tells Proton to load UE4SS's `dwmapi.dll`.

## Check That It Loaded

The game starting proves nothing. Check UE4SS's log instead, `...\Binaries\Win64\ue4ss\UE4SS.log`, which should contain:

```
Mod 'SteamAchievements' has enabled.txt, starting mod.
[SteamAchievements] v1.0.1 loaded
```

In the game, the purple trophy icon appears on the tablet and on the office computer once a save has loaded. It isn't on the main menu, so don't look for it there.

## Everything It Does

### The App

Open it from the purple trophy icon on your tablet or office computer.

- **The List:** every Steam achievement for the game, 203 of them. Each row has the icon, title, Steam's description, a progress bar and a count such as `23 / 25 (28.0% have it)`: the percentage is how many Steam players have unlocked it. An achievement with no counter shows `Locked (x% have it)` until you earn it, and a finished one shows `Done`.
- **Tiers:** tiered achievements share one row, and the title and icon follow the tier you're on. The squares under the icon show each tier: green done, white the one you're on, grey still to come.
- **Pages:** 25 rows per page, with `< Prev` / `Next >`. The top line shows your total, e.g. `79 / 203 unlocked   Page 1 of 4`.
- **Filters:** All, Tracked, In Progress (everything not finished yet) and Done.
- **Search:** type in the search box to narrow the list. Typing there doesn't move your character.
- **Track / Untrack:** Track pins an achievement to the HUD panel, up to 4 at a time. A 5th is refused with "You're already tracking 4. Untrack one first." Untrack frees the slot. Finished achievements have no button.
- **HUD Panel: ON/OFF** hides or shows the panel.

### The HUD Panel

A small panel at the top right of your screen, level with the reputation box. It takes no clicks: everything is done in the app.

- **Tracked:** your tracked achievements. The first two show in full; the rest are shorter rows.
- **Suggested:** with nothing tracked, the 4 easiest achievements you haven't finished. Counters are ranked by how close they are to done, achievements without a counter by how many players have them. Hidden achievements are never suggested. A note underneath says where to choose your own.
- A tracked achievement drops off the panel by itself once you finish it.

### Live Progress

Counts move the moment the game reports them to Steam. Wash a car and "Wash down 50 cars with water" goes from 47 to 48 on the spot.

### Hidden Achievements

Until you unlock one, it shows only "Hidden achievement", "Details appear when it's unlocked." and Steam's locked art, in the list and on the panel.

### What It Doesn't Do

It reads your progress and never unlocks anything. It never writes Steam's files, and nothing is downloaded while you play: the icons and player percentages ship with the mod.

## Settings

`settings.txt` in the mod folder is created the first time you change something, and remembers your choices:

| Key | What it does |
|---|---|
| `widget` | `1` shows the HUD panel, `0` hides it. The app's HUD Panel button sets it. |
| `track` | Your tracked achievements. Track and Untrack set it. |
| `steam_path` | Only needed if the app says it can't find your Steam folder, e.g. `steam_path=D:\Games\Steam`. |

The tracked list is shared by every career and survives restarting the game.

## Questions

### Why Is the Panel Ahead of Steam?

The mod counts progress the moment the game reports it. Steam stores progress only from time to time, so its overlay and its page catch up later. Nothing is counted twice.

### Why Doesn't a Car I Sold on Installments Count Yet?

It counts when the installments are complete, the same as on Steam.

### Can It Unlock Achievements?

No. It only reads.

### Which Steam Account Does It Read?

On a PC with several Steam accounts, the one that signed in to Steam most recently. Switch accounts and the panel switches with you.

### It Says "Steam Folder Not Found"

Your Steam folder isn't in a usual place. The mod looks in `Program Files (x86)\Steam`, `Program Files\Steam` and `\Steam` on drives C to H. Add a `steam_path=` line to `settings.txt` (see [Settings](#settings)) and restart the game.

### An Achievement Has No Icon or Player Percentage

It was added by a game update after this version of the mod was built. It shows without an icon or player percentage until the mod is updated.

## Uninstall

Delete `...\ue4ss\Mods\SteamAchievements\`. The mod writes only `settings.txt` and bug-report files, both in its own folder, so nothing is left behind.

## Compatibility

No known conflicts. Steam Achievements was tested alongside other mods for this game, including Parts Manager, but mods change over time, so there's no promise about how any of them will work with it after an update. If two mods misbehave together, please [report it](https://github.com/lukas-mods/Lukas-Mods/issues/new/choose).

## Known Issues

- Linux / Steam Deck (Proton) is untested.
- Tested on the Steam version only.
- On a PC with several Steam accounts, it reads the most recently signed-in one. See [Which Steam Account Does It Read?](#which-steam-account-does-it-read)
- Achievements added by a later game update show without an icon or player percentage until the mod is updated.

## Report a Bug / Request a Feature

Use the buttons in the app's header. "Report a Bug" saves a report file in the mod folder, with your Windows user name and Steam account numbers removed, and opens the GitHub issue form: drag the file in and press Submit. GitHub needs a free account. No account? Post on [the mod's Nexus page](https://www.nexusmods.com/cardealersimulator/mods/56) instead.

---

Achievement icons, names and descriptions belong to Garage Monkeys and are shown unmodified from Car Dealer Simulator on Steam.

Steam is a trademark of Valve Corporation. This mod is not made by, affiliated with or endorsed by Valve.
