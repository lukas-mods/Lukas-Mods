**Get it on [Nexus Mods](https://www.nexusmods.com/cardealersimulator/mods/60)**, or download `LukasMods-CDS-AutomationManager-1.0.2.zip` below. It holds the same six files as the Nexus download, byte for byte, but it's packed differently, so this zip's own sha256 is `027fb52075da5c13dbf58a4d354f3e9fc7fe68ce66f021641af4a29e20b23864`.

A bug fix for Car Pickup, from a player report. No new features.

Needs Car Dealer Simulator on PC (Steam) and an EXPERIMENTAL UE4SS build: the one whose log says `UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d`, [on Nexus Mods](https://www.nexusmods.com/cardealersimulator/mods/53), the same as Parts Manager. Copy the `AutomationManager` folder into `<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\`, over the old one; your profiles are kept. Install and full details: [Automation Manager guide](https://github.com/lukas-mods/Lukas-Mods/blob/main/guides/car-dealer-simulator/automation-manager.md).

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save, so back up your saves first: copy `%LOCALAPPDATA%\CarDealerSimulator\Saved\` somewhere safe. Automation Manager starts real tasks on your cars, takes parts from your storage for the mechanic, and posts real ads.

## 1.0.2 - Car Pickup Fix

- Add Bought Cars now leaves off any car the game has marked as driven by you. Bought cars you haven't driven yet are still added. Before, it could put a car you'd been driving on the transporter's list, and the game then reserved it for the transporter's driver, so you couldn't use it.
