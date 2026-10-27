Parts Manager v1.1.1 -- by Luka's Mods
Car Dealer Simulator UE4SS mod

WHAT IT DOES
Rebuilding a car means buying every part one at a time, with no idea how
many cars the parts you already own could build. Parts Manager fixes
both. It adds a "Parts Manager" app (blue icon) to the tablet and to the
office computer. The app shows what is in your warehouse storage and how many
complete cars that stock can build, and it buys at normal store prices
straight into storage:

  * Complete cars: choose a kit (Stock / Sport / Race) and a number of cars,
    and you get that many full sets, whatever is already in storage.
    "Body & Consumables" adds a windshield, plate repair kit, engine oil,
    coolant and brake fluid per car.
  * Single parts: every row has its own car count, so brake calipers for
    2 cars buys 8.
  * Workshop supplies (Workshop tab): soap, wax, polish, grinder discs,
    putty, oscillating polisher pads and paint for the car wash and body
    shop. Add buys 10 of a supply. Each row's Tier button picks which of the
    game's tiers to buy: Basic, Large, Range+ or Eco-friendly (discs have
    Extra Durable in place of Large, and polisher pads have Extra and Eco).
    Add and Auto Supplies buy that tier.
  * Fuel Delivery (Fuel Delivery tab): fills your Gas Pump Hub's tanks at the
    gas station's price per gallon, without the drive. One tank unlocks per
    hub level. Needs the Gas Pump Hub upgrade and your own mobile fuel tank
    (sold at the gas station); the tab shows a padlock until you have both.
  * Auto-stock: keeps what you choose topped up, checking every 30 seconds
    while you play. It starts about a minute after a save has loaded, and
    never spends below the balance you set in "Keep Balance Above".
    (Buying by hand is not limited by it.)
      - Auto Stock / Sport / Race: N complete cars of that kit.
      - Auto Fuses: N of each fuse size (fuses come in packs of 3).
      - Auto Supplies: N of each workshop supply.
      - Auto Fuel: fills every unlocked hub tank when together they drop
        below 10%.

Hover a ? icon or an Auto button in the app for a short explanation.

Sport and Race kits need the "Up 2 You" DLC, and unlock once every part in
them is unlocked by fame level. Until then their tabs show a padlock, and
clicking one tells you what is missing. Without the DLC only Stock can be
bought.

A brand-new career always starts with auto-stock paused, so the mod never
spends a new player's money without being asked. Click any Auto button in the
app when you want it to start. If you play more than one career, set
pause_auto_on_load=1 in settings.txt: auto-stock then pauses after every save
load, with an on-screen notice, and any Auto button resumes it.

REQUIREMENTS
  * Car Dealer Simulator on PC, with the "Workshop Upgrades & Sprint Racing"
    update (October 2026) or later: Workshop supplies and Fuel Delivery use
    what that update added. Tested on the Steam version; the Microsoft
    Store / Xbox PC version is untested, and UE4SS installs differently there.
  * UE4SS (the mod loader), an EXPERIMENTAL build: the game runs on Unreal
    Engine 5.4, which the stable UE4SS release doesn't support. Tested with
    the build whose log says "UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d".
    UE4SS goes in
      <game folder>\CarDealerSimulator\Binaries\Win64\
    so that dwmapi.dll and the ue4ss\ folder sit next to
    CarDealerSimulator-Win64-Shipping.exe.
  * Optional: the "Up 2 You" DLC, for the Sport and Race kits.

USE AT YOUR OWN RISK
  Any mod can crash a game or damage a save, and this one is no
  exception: it has been tested, but not on every setup. Back up your
  saves before you install it, and now and then while you play. They
  live in
      %LOCALAPPDATA%\CarDealerSimulator\Saved\
  Copy that folder somewhere safe.
  Parts Manager also spends real in-game money. While auto-stock is
  switched on it keeps buying, down to the balance you set in Keep
  Balance Above.
  You use this mod at your own risk.

INSTALL -- WINDOWS
  Copy the PartsManager folder into
      <game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\
  so that you have  ...\ue4ss\Mods\PartsManager\enabled.txt
  enabled.txt is what turns the mod on.
  Updating from 1.0: copy the new folder over the old one. Your
  settings.txt is kept.

INSTALL -- LINUX / STEAM DECK (PROTON)
  Status: partly tested, on 1.0 only. Under Proton, UE4SS and the mod loaded
  and attached to the tablet; buying, auto-stock and the 1.1 and 1.1.1
  features have not been tested there. If you try it, please report how it
  went (see "Report a Bug" below).
  1. Install UE4SS and this mod into the same folders as on Windows (inside
     the game's Steam install folder).
  2. In Steam: right-click Car Dealer Simulator > Properties > General >
     Launch Options, and enter exactly:
         WINEDLLOVERRIDES="dwmapi=n,b" %command%
     This tells Proton to load UE4SS's dwmapi.dll.
  Note: "Report a Bug" opens your browser and file manager through Proton;
  this has not been verified yet.

CHECK THAT IT LOADED
  The game starting proves nothing. Check UE4SS's log instead:
      ...\Binaries\Win64\ue4ss\UE4SS.log
  It should contain:
      Mod 'PartsManager' has enabled.txt, starting mod.
      [PartsManager] v1.1.1 loaded
  In the game, a blue Parts Manager icon appears on the tablet and on the
  office computer's taskbar once a save has loaded -- not on the main menu,
  so don't look for it there.

SETTINGS
  settings.txt (created next to this file) remembers your choices. The
  "per_car.<ProductID>=<amount>" lines set how many of each body part or
  consumable "Body & Consumables" buys per car; set one to 0 to skip it.

UNINSTALL
  Delete  ...\ue4ss\Mods\PartsManager\
  What you bought stays: parts and supplies are ordinary items in your
  storage, and delivered fuel is in your tanks.

REPORT A BUG / REQUEST A FEATURE
  Use the buttons in the app's header. "Report a Bug" saves a report file in
  the mod folder (your Windows user name removed; it lists your installed
  UE4SS mods and the game build) and opens the GitHub issue form. Drag the
  file in and press Submit. GitHub needs a free account. No account? Post on
  the mod's Nexus page instead.

LOGO
  The logo (Assets\logo.png) is part of the Luka's Mods branding.
  The mod loads it at runtime; if the file is missing, the app works the same
  without it.
