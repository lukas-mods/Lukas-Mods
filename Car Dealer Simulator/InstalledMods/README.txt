Installed Mods v1.0 -- by Luka's Mods
Car Dealer Simulator UE4SS mod

WHAT IT DOES
Switching a UE4SS mod off normally means finding its folder and renaming
or deleting files by hand. Installed Mods puts that on the game's title
menu. It adds an INSTALLED MODS button (above QUIT) that opens a page
listing the mods in your ue4ss\Mods folder:

  * Each mod's name, whether it is ON or OFF, and its version. The version
    comes from the mod's mod-support.json when it has one, or else from the
    version the mod printed in UE4SS's log when it loaded. A mod that does
    neither shows a dash.
  * Turn On / Turn Off on each mod, then Apply. The change takes effect the
    next time you start the game; a box then offers to quit the game now
    (Quit Game) or carry on (Later).
  * UE4SS's own built-in mods are left out of the list, and they can't be
    switched from here.

Some rows have no switch, and the status says why:
  (this mod)        Installed Mods can't switch itself off.
  (no mod files)    The folder holds nothing UE4SS can start, and no
                    enabled.txt.
  (set in mods.txt) The mod is switched by a line in UE4SS's mods.txt,
                    which Installed Mods never edits. Change that line by
                    hand.
  MIXED             The mod has an enabled.txt but mods.txt says 0, and
                    which one UE4SS follows isn't known. Remove the mod's
                    line from mods.txt, or its enabled.txt, so only one
                    is left.

Back, or Esc, returns to the title menu.

WHAT IT CHANGES ON DISK
Only a mod's enabled.txt, and only when you press Apply: switching a mod
off renames enabled.txt to enabled.txt.off (replacing any older
enabled.txt.off), and switching it on renames it back (or creates an empty
enabled.txt). Nothing else in any mod's folder is
touched. The one file of its own it writes is a bug report, when you ask
for one. It makes no web requests of its own.

REQUIREMENTS
  * Car Dealer Simulator on PC (Steam). The Microsoft Store / Xbox PC
    version is untested, and UE4SS installs differently there.
  * UE4SS (the mod loader), an EXPERIMENTAL build: the game runs on Unreal
    Engine 5.4, which the stable UE4SS release doesn't support. Use the
    build whose log says "UE4SS - v3.0.1 Beta #0 - Git SHA #44afb36d", the
    same one Parts Manager uses.
    UE4SS goes in
      <game folder>\CarDealerSimulator\Binaries\Win64\
    so that dwmapi.dll and the ue4ss\ folder sit next to
    CarDealerSimulator-Win64-Shipping.exe.

USE AT YOUR OWN RISK
  Any mod can crash a game or damage a save. Back up your saves before you
  install it; they live in
      %LOCALAPPDATA%\CarDealerSimulator\Saved\
  Switching another mod off or on is the same as renaming its enabled.txt
  yourself: what that mod does to your save when it is missing is up to
  that mod.
  You use this mod at your own risk.

INSTALL -- WINDOWS
  Copy the InstalledMods folder into
      <game folder>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\
  so that you have  ...\ue4ss\Mods\InstalledMods\enabled.txt
  enabled.txt is what turns the mod on.

INSTALL -- LINUX / STEAM DECK (PROTON)
  Status: untested. If you try it, please report how it went (see "Report
  a Bug" below).
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
      Mod 'InstalledMods' has enabled.txt, starting mod.
      [InstalledMods] v1.0 loaded
  In the game, INSTALLED MODS appears in the title menu, above QUIT.

UNINSTALL
  Delete  ...\ue4ss\Mods\InstalledMods\
  Mods you switched off stay off (their enabled.txt is still named
  enabled.txt.off). To switch one back on by hand, rename that file to
  enabled.txt.

REPORT A BUG / REQUEST A FEATURE
  Use the buttons at the top of the page. "Report a Bug" saves a report
  file in the InstalledMods folder (it lists your installed UE4SS mods and
  holds no file paths, so your Windows user name isn't in it), opens that
  folder with the file selected when it can, and opens the GitHub issue
  form. Drag the file in and press Submit. GitHub needs a free account. No
  account? Post on the mod's Nexus page instead.

LOGO
  The logo (Assets\logo.png) is part of the Luka's Mods branding.
  The mod loads it at runtime; if the file is missing, the page works the
  same without it.
