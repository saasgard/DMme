# DMme

Whispers in their own windows for World of Warcraft (Forever client, interface 16001).

![DMme logo](Art/curseforge-logo.png)

## Features

- **Whisper windows**: every conversation gets its own window, or one window with a **tab per player**
- **Battle.net whispers** too, with the friend's current character shown
- **Class colors** for names, text, tabs and unread markers (or classic whisper pink)
- **Player profile** from `/who`: level, race, class, guild and zone in the window header
- **Right-click a name** for the game's normal player menu
- **Minimap button** with an unread badge (counted per conversation), a pulsing glow and a list of this session's whispers. Remove one or clear all. The button can be detached and placed anywhere.
- **Session list survives `/reload`**: it's only cleared on a fresh login
- **Optional history** (off by default): saves whispers and lets you search them in a History window
- **Buttons per window**: Guild Invite, Party Invite, Who and History, each one can be toggled in Settings
- Settings window, scale option and an entry under Esc → Options → AddOns

## Commands

| Command | What it does |
|---|---|
| `/dm` | Open settings |
| `/dm help` | List all commands |
| `/dm open <name>` | Open a whisper window |
| `/dm list` | This session's whispers |
| `/dm history [name]` | Browse saved whispers |
| `/dm log [on\|off]` | Save whispers to disk |
| `/dm tabs` | Toggle tabbed window |
| `/dm minimap` / `/dm detach` | Show/hide or detach the minimap button |
| `/dm scale <n>` | Window scale |
| `/dm clear [name]` | Delete saved history |
| `/dm reset` / `/dm closeall` | Reset positions / close all windows |

`/dmme` works as an alias.

## Notes

- **Guild invites:** on this client the game only allows guild invites you type yourself. Addons, secure buttons, macros and pre-filled chat are all blocked. The Guild Invite button (off by default) shows `/ginvite Name` ready to copy. Press Ctrl+C, then Enter, Ctrl+V, Enter in chat.
- **Add Friend:** friends are Battle.net friends now, which need a BattleTag, so there is no Add Friend button.
- **Saved data:** history is stored in `WTF\Account\<account>\SavedVariables\DMme.lua`.

## Install

Copy the `DMme` folder to `World of Warcraft\_forever_\Interface\AddOns\` and restart the game.

## Art

`Art/source/make_art.py` draws the logo and icons with plain Python (no dependencies):

```
python Art/source/make_art.py <addon folder> <preview folder>
```
