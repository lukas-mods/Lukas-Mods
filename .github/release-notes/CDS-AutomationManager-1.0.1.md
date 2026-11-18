**Get it on [Nexus Mods](https://www.nexusmods.com/cardealersimulator/mods/60)**, or download `LukasMods-CDS-AutomationManager-1.0.1.zip` below. It holds the same six files as the Nexus download, byte for byte, but it's packed differently, so this zip's own sha256 is `c766b4640a6d9882c862119137ea74763450d2895bcd1f228c7e1690fee25bf8`.

Bug fixes for the mechanic step, from player reports. No new features.

Needs Car Dealer Simulator on PC (Steam) and an EXPERIMENTAL UE4SS build: the one whose log says `UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d`, [on Nexus Mods](https://www.nexusmods.com/cardealersimulator/mods/53), the same as Parts Manager. Copy the `AutomationManager` folder into `<game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\`, over the old one; your profiles are kept. Install and full details: [Automation Manager guide](https://github.com/lukas-mods/Lukas-Mods/blob/main/guides/car-dealer-simulator/automation-manager.md).

> ⚠️ **Use at Your Own Risk.** Any mod can crash a game or damage a save, so back up your saves first: copy `%LOCALAPPDATA%\CarDealerSimulator\Saved\` somewhere safe. Automation Manager starts real tasks on your cars, takes parts from your storage for the mechanic, and posts real ads.

## 1.0.1 - Mechanic Fixes

- Replace Damaged now works: the mechanic gets the parts, fuses and fluids to change, picked from your storage the way the game's own Automation tab picks them. Before, the car went to the mechanic with nothing to do and came back untouched.
- Disassemble now takes the parts and fuses off and drains the fluids.
- Custom now changes fuses and fluids too, and fits parts that are missing. The windshield is replaced when it needs it.
- A car with nothing for the mechanic to do now skips the mechanic and gets the rest of its profile, instead of riding to the mechanic for nothing.
- Parts picked for a job that doesn't go ahead go back to storage.
- If a car's task is removed before the platform picks the car up (for example by another mod), the car is no longer treated as finished.
