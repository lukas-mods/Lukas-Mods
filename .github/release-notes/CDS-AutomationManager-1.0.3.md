**Get it on [Nexus Mods](https://www.nexusmods.com/cardealersimulator/mods/60)**, or download `LukasMods-CDS-AutomationManager-1.0.3.zip` below. It holds the same six files as the Nexus download, byte for byte, but it's packed differently, so this zip's own sha256 is `e577e44cdb16d87fe64832765f9d768ad12f36e92a06c97282dd2a60e9896842`.

Bug fixes from player reports. No new features.

Needs Car Dealer Simulator on PC (Steam) and an EXPERIMENTAL UE4SS build: the one whose log says `UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d`, [on Nexus Mods](https://www.nexusmods.com/cardealersimulator/mods/53), the same as Parts Manager. Automation needs the game's Vehicle Platform, which you buy in the game's Store. Copy the `AutomationManager` folder into `<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\`, over the old one; your profiles are kept. Install and full details: [Automation Manager guide](https://github.com/lukas-mods/Lukas-Mods/blob/main/guides/car-dealer-simulator/automation-manager.md).

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save, so back up your saves first: copy `%LOCALAPPDATA%\CarDealerSimulator\Saved\` somewhere safe. Automation Manager starts real tasks on your cars, takes parts from your storage for the mechanic, and posts real ads.

## 1.0.3 - Photo and Report a Bug Fixes

- Report a Bug now works while a car that got its profile from the mod is in automation. Before, the button could do nothing.
- Post for Sale: when the mod can't use the photo path the game gives it, it now works from the photo's file name instead. Before, it refused the car as having no Photo Studio photos.
- If you don't own the Vehicle Platform, the app now says automation needs it. Before, it said automation wasn't ready yet.
