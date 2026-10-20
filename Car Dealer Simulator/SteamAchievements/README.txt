Steam Achievements v1.0.1 -- by Luka's Mods
Car Dealer Simulator UE4SS mod

WHAT IT DOES
Car Dealer Simulator has 203 Steam achievements. Steam Achievements brings
them into the game, so you can see what's close and track it while you play.
It adds a "Steam Achievements" app (purple trophy icon) to the tablet and to the
office computer, and a small panel at the top right of your screen:

  * Every achievement in one list: icon, description, progress bar and
    count (e.g. "23 / 25"), plus how many Steam players have it
    ("28.0% have it"). 25 rows per page, with < Prev / Next >.
  * Tiered achievements share one row. The squares under the icon show the
    tiers: green done, white the one you're on, grey still to come.
  * Filters: All, Tracked, In Progress (everything not finished yet) and
    Done. The search box narrows the list as you type.
  * Track: pin up to 4 achievements to the HUD panel. Untrack frees a slot,
    and a finished achievement drops off by itself. Your picks are kept in
    settings.txt, so they survive a restart.
  * HUD panel: shows your tracked achievements while you play. With nothing
    tracked, it suggests the 4 easiest unfinished ones: counters closest to
    done, and one-offs the most players have. HUD Panel: ON/OFF in the app
    hides or shows it.
  * Live progress: counts move the moment the game reports them to Steam.
    Wash a car and "Wash down 50 cars with water" goes from 47 to 48 on the
    spot.
  * Hidden achievements stay hidden until you unlock them.

It reads your progress and never unlocks anything. Nothing is downloaded
while you play: the icons and player percentages ship with the mod.

REQUIREMENTS
  * Car Dealer Simulator on PC, the Steam version, played signed in to
    Steam. Tested on game build 26053251. The Microsoft Store / Xbox PC
    version is untested.
  * UE4SS (the mod loader), an EXPERIMENTAL build: the game runs on Unreal
    Engine 5.4, which the stable UE4SS release doesn't support. Tested with
    the build whose log says "UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d".
    UE4SS goes in
      <game folder>\CarDealerSimulator\Binaries\Win64\
    so that dwmapi.dll and the ue4ss\ folder sit next to
    CarDealerSimulator-Win64-Shipping.exe.
    With Vortex, it's installed for you (see INSTALL -- VORTEX).
  * No DLC needed.

USE AT YOUR OWN RISK
  Any mod can crash a game or damage a save, and this one is no
  exception: it has been tested, but not on every setup. Back up your
  saves before you install it, and now and then while you play. They
  live in
      %LOCALAPPDATA%\CarDealerSimulator\Saved\
  Copy that folder somewhere safe.
  You use this mod at your own risk.

INSTALL -- VORTEX
  In Vortex, find Car Dealer Simulator under Games and click Manage. Then
  drag this mod's zip onto Vortex's Mods page and enable it. Vortex puts it
  in the right folder, and installs UE4SS for you if it's missing.

INSTALL -- WINDOWS (BY HAND)
  Copy the SteamAchievements folder into
      <game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\
  so that you have  ...\ue4ss\Mods\SteamAchievements\enabled.txt
  enabled.txt is what turns the mod on.
  Nothing else to set up: the mod finds your Steam folder and account
  by itself.

INSTALL -- LINUX / STEAM DECK (PROTON)
  Status: untested. If you try it, please report how it went (see
  "Report a Bug" below). UE4SS under Proton needs this in Steam: right-click
  Car Dealer Simulator > Properties > General > Launch Options, and enter
  exactly:
      WINEDLLOVERRIDES="dwmapi=n,b" %command%

CHECK THAT IT LOADED
  The game starting proves nothing. Check UE4SS's log instead:
      ...\Binaries\Win64\ue4ss\UE4SS.log
  It should contain:
      Mod 'SteamAchievements' has enabled.txt, starting mod.
      [SteamAchievements] v1.0.1 loaded
  In the game, the purple trophy icon appears on the tablet and on the
  office computer once a save has loaded -- not on the main menu, so don't
  look for it there.

SETTINGS
  settings.txt (created next to this file the first time you change
  something) remembers your choices:
      widget=1             the HUD panel on (0 = off)
      track=...            your tracked achievements
      steam_path=...       only if the app says it can't find your Steam
                           folder, e.g.
                           steam_path=D:\Games\Steam

QUESTIONS
  Why is the panel ahead of Steam?
    The mod counts progress the moment the game reports it. Steam stores
    progress only from time to time, so its overlay and its page catch up
    later. Nothing is counted twice.
  Why doesn't a car I sold on installments count yet?
    It counts when the installments are complete, the same as on Steam.
  Can it unlock achievements?
    No. It only reads.
  Which Steam account does it read?
    On a PC with several Steam accounts, the one that signed in to Steam
    most recently. Switch accounts and the panel switches with you.
  It says "Steam folder not found".
    Your Steam folder isn't in a usual place. Add a steam_path= line to
    settings.txt (see SETTINGS) and restart the game.
  An achievement has no icon or player percentage.
    It was added by a game update after this version of the mod was built.
    It shows without an icon or player percentage until the mod is updated.

UNINSTALL
  Delete  ...\ue4ss\Mods\SteamAchievements\
  The mod writes only settings.txt and bug-report files, both in its own
  folder, so nothing is left behind. It never touches Steam's files.

REPORT A BUG / REQUEST A FEATURE
  Use the buttons in the app's header. "Report a Bug" saves a report file in
  the mod folder (your Windows user name and Steam account numbers removed)
  and opens the GitHub issue form. Drag the file in and press Submit. GitHub
  needs a free account. No account? Post on the mod's Nexus page instead.

MY OTHER MODS
  Parts Manager: buy a whole car's worth of parts in one click, restock
  workshop supplies and fill your Gas Pump Hub's tanks without the drive.
  https://www.nexusmods.com/cardealersimulator/mods/54

LOGO
  The logo (Assets\logo.png) is part of the Luka's Mods branding.
  The mod loads it at runtime; if the file is missing, the app works the same
  without it.

Steam is a trademark of Valve Corporation. This mod is not made by,
affiliated with or endorsed by Valve.
