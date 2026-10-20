# Changelog

## 1.0.1

- To-do steps you ticked were forgotten after a restart when there were two or more. Fixed.
- Ready for the Microsoft Store: the Store version leaves installing and updating to the Store.
- Available with winget: `winget install MichaelKloprogge.PCMove` (once the package is approved).

## 1.0.0

First version.

- **Pack up on the old PC:** programs (through winget, also programs installed another way that winget knows by name), the personal folders (Desktop, Documents, Pictures, Music, Videos, Downloads, Favorites), Wi-Fi networks with their passwords (as administrator), Windows settings (light/dark, taskbar, file extensions, hidden files, mouse speed...), the desktop background, and bookmarks from Chrome, Edge, Brave and Vivaldi. Everything goes into one folder on a USB drive or external disk, with a copy of PC Move itself.
- **Unpack on the new PC:** start PC-Move.exe from the drive and it opens the move folder by itself. Programs already on the new PC, Wi-Fi networks it already knows and settings that are already the same are left out. Files are copied back without ever overwriting a file that is already there.
- **To do:** a checklist for what no program can move: importing bookmarks, signing in to browsers, OneDrive, Firefox and Steam, Microsoft 365, programs winget doesn't know, the default browser, printers, Windows Update - each with a button that opens the right place.
- Runtimes, drivers and the PC maker's own tools are recognised and not installed again.
- Settings changes can be undone (Settings > Undo).
- English, Dutch, German, French, Spanish, Italian and Polish; light and dark theme; updates itself from GitHub.
