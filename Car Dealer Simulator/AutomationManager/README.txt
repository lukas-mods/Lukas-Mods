Automation Manager v1.0 -- by Luka's Mods
Car Dealer Simulator UE4SS mod

WHAT IT DOES
The automation platform does the legwork of moving cars between stations,
but you still set every car's task by hand and keep an eye on the shop.
Automation Manager adds an "Automation Manager" app to the tablet and to
the office computer that does the setting up for you and shows the whole
shop at a glance:

  * Profiles: a profile picks which stations a car visits (Photo Studio,
    Paint Booth, Car Wash, Body Workshop, Mechanical Workshop, Air
    Compressor, Fuel Dispenser), the paint colour, and where the car
    finishes (Front Parking, Side Parking, Underground Garage or Tuning
    Garage). The mechanic step can Replace Damaged parts with one part type,
    use Custom (a part type for every slot, all of them set, the parts taken
    from your storage when the task is added, all or nothing), or
    Disassemble the car. Stations a car doesn't need are skipped, by the
    game's own tests. Profiles can be renamed.
  * Give a car on a parking spot near the warehouse a profile, and it gets
    its automation task through the game's own Add Automation Task.
    Select Cars (or Shift-click) gives several cars the same profile.
  * Board: your shop from above, with every station's Working, Idle or
    Reserved (the game is holding the station, though no car is in it),
    each car where it is, and the platform's line saying what it's doing
    and what's in its way. List shows the same cars as rows. The Cars
    tab lists the cars waiting near the warehouse, each with its photo.
  * Unstick and Reset Car for a car the platform is stuck on. Unstick keeps
    the car's task and moves it to a free spot; Reset Car takes it out of
    automation and returns its parts to storage. Every other car keeps its
    task and its parts. Neither does anything while the platform is still
    moving or something is in its way.
  * Lower Lift, for a mechanic's lift left up over an empty bay. It isn't
    offered while the lift still counts a car as on it, and nothing can be
    under the lift when you press it.
  * Free Station, for a Car Wash, Body Workshop or Mechanical Workshop
    the game is still holding with no car in it: it ends the station's
    work the way the game does when a job finishes, so the platform can
    use it again.
  * Car photos: cars show the game's own preview photo for their model and
    colour. A car with custom paint shows a "Custom Paint" box,
    because the game has no photo for it.
  * Car Pickup: the transporter's list and its Pick up when setting, with
    - and + (the same setting as the game's Car Pickup screen). Add Bought
    Cars puts every car the Car Pickup screen would offer on the list, up
    to 7; cars on your shop's own parking spots, and cars the platform or
    the mod is working on, stay off it. Send Now sends the transporter
    with the cars already on its list. While it's out, the page shows when
    it's back.
  * Front Parking: your Front Parking spots in one row (14 on a full lot),
    each with its car and whether it's listed. Click a car for its details.
  * Post for Sale: a profile that finishes at Front Parking can price the
    car and post it for you. Set Competitiveness on the profile: the same
    bar as "Competitiveness of the offer" on the game's ad screen. The mod
    picks the highest price that keeps the bar at that level, counting
    photos, wash and the other bonuses the way the game does. Non-negotiable,
    installments, online sale and warranty are the game's own choices; one
    the game hasn't unlocked yet is left off. The car is posted once,
    through the game's own ad call, and the ad is read back to confirm it.
    From then on it's the game's ad like any other, in Your Ads. The mod
    never takes an ad down; a car whose ad you take down becomes yours.
    If the mod can't confirm a car's ad, the car shows Check the Ad: look
    for it in Your Ads. Try Again only looks again and never posts twice;
    Dismiss makes the car yours.

Each page has a one-line hint, and Help in the app explains every part.

REQUIREMENTS
  * Car Dealer Simulator on PC. Tested on the Steam version, game build
    26565045. The Microsoft Store / Xbox PC version is untested, and UE4SS
    installs differently there.
  * UE4SS (the mod loader), an EXPERIMENTAL build: the game runs on Unreal
    Engine 5.4, which the stable UE4SS release doesn't support. Tested with
    the build whose log says "UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d".
    UE4SS goes in
      <game folder>\CarDealerSimulator\Binaries\Win64\
    so that dwmapi.dll and the ue4ss\ folder sit next to
    CarDealerSimulator-Win64-Shipping.exe.
    With Vortex, it's installed for you (see INSTALL -- VORTEX).
  * Optional: the "Up 2 You" DLC, for Sport and Race parts. Without it only
    Default and Stock are offered.

USE AT YOUR OWN RISK
  Any mod can crash a game or damage a save, and this one is no
  exception: it has been tested, but not on every setup. Back up your
  saves before you install it, and now and then while you play. They
  live in
      %LOCALAPPDATA%\CarDealerSimulator\Saved\
  Copy that folder somewhere safe.
  Automation Manager starts real tasks on your cars, takes parts from your
  storage for Custom profiles, and posts real ads at the price it works
  out. Check a profile before you give it to a car.
  You use this mod at your own risk.

INSTALL -- VORTEX
  In Vortex, find Car Dealer Simulator under Games and click Manage. Then
  drag this mod's zip onto Vortex's Mods page and enable it. Vortex puts it
  in the right folder, and installs UE4SS for you if it's missing.

INSTALL -- WINDOWS (BY HAND)
  Copy the AutomationManager folder into
      <game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\
  so that you have  ...\ue4ss\Mods\AutomationManager\enabled.txt
  enabled.txt is what turns the mod on.

UPDATE
  Copy the new AutomationManager folder over the old one and let Windows
  replace the files. Your profiles (profiles.lua) and Car Pickup settings
  (delivery.lua) aren't in the download, so they stay. Don't delete the old
  folder first, or they go with it.

INSTALL -- LINUX / STEAM DECK (PROTON)
  Status: untested. If you try it, please report how it went (see
  "Report a Bug" below).
  1. Install UE4SS and this mod into the same folders as on Windows (inside
     the game's Steam install folder).
  2. In Steam: right-click Car Dealer Simulator > Properties > General >
     Launch Options, and enter exactly:
         WINEDLLOVERRIDES="dwmapi=n,b" %command%
     This tells Proton to load UE4SS's dwmapi.dll.

CHECK THAT IT LOADED
  The game starting proves nothing. Check UE4SS's log instead:
      ...\Binaries\Win64\ue4ss\UE4SS.log
  It should contain:
      Mod 'AutomationManager' has enabled.txt, starting mod.
      [AutomationManager] v1.0 (... B, sum ...) loaded (running)
  In the game, the Automation Manager app appears on the tablet and on the
  office computer once a save has loaded -- not on the main menu.

FILES IT WRITES
  In its own folder only: profiles.lua (your profiles), delivery.lua (the
  Car Pickup settings) and AutomationManager-bug-*.txt (bug reports). It
  changes no game files; it works through the game's own functions while
  the game runs.

UNINSTALL
  Delete  ...\ue4ss\Mods\AutomationManager\
  This deletes your profiles and Car Pickup settings too. To keep your
  profiles, copy profiles.lua somewhere safe first; put it back in the
  folder if you install the mod again.
  Tasks already on the platform and ads already posted stay: they're the
  game's own.

REPORT A BUG / REQUEST A FEATURE
  Use the buttons in the app's header. "Report a Bug" saves a report file
  in the mod folder (your profiles, the Board's cars and their stations,
  and the mod's recent log lines; your Windows user name and profile
  folders are replaced) and opens the GitHub issue form. Drag the file in
  and press Submit. GitHub needs a free account. No account? Post on the
  mod's Nexus page instead.

LOGO
  The logo (Assets\logo.png) is part of the Luka's Mods branding.
  The mod loads it at runtime; if the file is missing, the app works the same
  without it.
