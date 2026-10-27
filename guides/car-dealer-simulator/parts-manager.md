# Parts Manager — Guide

**Car Dealer Simulator · v1.1.1 · by Luka's Mods**

Buy a whole car's worth of parts in one click, straight into your warehouse storage at normal store prices. Restock workshop supplies and fill your Gas Pump Hub's tanks without the drive. This page is the full reference. The short version is on [the Nexus page](https://www.nexusmods.com/cardealersimulator/mods/54).

- [Requirements](#requirements)
- [Install](#install)
- [Check That It Loaded](#check-that-it-loaded)
- [Everything It Does](#everything-it-does)
- [Settings](#settings)
- [Uninstall](#uninstall)
- [Compatibility](#compatibility)
- [Known Issues](#known-issues)
- [Report a Bug / Request a Feature](#report-a-bug--request-a-feature)

## Requirements

- Car Dealer Simulator on PC, with the "Workshop Upgrades & Sprint Racing" update (October 2026) or later: Workshop supplies and Fuel Delivery use what that update added. Tested on the Steam version; the Microsoft Store / Xbox PC version is untested, and UE4SS installs differently there.
- UE4SS (the mod loader), an **EXPERIMENTAL** build: the game runs on Unreal Engine 5.4, which the stable UE4SS release doesn't support. Versions 1.1 and 1.1.1 were tested with the build whose log says `UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d`. This is the file on Nexus as "UE4SS v3.0.1-1150-g61b0e95e - Required Modding Framework" (Car Dealer Simulator mod 53). Despite its name, its log reports `#44afb36d`. (Version 1.0 was also tested with `UE4SS_v3.0.1-1164-g5e627997.zip`, whose log says `#5e627997`; 1.1 and 1.1.1 haven't been tested with that one.)

  UE4SS goes in `<game folder>\CarDealerSimulator\Binaries\Win64\`, so that `dwmapi.dll` and the `ue4ss\` folder sit next to `CarDealerSimulator-Win64-Shipping.exe`.
- Optional: the "Up 2 You" DLC, for the Sport and Race kits.

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save, and this one is no exception: it has been tested, but not on every setup. Back up your saves before you install it, and now and then while you play. They live in `%LOCALAPPDATA%\CarDealerSimulator\Saved\`.
> Parts Manager also spends real in-game money. While auto-stock is switched on it keeps buying, down to the balance you set in Keep Balance Above.

## Install

### Windows

Copy the `PartsManager` folder into

```
<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\
```

so that you have `...\ue4ss\Mods\PartsManager\enabled.txt`. `enabled.txt` is what turns the mod on.

**Updating from 1.0 or 1.1:** copy the new folder over the old one. Your `settings.txt` is kept.

### Linux / Steam Deck (Proton)

Partly tested, on 1.0 only. Under Proton, UE4SS and the mod loaded and attached to the tablet; buying, auto-stock and the 1.1 and 1.1.1 features have not been tested there. If you try it, please report how it went.

1. Install UE4SS and this mod into the same folders as on Windows (inside the game's Steam install folder).
2. In Steam: right-click Car Dealer Simulator > Properties > General > Launch Options, and enter exactly:
   ```
   WINEDLLOVERRIDES="dwmapi=n,b" %command%
   ```
   This tells Proton to load UE4SS's `dwmapi.dll`.

## Check That It Loaded

The game starting proves nothing. Check UE4SS's log instead, `...\Binaries\Win64\ue4ss\UE4SS.log`, which should contain:

```
Mod 'PartsManager' has enabled.txt, starting mod.
[PartsManager] v1.1.1 loaded
```

In the game, the blue Parts Manager icon appears on the tablet and on the office computer's taskbar once a save has loaded. It isn't on the main menu, so don't look for it there.

## Everything It Does

The tabs at the top switch between the parts kits (Stock, Sport, Race), Workshop and Fuel Delivery. Hover a ? icon or an Auto button for a short explanation; click a ? to show it in the STATUS line.

- **Overview:** one line with your account balance, reputation level, fame level and free storage, plus how many complete cars the parts in storage can build for each kit you have unlocked.
- **Buy Complete Cars:** choose Stock, Sport or Race and a number of cars (-10, -1, +1, +10), then press Buy. You get that many full sets, whatever is already in storage. Turn on "Body & Consumables" to add a windshield, plate repair kit, engine oil, coolant and brake fluid per car.
- **Parts Table** for the selected kit: each part's price, how many one car needs, how many in storage show under Ready (100%) and how many under Needs Repair, and how many cars that covers. Carried shows what's in your inventory and car trunks, for reference only. Every row has its own car count, so one click is a whole car's worth of that part: brake calipers for 2 cars buys 8.
- **Workshop Supplies** (Workshop tab): soap, wax, polish, grinder discs, putty, oscillating polisher pads and paint for the car wash and body shop, at store prices. Add buys 10 of a supply. Each row's Tier button shows the tier you're buying; click it for the next one: Basic, Large, Range+ or Eco-friendly (discs have Extra Durable in place of Large, and polisher pads have Extra and Eco).
- **Fuel Delivery** (Fuel Delivery tab): fills your Gas Pump Hub's tanks at the gas station's price per gallon, without the drive. Each tank has +10%, +25%, +50% and Fill, and the All Tanks row does every unlocked tank at once. One tank unlocks per Gas Pump Hub level; locked tanks show "Locked" and the level that unlocks them. It needs the Gas Pump Hub upgrade (Upgrades app on your tablet) and your own mobile fuel tank (sold at the gas station); the tab shows a padlock until you have both. It works only with your dealership loaded (otherwise it says "go back to your dealership"), and it takes about a minute after loading to read your tank levels. If the game's pump price can't be read, it uses $3.07, the pump's usual price, and says so.
- **Auto-Stock:** checks every 30 seconds while you play and buys whatever is below its target. It starts about a minute after a save has loaded, and never spends below the balance you set in "Keep Balance Above". Buying by hand is not limited by it.
  - **Auto Stock / Sport / Race:** keeps N complete cars of that kit in storage. With "Body & Consumables" on, each car gets its own, so 5 Stock + 5 Sport = fluids for 10.
  - **Auto Fuses:** keeps N of each fuse size in storage, buying packs of 3 as needed.
  - **Auto Supplies:** keeps N of each workshop supply, in the tier picked on the Workshop tab.
  - **Auto Fuel:** when your unlocked hub tanks together drop below 10% of their capacity, fills them all to full at the pump's price. It never tops up a little at a time. It starts about 3 minutes after your dealership loads, needs your own mobile fuel tank, and never spends below Keep Balance Above either.
  - **Count Worn Parts** (called "Count Parts Needing Repair" in 1.0) decides whether Needs Repair parts count as stock, for both auto-stock and the complete-car counts.

### It's a Normal Purchase

Everything is bought at normal store prices and paid from your balance. Your bank app lists it as "Buying items: Parts Manager", and fuel as "Fuel delivery: Parts Manager". A purchase you can't afford, or that won't fit in storage, is refused before anything is charged: the game's error sound plays and the app says why. The parts and supplies are normal game items, and they stay in storage if you uninstall the mod.

### It Won't Spend Your Money Unasked

A brand-new career always starts with auto-stock paused. Click any Auto button in the app when you want it to start. If you play more than one career, set `pause_auto_on_load=1` in `settings.txt` and auto-stock pauses after every save load, with an on-screen notice, until you press an Auto button again.

### Sport and Race Kits

They need the "Up 2 You" DLC, and unlock once every part in them is unlocked by fame level. Until then their tabs show a padlock, and clicking one tells you what is missing. Without the DLC only Stock can be bought.

### What It Doesn't Do

It doesn't sell parts, discount them or repair them, and it only buys into your warehouse storage and your Gas Pump Hub's tanks. Tuning shop items, empty canisters and exhaust tape are left out on purpose.

## Settings

`settings.txt` in the mod folder remembers your choices. Its `per_car.<ProductID>=<amount>` lines set how many of each body part or consumable "Body & Consumables" buys per car; set one to 0 to skip it.

Other keys it writes as you use the app: `pause_auto_on_load` (see [It Won't Spend Your Money Unasked](#it-wont-spend-your-money-unasked)), `count_worn`, `auto_supplies` and `auto_supplies_target`, `auto_fuel`, and `supply_tier.<item ID>` once you pick a tier (the game's own ID, e.g. `supply_tier.Sandpaper=Large` for discs on Extra Durable). A 1.0 `settings.txt` is read as it is.

## Uninstall

Delete `...\ue4ss\Mods\PartsManager\`. What you bought stays: parts and supplies are ordinary items in your storage, and delivered fuel is in your tanks.

## Compatibility

No known conflicts. Parts Manager was tested alongside other mods for this game, but mods change over time, so there's no promise about how any of them will work with it after an update. If two mods misbehave together, please [report it](https://github.com/lukas-mods/Lukas-Mods/issues/new/choose).

## Known Issues

- Linux / Steam Deck is only partly tested: see [the Proton install notes](#linux--steam-deck-proton).
- Settings are shared by every career, because the game's saves don't say which career they belong to. Auto-stock targets and switches follow you from one career to the next. See [It Won't Spend Your Money Unasked](#it-wont-spend-your-money-unasked).
- Tested on the Steam version only.
- Workshop supplies and Fuel Delivery need the "Workshop Upgrades & Sprint Racing" update (October 2026), and the newer supply tiers come with the "New Materials & Manager Features" update (October 2026). How the mod behaves on an older game build is untested.
- Fuel Delivery works only with your dealership loaded, and tank levels take about a minute to read after loading.
- Fuel Delivery finds your mobile fuel tank only once you've been near it since loading the save. If the tab says you need one and you own one, go near it, then try again.

## Report a Bug / Request a Feature

Use the buttons in the app's header. "Report a Bug" saves a report file in the mod folder, with your Windows user name removed, and opens the GitHub issue form: drag the file in and press Submit. The report lists your installed UE4SS mods and the game build. GitHub needs a free account. No account? Post on [the mod's Nexus page](https://www.nexusmods.com/cardealersimulator/mods/54) instead. Under Proton, opening the browser and file manager this way hasn't been verified yet.
