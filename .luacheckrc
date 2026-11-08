-- luacheck config for DMme. Run from this folder:  luacheck .
-- WoW runs Lua 5.1 and ignores this file (it's not in DMme.toc).
std = "lua51"
max_line_length = false
exclude_files = { ".luacheckrc" }

ignore = {
    "212/self",   -- unused 'self' in methods/scripts
    "21./_.*",    -- unused variables named _ / _foo on purpose
    "211/ADDON",  -- every file unpacks "local ADDON, ns = ..."
}

-- globals DMme creates or writes to
globals = {
    "DMmeDB", "DMmeHistory",
    "DMme_OnAddonCompartmentClick", "DMme_OnAddonCompartmentEnter", "DMme_OnAddonCompartmentLeave",
    "SLASH_DMME1", "SLASH_DMME2",
    "SlashCmdList", "StaticPopupDialogs", "UISpecialFrames",
}

-- WoW API and UI globals DMme reads (add new ones here when luacheck reports them)
read_globals = {
    -- Lua helpers WoW adds
    "date", "time", "wipe", "tinsert", "tremove", "hooksecurefunc", "geterrorhandler", "issecretvalue",
    -- namespaces
    "C_BattleNet", "C_ChatInfo", "C_FriendList", "C_PartyInfo", "C_Timer",
    "ChatFrameUtil", "Menu", "MenuResponse", "MenuUtil", "Settings",
    -- functions
    "Ambiguate", "BNGetNumFriends", "BNInviteFriend", "BNSendWhisper", "CanGuildInvite",
    "ChatEdit_InsertLink", "ChatFrame_AddMessageEventFilter", "CreateColor", "CreateFont", "CreateFrame",
    "FriendsFrame_InviteOrRequestToJoin", "GetCursorPosition", "GetNormalizedRealmName", "GetNumWhoResults",
    "GetPlayerInfoByGUID", "GetRealmID", "GetRealmName", "GetTime", "GetWhoInfo", "InCombatLockdown",
    "InterfaceOptions_AddCategory", "InviteUnit", "IsControlKeyDown", "IsGuildMember", "IsInGuild",
    "IsModifierKeyDown", "IsShiftKeyDown", "MouseIsOver", "PlaySound", "SendChatMessage", "SendWho",
    "SetItemRef", "StaticPopup_Show", "UIDropDownMenu_AddButton", "UIDropDownMenu_CreateInfo",
    "UnitClass", "UnitInParty", "UnitInRaid", "UnitIsPlayer", "UnitName", "UnitPopup_ShowMenu",
    -- frames, mixins, tables, constants
    "BackdropTemplateMixin", "ChatFontNormal", "ChatTypeInfo", "DEFAULT_CHAT_FRAME", "GameTooltip",
    "Minimap", "UIParent", "CLASS_ICON_TCOORDS", "LOCALIZED_CLASS_NAMES_FEMALE", "LOCALIZED_CLASS_NAMES_MALE",
    "RAID_CLASS_COLORS", "SOUNDKIT", "UIDROPDOWNMENU_MENU_LEVEL", "WOW_PROJECT_ID", "BNET_CLIENT_WOW",
    "COPY_CHARACTER_NAME", "FRIEND", "NO", "PARTY", "PLAYER", "RAID_PLAYER", "TARGET", "WHO_LIST_FORMAT", "YES",
}
