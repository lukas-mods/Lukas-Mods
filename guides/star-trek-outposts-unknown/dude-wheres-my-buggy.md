# Dude, Where's My Buggy? — Guide

**Star Trek: Outposts Unknown · v1.0.0 · by Luka's Mods**

Click a Cargo Buggy and see its whole route: every pickup and delivery stop in order, what it's moving at each one, and which stop it's on. This page is the full reference. The short version is on [the mod's Nexus page](https://www.nexusmods.com/startrekoutpostsunknown/mods/1).

- [Requirements](#requirements)
- [Install](#install)
- [Check That It Loaded](#check-that-it-loaded)
- [Everything It Does](#everything-it-does)
- [Questions](#questions)
- [Uninstall](#uninstall)
- [Compatibility](#compatibility)
- [Known Issues](#known-issues)
- [Report a Bug / Request a Feature](#report-a-bug--request-a-feature)

## Requirements

- Star Trek: Outposts Unknown on PC, the Steam version. Tested on Steam build 26124237.

- BepInEx (the mod loader) 6.0.0-be.790, the Unity IL2CPP win-x64 build. Its log's first line reads `BepInEx 6.0.0-be.790`. Download `BepInEx-Unity.IL2CPP-win-x64-6.0.0-be.790+4e98359.zip` from [BepInEx's build site](https://builds.bepinex.dev/projects/bepinex_be): it's build #790 in the list, the exact build this mod was tested with. BepInEx 6 is still a pre-release, and BepInEx 5 doesn't support games like this one.

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save. This one has been tested, but not on every setup. Back up your saves before you install it. Your saves are in your Steam folder (usually `C:\Program Files (x86)\Steam`), under `userdata\<your Steam account number>\3469910\remote\`. Copy that whole `remote` folder somewhere safe.

## Install

### Windows (by Hand)

1. Extract BepInEx into the folder that holds `StarTrekOutpostsUnknown.exe`. The `BepInEx` folder must sit right beside the .exe, not inside an extra folder named after the zip.
2. Start the game once and quit. This first start is slow, because BepInEx prepares itself for the game. Let it finish: later starts are back to normal speed.

3. Extract this mod's zip into the same folder, so that you have

   ```
   <game folder>\BepInEx\plugins\DudeWheresMyBuggy\DudeWheresMyBuggy.dll
   ```

   If Windows put everything inside an extra folder named after the zip, move its contents up into the game folder.

The first start after every game update is slow again, for the same reason. That's BepInEx, not a fault.

### Linux / Steam Deck (Proton)

Untested.

## Check That It Loaded

Open `<game folder>\BepInEx\LogOutput.log`. It should contain:

```
Dude, Where's My Buggy? 1.0.0 loaded (2 methods patched)
```

In the game, click a Cargo Buggy that's out on the map. Buggies parked inside their bay can't be clicked.

## Everything It Does

### The Route

Click a Cargo Buggy and its info panel opens, headed CARGO BUGGY. Under VEHICLE INFO, the mod adds a list of every stop on its current run, in order:

- **Stop headings:** `1. Picking Up From <building>` or `2. Delivering To <building>`.
- **What it's moving:** under each heading, the resources and amounts moved at that stop, as the game's own resource icons. Amounts are rounded down to whole numbers, the same way the game's storage counter shows them, and amounts under 1 aren't shown.

- **Job cards:** then the game's own Job Queue card for that job, with its name and icon.
- **Stops with no job behind them:** a stop that isn't part of a job shows just its heading, for example `1. Delivering To Large Storage Pad`.

- **Where it is now:** the heading of the stop it's on is amber. Finished stops are dimmed (heading, icons and card) while they're still on the route. The game drops some finished stops from the route, and then they leave the list.
- **Live:** the list updates while the panel is open, and rebuilds when the route changes.
- **Scrolling:** a long route scrolls inside the panel.
- **The task line:** `Task:` followed by the game's own description of what the vehicle is doing. When a vehicle isn't on a haul, the panel shows only that line and the footer, with no list: for example `Task: Parked / idle` for a buggy parked out on the map. The bays' panels (the Cargo Transport Bay and the Passenger Transport Bay) have the same VEHICLE INFO section, so they show the task line and the footer too: `Task: Docked`.

- **The footer:** `Dude, Where's My Buggy? 1.0.0 - Report Bugs on Nexus`, a dim line at the bottom of the mod's text: under the list, or under the task line when there's no route. It names the version you're running, which helps when you report a bug.

### What It Doesn't Do

It only displays. It changes nothing about how buggies drive, haul or refuel, and it doesn't change any job. The job cards it shows are copies with Cancel and Prioritize removed, and clicking them does nothing. Use the game's own Job Queue for that.

The pink glow on some cards is the game's: it means crew are working that job.

## Questions

### Why Do Two Stops Show the Same Card?

Because they're the same job. A job's pickup and its delivery are two stops on the route, and both show that job's card. The headings tell them apart.

### Why Is It in English When My Game Isn't?

The building names and the task description come from the game, so they follow your game's language. The mod's own words are English only: "Picking Up From", "Delivering To", "Task:", the footer, and the task texts it shows when the game gives none ("Parked / idle", "Returning to pad", "Docked", or the name of the vehicle's current action).

### Does It Work on Other Vehicles?

The route list appears when a vehicle is hauling cargo, as Cargo Buggies do. Other vehicles show only the task line and the footer: a Transport Buggy, for example, shows `Task: Transport Passengers`, the game's own description of what it's doing.

### Can I Remove It From a Game in Progress?

Yes. The mod doesn't store anything: it only reads the game while the panel is open. A save made with it installed was tested loading with the mod removed, and it loaded normally.

## Uninstall

Delete `<game folder>\BepInEx\plugins\DudeWheresMyBuggy\`. The mod writes no settings or other files, so nothing of it is left behind. BepInEx's own files (its log, its settings and its cache) belong to BepInEx: remove BepInEx separately if nothing else uses it.

## Compatibility

No known conflicts, but none have been tested yet. If two mods misbehave together, please [report it](https://github.com/lukas-mods/Lukas-Mods/issues/new/choose).

## Known Issues

- Linux / Steam Deck (Proton) is untested.
- Tested on the Steam version only.
- Amounts are remembered from the pickup. If you open the panel on a buggy that has already picked up, the mod never saw that pickup: the pickup stop shows its job card without amounts, and a delivery stop shows what the job still needs instead, as an estimate. Delivery figures have been checked against the game's storage once, and matched.
- After a game update, the job cards may stop appearing until the mod is updated. The mod first uses a job card the game has already loaded (for example, once you've opened the Job Queue), and only without one shows the stops without cards. The resource icons could also go missing after an update. Neither has been seen in play yet.

## Report a Bug / Request a Feature

This mod has no buttons of its own. Post on the Bugs tab of the mod's Nexus page, or [open a GitHub issue](https://github.com/lukas-mods/Lukas-Mods/issues/new/choose) and pick the **Bug Report** or **Feature Request** form. GitHub needs a free account.

Please attach `<game folder>\BepInEx\LogOutput.log`, and grab it before you restart the game, so it still holds what went wrong. Don't attach Player.log or ErrorLog.log, because they contain your Steam ID. If your game is installed inside your Windows user folder, the log shows that path, so remove your user name first.

---

Star Trek and related marks and logos are trademarks of CBS Studios Inc. This mod is not made by, affiliated with or endorsed by CBS Studios, Paramount, Playstack or Magic Fuel Games.
