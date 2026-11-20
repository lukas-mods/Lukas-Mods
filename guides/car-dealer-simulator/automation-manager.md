# Automation Manager — Guide

**Car Dealer Simulator · v1.0.2 · by Luka's Mods**

Profiles for the automation platform. Automation Manager adds an app to the tablet and the office computer that sets up your cars' automation tasks and shows the whole shop at a glance. This page is the full reference. The short version is on [the mod's Nexus page](https://www.nexusmods.com/cardealersimulator/mods/60).

- [Requirements](#requirements)
- [Install](#install)
- [Check That It Loaded](#check-that-it-loaded)
- [Everything It Does](#everything-it-does)
- [What It Changes](#what-it-changes)
- [Uninstall](#uninstall)
- [Report a Bug / Request a Feature](#report-a-bug--request-a-feature)

## Requirements

- Car Dealer Simulator on PC. Tested on the Steam version, game build 26731899. The Microsoft Store / Xbox PC version is untested, and UE4SS installs differently there.
- UE4SS (the mod loader), an **EXPERIMENTAL** build: the game runs on Unreal Engine 5.4, which the stable UE4SS release doesn't support. Tested with the build whose log says `UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d`: [the one on Nexus Mods](https://www.nexusmods.com/cardealersimulator/mods/53), the same build Parts Manager uses. With Vortex, it's installed for you (see [Install](#install)).
- Optional: the "Up 2 You" DLC, for Sport and Race parts. Without it only Default and Stock are offered.

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save. Back up your saves before you install it, and now and then while you play: copy `%LOCALAPPDATA%\CarDealerSimulator\Saved\` somewhere safe. Automation Manager starts real tasks on your cars, takes parts from your storage for the mechanic, and posts real ads at the price it works out. Check a profile before you give it to a car.

## Install

### With Vortex

In Vortex, find Car Dealer Simulator under Games and click Manage. Then drag this mod's zip onto Vortex's Mods page and enable it. Vortex puts it in the right folder, and installs UE4SS for you if it's missing.

### By Hand

1. Install the UE4SS build above, if you don't already have it for another mod. UE4SS goes in `<game folder>\CarDealerSimulator\Binaries\Win64\`, so that `dwmapi.dll` and the `ue4ss\` folder sit next to `CarDealerSimulator-Win64-Shipping.exe`.
2. Copy the `AutomationManager` folder from this mod's zip into the game's UE4SS Mods folder, so that you have

   ```
   <game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\AutomationManager\enabled.txt
   ```

   `enabled.txt` is what turns the mod on.

### Updating (By Hand)

Copy the new `AutomationManager` folder over the old one and let Windows replace the files. Your profiles (`profiles.lua`) and Car Pickup settings (`delivery.lua`) aren't in the download, so they stay. Don't delete the old folder first, or they go with it.

**Linux / Steam Deck (Proton):** untested for Automation Manager. UE4SS needs the Steam launch option `WINEDLLOVERRIDES="dwmapi=n,b" %command%` to load under Proton. If you try it, please [report how it went](#report-a-bug--request-a-feature).

## Check That It Loaded

The game starting proves nothing. Open `<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\UE4SS.log`. It should contain:

```
Mod 'AutomationManager' has enabled.txt, starting mod.
[AutomationManager] v1.0.2 (... B, sum ...) loaded (running)
```

In the game, the Automation Manager app appears on the tablet and on the office computer once a save has loaded, not on the main menu.

## Everything It Does

The app has five tabs: Board, Cars, Car Pickup, Front Parking and Profiles. It opens on the Board. Every page has a one-line hint at the top, and Help in the app's header explains each part.

### Profiles

A profile picks which stations a car visits (Photo Studio, Paint Booth, Car Wash, Body Workshop, Mechanical Workshop, Air Compressor, Fuel Dispenser) and where it finishes (Front Parking, Side Parking, Underground Garage or Tuning Garage).

- **The mechanic step** can Replace Damaged parts with one part type, use Custom (a part type for every slot, all of them set; the car gets its task only once every part it needs is in storage, so it comes out complete), or Disassemble the car. The parts, fuses and fluids come from your storage, picked the way the game's own Automation tab picks them. Sport and Race parts need the Up 2 You DLC.
- **The Paint Booth step** paints the car a colour the profile picks.
- **Stations a car doesn't need are skipped**, by the game's own tests: fuel near full, tyres at pressure, body and looks already good, and a tuned car skips body, wash and paint. The mechanic is skipped too when there's nothing for it to do.
- Profiles can be renamed, and are saved in `profiles.lua` in the mod's folder.

### Giving Cars Their Tasks

Give a car on a parking spot near the warehouse a profile, and it gets its automation task through the game's own Add Automation Task. To give several cars the same profile, use Select Cars (or Shift-click, or Select in a car's panel) to tick them, then Set Profile. Select All ticks every car that can take one.

### Board

Your shop from above: every station with Working, Idle or Reserved, each car where it is, the platform's line saying what it's doing (and what's in its way), and a legend. Reserved means the game is holding that station, though no car is in it. Idle with a car in it means the car is waiting there: its work is done, or hasn't started yet. Click a car for its panel. List shows the same cars as rows. The Cars tab lists the cars waiting near the warehouse, each with the game's own preview photo for its model and colour. A car with custom paint shows a grey "Custom Paint" box, because the game has no photo for it.

### Unstick, Reset Car, Lower Lift and Free Station

- **Unstick** frees the platform from a car it's stuck on. The car keeps its task and moves to a free parking spot, so the platform picks it up again.
- **Reset Car** takes one stuck car out of automation: its task is removed, its parts go back to storage, and it moves to a free spot near the warehouse. Every other car keeps its task and its parts. The game's own red reset clears every car.
- Neither does anything while the platform is still moving or something is in its way. The message says which, and the platform line on the Board names what's in the way when it can.
- **Lower Lift:** if a mechanic's lift is left up with no car in the bay, the Board shows it under the platform line with a Lower Lift button. It isn't offered while the lift still counts a car as on it, and nothing can be under the lift when you press it, you included.
- **Free Station:** a Car Wash, Body Workshop or Mechanical Workshop can be left held by the game after its car has gone, so it reads Reserved with no car in it. After 30 s like that, the Board names it under the platform line with a Free Station button. Free Station ends the station's work the way the game does when a job finishes, so the platform can use it again. Lower a bay's lift before you press it.

### Car Pickup

The transporter's list and its Pick up when setting, with - and + to change it. It's the same setting as the game's Car Pickup screen.

- **Add Bought Cars** puts cars you own that are away from your shop on the transporter's list, up to 7. It leaves off any car the game has marked as driven by you, and any the platform or the mod is working on. To bring back a car you've driven, add it on the game's Car Pickup screen.
- **Send Now** sends the transporter with the cars already on its list, then puts Pick up when back.
- While the transporter is out, the page shows when it's back, for example "back in 3m45s", from the game's own trip timer.

### Front Parking

Your Front Parking spots in one row, numbered from F1 as you count the lot, each with its car and its ad state. Click a car for its details; for a car the mod posted, that includes the price it posted at, so you can find it in Your Ads. The tiles:

| Tile | Means |
|---|---|
| Green | Listed by the Mod |
| Yellow | Post for Sale Off: its profile doesn't post |
| Red | Not Posted: the panel says why |
| Purple | Check the Ad: the mod couldn't confirm the ad |
| Teal | Being Checked |
| Green outline | Listed by You |
| Grey | Yours, Not Listed |

### Post for Sale

A profile that finishes at Front Parking can Post for Sale. When the platform leaves the car there, the mod prices it and posts it once through the game's own ad call, then reads the ad back to confirm it. From then on it's the game's ad like any other, in Your Ads.

- **Competitiveness:** the same bar as Competitiveness of the offer on the game's ad screen. The mod picks the highest price that keeps the bar at that level, counting photos, wash and the other bonuses the way the game does. A fuller bar sells sooner but means a lower price.
- **The Ad's Options:** Non-negotiable, Available for installments, Available for online sale and Offer Warranty are the same choices as the game's ad screen. One the game hasn't unlocked yet is left off: installments from reputation 12, online sale from 10, the warranty at its level, and never on a special car.
- **Photo and Parking:** the game needs a photo to post a car, so Post for Sale keeps the Photo Studio on. A car not parked inside its spot's lines isn't posted.
- **Check the Ad:** if the mod can't confirm a car's ad, the car shows Check the Ad. Look for it in Your Ads. Try Again only looks again and never posts twice; Dismiss makes the car yours.
- **Send Back for Photos:** if a car is ever refused for having no photo, its panel offers Send Back for Photos: the car goes to a free spot near the warehouse, through the Photo Studio and back, and the mod tries again. This hasn't been seen in play: Post for Sale keeps the Photo Studio on, so the refusal shouldn't normally happen.
- **It never takes an ad down.** A car whose ad you take down becomes yours, and the mod doesn't post it again. A posted ad keeps its photos after you save and load.

## What It Changes

- **Real Tasks, Parts and Ads:** it starts real tasks on your cars, takes parts from your storage for the mechanic, and posts real ads.
- **Its Own Files Only:** `profiles.lua` (your profiles), `delivery.lua` (the Car Pickup settings) and `AutomationManager-bug-*.txt` (bug reports), all in its own folder. It changes no game files; it works through the game's own functions while the game runs.

## Uninstall

Delete `<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\AutomationManager\`. This deletes your profiles and Car Pickup settings too. To keep your profiles, copy `profiles.lua` somewhere safe first, and put it back in the folder if you install the mod again. Tasks already on the platform and ads already posted stay: they're the game's own.

## Report a Bug / Request a Feature

Use the buttons in the app's header. **Report a Bug** saves a report file in the mod's folder (your profiles, the Board's cars and their stations, and the mod's recent log lines; your Windows user name and profile folders are replaced) and opens the GitHub issue form. Drag the file in and press Submit. **Request a Feature** opens the GitHub feature form. GitHub needs a free account. No account? Post on [the mod's Nexus page](https://www.nexusmods.com/cardealersimulator/mods/60) instead.
