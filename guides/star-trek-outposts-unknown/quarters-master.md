# Quarters Master — Guide

**Star Trek: Outposts Unknown · v1.0.0 · by Luka's Mods**

See where your crew sleeps. When you pick crew for a habitat, their portraits carry the game's planet or ship icon, and crew cards get a QUARTERS row. This page is the full reference. The short version is on [the mod's Nexus page](https://www.nexusmods.com/startrekoutpostsunknown/mods/3).

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

- Star Trek: Outposts Unknown on PC, the Steam version. Tested on Steam build 26239730.

- BepInEx (the mod loader) 6.0.0-be.790, the Unity IL2CPP win-x64 build, the exact build this mod was tested with. Get it from [our BepInEx pack on Nexus Mods](https://www.nexusmods.com/startrekoutpostsunknown/mods/2). Its log's first line reads `BepInEx 6.0.0-be.790`. BepInEx 6 is still a pre-release, and BepInEx 5 doesn't support games like this one.

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save. This one has been tested, but not on every setup. Back up your saves before you install it. Your saves are in your Steam folder (usually `C:\Program Files (x86)\Steam`), under `userdata\<your Steam account number>\3469910\remote\`. Copy that whole `remote` folder somewhere safe.

## Install

### With Vortex

1. Install our [Star Trek: Outposts Unknown extension for Vortex](https://www.nexusmods.com/site/mods/2507): download it and drop its zip onto Vortex's Extensions page.
2. Set Star Trek: Outposts Unknown to be managed by Vortex (Games, then Manage). The extension installs BepInEx for you if it's missing.
3. The Nexus page doesn't have a Vortex download button yet, so download this mod's zip manually, then drag it onto Vortex's Mods page and enable it. Vortex puts it in the right folder.

### Windows (by Hand)

1. Extract BepInEx into the folder that holds `StarTrekOutpostsUnknown.exe`. The `BepInEx` folder must sit right beside the .exe, not inside an extra folder named after the zip. Skip this step if you already have it for another mod.
2. Start the game once and quit. This first start is slow, because BepInEx prepares itself for the game. Let it finish: later starts are back to normal speed.

3. Extract this mod's zip into the same folder, so that you have

   ```
   <game folder>\BepInEx\plugins\QuartersMaster\QuartersMaster.dll
   ```

   If Windows put everything inside an extra folder named after the zip, move its contents up into the game folder.

The first start after every game update is slow again, for the same reason. That's BepInEx, not a fault.

### Linux / Steam Deck (Proton)

Untested.

## Check That It Loaded

Open `<game folder>\BepInEx\LogOutput.log`. It should contain:

```
Quarters Master 1.0.0 loaded (4 methods patched)
```

In the game, open a habitat and pick its crew: the portraits carry their badges. Or hover over a crew portrait to see the QUARTERS row.

## Everything It Does

### Badges in the Habitat Picker

When you pick crew for a habitat, portraits of crew with a bed get a small round badge in the top-right corner (the rank stripes stay top-left):

- **Planet icon:** they have a bed in a habitat.
- **Ship icon:** they sleep aboard the ship.

The icons and their round backing are the game's own, read from the game while it runs. The mod ships no images.

### Crew Without a Habitat Bed Come First

The habitat picker lists crew who don't have a bed in a habitat (such as ship sleepers) first, so the people you're looking for are at the top. Everyone else follows in the game's own order, and within each group the game's order is kept too.

### A QUARTERS Row on Crew Cards

Under STATIONED, crew cards get a new row, QUARTERS:

- the planet's name, in capitals, for crew with a bed in a habitat;
- `SHIP` for crew who sleep aboard the ship.

It's on the hover card over a portrait, the crew info panel, and the worker tooltip in a building's crew slots.

### Habitat Pickers Only

The badges and the new order only appear when you pick crew for a habitat. Job pickers are unchanged.

### What It Doesn't Do

It only displays. It doesn't assign, move or unassign anyone, and it doesn't change anything else in the game. The only thing it changes is the order the habitat picker lists crew in.

## Questions

### Why Is QUARTERS in English When My Game Isn't?

The planet name comes from the game. The mod's own words are English only: `QUARTERS` and `SHIP`.

### Can I Remove It From a Game in Progress?

The mod writes nothing into your save: it only reads the game. Removing it from a save made with it installed hasn't been tested yet, so keep your save backup.

## Uninstall

Delete `<game folder>\BepInEx\plugins\QuartersMaster\`. The mod writes no settings or other files, so nothing of it is left behind. In Vortex, disable or remove it on the Mods page. BepInEx's own files (its log, its settings and its cache) belong to BepInEx: remove BepInEx separately if nothing else uses it.

## Compatibility

Works alongside [Dude, Where's My Buggy?](https://www.nexusmods.com/startrekoutpostsunknown/mods/1): both were loaded together in testing, and no error was logged. No other mods have been tested with it. If two mods misbehave together, please [report it](https://github.com/lukas-mods/Lukas-Mods/issues/new/choose).

## Known Issues

- Linux / Steam Deck (Proton) is untested.
- Tested on the Steam version only.
- Crew with no bed at all haven't been seen in play yet. The mod is built to show them with no badge and `NONE` on their card.
- After a game update, the badges could go missing until the mod is updated, because they use the game's own icons. The QUARTERS row doesn't depend on them. Neither has been seen in play yet.

## Report a Bug / Request a Feature

This mod has no buttons of its own. Post on the Bugs tab of the mod's Nexus page, or [open a GitHub issue](https://github.com/lukas-mods/Lukas-Mods/issues/new/choose) and pick the **Bug Report** or **Feature Request** form. GitHub needs a free account.

Please attach `<game folder>\BepInEx\LogOutput.log`, and grab it before you restart the game, so it still holds what went wrong. Don't attach Player.log or ErrorLog.log, because they contain your Steam ID. If your game is installed inside your Windows user folder, the log shows that path, so remove your user name first.

---

Star Trek and related marks and logos are trademarks of CBS Studios Inc. This mod is not made by, affiliated with or endorsed by CBS Studios, Paramount, Playstack or Magic Fuel Games.
