-- Party Manager: your own characters as a managed party.
-- The Party tab lives inside the Character window (like Reputation and
-- Skills) and reuses the sheet's own art and slot layout. Companions are the
-- tabs on the right edge, like spellbook schools. Transmog has its own
-- Blizzard-style window. Talks to mod-party-manager on the realm through
-- addon whispers to yourself.

local PREFIX = "PMGR"
local TRANSMOGRIFIER = 190010

PartyManagerDB = PartyManagerDB or {}

local CLASS_FILE = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", nil, "DRUID" }
local CLASS_NAME = { "Warrior", "Paladin", "Hunter", "Rogue", "Priest", "Death Knight", "Shaman", "Mage", "Warlock", nil, "Druid" }
local RACE_FILE = { "Human", "Orc", "Dwarf", "NightElf", "Scourge", "Tauren", "Gnome", "Troll", nil, "BloodElf", "Draenei" }
local RACE_NAME = { "Human", "Orc", "Dwarf", "Night Elf", "Undead", "Tauren", "Gnome", "Troll", nil, "Blood Elf", "Draenei" }
local ROLE_NAME = { T = "Tank", H = "Healer", D = "Damage" }

local SLOT_NAME = {
  [0] = "HeadSlot", [1] = "NeckSlot", [2] = "ShoulderSlot", [3] = "ShirtSlot", [4] = "ChestSlot",
  [5] = "WaistSlot", [6] = "LegsSlot", [7] = "FeetSlot", [8] = "WristSlot", [9] = "HandsSlot",
  [10] = "Finger0Slot", [11] = "Finger1Slot", [12] = "Trinket0Slot", [13] = "Trinket1Slot",
  [14] = "BackSlot", [15] = "MainHandSlot", [16] = "SecondaryHandSlot", [17] = "RangedSlot", [18] = "TabardSlot",
}
local SLOT_LABEL = {
  [0] = "Head", [1] = "Neck", [2] = "Shoulders", [3] = "Shirt", [4] = "Chest", [5] = "Waist", [6] = "Legs", [7] = "Feet",
  [8] = "Wrists", [9] = "Hands", [10] = "Ring", [11] = "Ring", [12] = "Trinket", [13] = "Trinket", [14] = "Back",
  [15] = "Main Hand", [16] = "Off Hand", [17] = "Ranged", [18] = "Tabard",
}
local LEFT_COLUMN = { 0, 1, 2, 14, 4, 3, 18, 8 }
local RIGHT_COLUMN = { 9, 5, 6, 7, 10, 11, 12, 13 }
local WEAPONS = { 15, 16, 17 }
local HIDEABLE = { [0] = true, [2] = true, [14] = true, [3] = true, [18] = true, [8] = true, [9] = true, [5] = true, [7] = true }
-- Wardrobe preview camera per slot: zoom, vertical offset, facing.
local SLOT_CAMERA = {
  [0] = { 1.55, -0.62, 0.35 }, [2] = { 1.15, -0.48, 0.55 }, [14] = { 0.75, -0.25, 3.14 }, [4] = { 0.95, -0.28, 0.35 },
  [3] = { 0.95, -0.28, 0.35 }, [18] = { 0.95, -0.28, 0.2 }, [8] = { 1.05, -0.08, 0.9 }, [9] = { 1.05, -0.05, 0.9 },
  [5] = { 1.05, -0.05, 0.35 }, [6] = { 0.7, 0.25, 0.35 }, [7] = { 1.0, 0.5, 0.35 },
  [15] = { 0.25, 0, 0.75 }, [16] = { 0.25, 0, -0.6 }, [17] = { 0.25, 0, 0.75 },
}

-- ---------------------------------------------------------------- state

local state = {
  roster = {}, maxCompanions = 4, levelLock = true, stance = 0,
  stats = {}, ext = {}, gear = {}, outfits = {}, selected = nil, view = "gear",
}
local wardrobe = { low = nil, slot = 4, page = 1, pending = {}, lists = {}, showLocked = true }
local buffers = { R = {}, G = {}, T = {}, O = {} }
local lastPickup
local ui, wui = {}, {}

local function Print(text) DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Party:|r " .. text) end
local function Send(msg) SendAddonMessage(PREFIX, msg, "WHISPER", UnitName("player")) end

local function Split(s, sep)
  local out = {}
  if not s or s == "" then return out end
  local start = 1
  while true do
    local i = string.find(s, sep, start, true)
    if not i then
      out[#out + 1] = string.sub(s, start)
      return out
    end
    out[#out + 1] = string.sub(s, start, i - 1)
    start = i + 1
  end
end

local function Size(r, w, h) r:SetWidth(w); r:SetHeight(h) end

local function ClassColor(classId)
  local file = CLASS_FILE[classId or 0]
  local c = file and RAID_CLASS_COLORS[file]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end

local function GuidLow(unit)
  local guid = UnitGUID(unit)
  return guid and tonumber(string.sub(guid, -8), 16)
end

local function UnitForLow(low)
  if not low then return nil end
  for i = 1, 4 do
    if UnitExists("party" .. i) and GuidLow("party" .. i) == low then return "party" .. i end
  end
  for i = 1, 40 do
    if UnitExists("raid" .. i) and GuidLow("raid" .. i) == low then return "raid" .. i end
  end
end

local function Companions()
  local list = {}
  for _, c in ipairs(state.roster) do
    if c.state == "S" then list[#list + 1] = c end
  end
  return list
end

local function FindChar(low)
  for _, c in ipairs(state.roster) do
    if c.low == low then return c end
  end
end

local function IsCompanionName(name)
  if not name then return false end
  for _, c in ipairs(state.roster) do
    if c.name == name then return true end
  end
  return false
end

local function GearRec(low, slot)
  local g = low and state.gear[low]
  return g and g[slot]
end

local function ItemString(rec)
  return string.format("item:%d:%d:%d:%d:%d:0:%d:0:%d", rec.entry, rec.ench, rec.g1, rec.g2, rec.g3, rec.suffix, UnitLevel("player"))
end

local function Money(copper)
  local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
  if g > 0 then return string.format("%dg %ds %dc", g, s, c) end
  if s > 0 then return string.format("%ds %dc", s, c) end
  return c .. "c"
end

local function ServerPos(bag, slot)
  if bag == 0 then return 255, 22 + slot end
  if bag >= 1 and bag <= 4 then return 18 + bag, slot - 1 end
end

hooksecurefunc("PickupContainerItem", function(bag, slot) lastPickup = { bag = bag, slot = slot } end)

-- Companion chatter stays out of your chat.
local function ChatFilter(self, event, msg, sender) return IsCompanionName(sender) end
for _, ev in ipairs({ "CHAT_MSG_WHISPER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_RAID" }) do
  ChatFrame_AddMessageEventFilter(ev, ChatFilter)
end
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", function(self, event, msg, target) return IsCompanionName(target) end)

-- ---------------------------------------------------------------- shared widgets

local nameCount = 0
local function NextName(kind)
  nameCount = nameCount + 1
  return "PartyManager" .. kind .. nameCount
end

local function PanelButton(parent, label, w, onClick)
  local b = CreateFrame("Button", NextName("Button"), parent, "UIPanelButtonTemplate")
  Size(b, w, 22)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function Tip(f, title, body)
  f:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(title)
    if body then GameTooltip:AddLine(body, 0.85, 0.85, 0.85, true) end
    GameTooltip:Show()
  end)
  f:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Item slot built on the game's own item button.
local function MakeSlot(parent)
  local b = CreateFrame("Button", NextName("Slot"), parent, "ItemButtonTemplate")
  b.icon = _G[b:GetName() .. "IconTexture"]
  b.border = b:CreateTexture(nil, "OVERLAY")
  b.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  b.border:SetBlendMode("ADD")
  Size(b.border, 68, 68)
  b.border:SetPoint("CENTER")
  b.border:Hide()
  b.check = b:CreateTexture(nil, "OVERLAY")
  b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  Size(b.check, 18, 18)
  b.check:SetPoint("BOTTOMRIGHT", 4, -4)
  b.check:Hide()
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function SetSlotIcon(b, slot, entry)
  if entry then
    b.icon:SetTexture(GetItemIcon(entry) or "Interface\\Icons\\INV_Misc_QuestionMark")
  else
    local _, texture = GetInventorySlotInfo(SLOT_NAME[slot])
    b.icon:SetTexture(texture)
  end
  b.icon:SetVertexColor(1, 1, 1)
  b.icon:Show()
end

local function MakeModel(parent)
  local m = CreateFrame("DressUpModel", nil, parent)
  m.rotation = 0.35
  m:EnableMouse(true)
  m:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
  m:SetScript("OnMouseUp", function(self) self.dragX = nil end)
  m:SetScript("OnUpdate", function(self)
    if self.dragX then
      local x = GetCursorPosition()
      self.rotation = self.rotation + (x - self.dragX) * 0.02
      self.dragX = x
      self:SetFacing(self.rotation)
    end
  end)
  return m
end

local function RotateButton(parent, model, dir)
  local b = CreateFrame("Button", nil, parent)
  Size(b, 35, 35)
  local base = "Interface\\Buttons\\UI-Rotation" .. (dir < 0 and "Left" or "Right") .. "-Button-"
  b:SetNormalTexture(base .. "Up")
  b:SetPushedTexture(base .. "Down")
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Round", "ADD")
  b:SetFrameLevel(model:GetFrameLevel() + 2)
  b:SetScript("OnUpdate", function(self, elapsed)
    if self:GetButtonState() == "PUSHED" then
      model.rotation = model.rotation + dir * elapsed * 2.5
      model:SetFacing(model.rotation)
    end
  end)
  return b
end

local function PageButton(parent, dir, onClick)
  local b = CreateFrame("Button", nil, parent)
  Size(b, 28, 28)
  local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-"
  b:SetNormalTexture(base .. "Up")
  b:SetPushedTexture(base .. "Down")
  b:SetDisabledTexture(base .. "Disabled")
  b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  b:SetScript("OnClick", onClick)
  return b
end

local INSET = {
  bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local function SetModelUnit(model, unit, dress)
  if model.unit ~= unit or model.dirty then
    model:SetUnit(unit)
    if dress then dress(model) end
    model:SetFacing(model.rotation or 0.35)
    model.unit, model.dirty = unit, false
  end
end

-- ---------------------------------------------------------------- layout from the character sheet

local FRAME_W, FRAME_H = 384, 512
local function AnchorXY(point, w, h)
  local x = point:find("LEFT") and 0 or (point:find("RIGHT") and w or w / 2)
  local y = point:find("TOP") and 0 or (point:find("BOTTOM") and -h or -h / 2)
  return x, y
end
-- Top-left offset of a frame relative to the Character frame, following its anchor chain.
local function OffsetOf(f, depth)
  depth = depth or 0
  if not f or depth > 16 then return nil end
  if f == CharacterFrame or f == PaperDollFrame then return 0, 0 end
  local point, rel, relPoint, x, y = f:GetPoint(1)
  if not point then return nil end
  rel = rel or f:GetParent()
  local rx, ry, rw, rh
  if rel == CharacterFrame or rel == PaperDollFrame or rel == UIParent then
    rx, ry, rw, rh = 0, 0, FRAME_W, FRAME_H
  else
    rx, ry = OffsetOf(rel, depth + 1)
    if not rx then return nil end
    rw, rh = rel:GetWidth(), rel:GetHeight()
  end
  local ax, ay = AnchorXY(relPoint, rw, rh)
  local px, py = AnchorXY(point, f:GetWidth(), f:GetHeight())
  return rx + ax + x - px, ry + ay + y - py
end
local function SheetPos(name, fx, fy)
  local f = _G[name]
  local x, y
  if f then x, y = OffsetOf(f) end
  if not x then return fx, fy end
  return x, y
end

-- Copy the large background pieces of one of the Character window's panes.
local function CloneArt(src, dst, fallback)
  local made = 0
  if src then
    for _, r in ipairs({ src:GetRegions() }) do
      if r:GetObjectType() == "Texture" then
        local file = r:GetTexture()
        if type(file) == "string" and r:GetWidth() >= 120 and r:GetHeight() >= 120 and not string.find(string.lower(file), "portrait", 1, true) then
          local p, rel, rp, x, y = r:GetPoint(1)
          if p and (rel == nil or rel == src or rel == CharacterFrame) then
            local t = dst:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(file)
            t:SetTexCoord(r:GetTexCoord())
            Size(t, r:GetWidth(), r:GetHeight())
            t:SetPoint(p, dst, rp, x, y)
            made = made + 1
          end
        end
      end
    end
  end
  if made == 0 then
    local base = "Interface\\PaperDollInfoFrame\\" .. fallback
    local pieces = { { "-L1", 256, 256, 2, -1 }, { "-R1", 128, 256, 258, -1 }, { "-BottomLeft", 256, 256, 2, -257 }, { "-BottomRight", 128, 256, 258, -257 } }
    for _, pc in ipairs(pieces) do
      local t = dst:CreateTexture(nil, "BACKGROUND")
      t:SetTexture(base .. pc[1])
      Size(t, pc[2], pc[3])
      t:SetPoint("TOPLEFT", pc[4], pc[5])
    end
  end
end

-- ================================================================ party pane (inside the Character window)

local pane = CreateFrame("Frame", "PartyManagerPane", CharacterFrame)
pane:SetAllPoints(CharacterFrame)
pane:Hide()

local artGear = CreateFrame("Frame", nil, pane)
artGear:SetAllPoints()
local artPlain = CreateFrame("Frame", nil, pane)
artPlain:SetAllPoints()

ui.level = pane:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")

-- companion tabs on the right edge, like spellbook schools; then the views
local StatRows, RefreshSideTabs, DownText
ui.sideTabs = {}
local function SideTab(i, y)
  local t = CreateFrame("CheckButton", "PartyManagerSideTab" .. i, pane, "SpellBookSkillLineTabTemplate")
  t:SetPoint("TOPLEFT", pane, "TOPRIGHT", -32, y)
  t:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return t
end
for i = 1, 5 do
  local t = SideTab(i, -65 - (i - 1) * 49)
  t:SetScript("OnClick", function(self)
    if self.low then PartyManager_Select(self.low)
    else self:SetChecked(false); PartyManager_SummonMenu(self) end
  end)
  t:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local c = self.low and FindChar(self.low)
    if c then
      GameTooltip:SetText(c.name, ClassColor(c.class))
      local s = state.stats[c.low]
      GameTooltip:AddLine(string.format("Level %d %s %s", (s and s.level) or c.level, RACE_NAME[c.race] or "", CLASS_NAME[c.class] or ""), 1, 1, 1)
      if s and ROLE_NAME[s.role] then GameTooltip:AddLine(ROLE_NAME[s.role], 0.8, 0.8, 0.8) end
      local down = DownText(c.low)
      if down then GameTooltip:AddLine(down) end
    else
      GameTooltip:SetText("Bring a character")
      GameTooltip:AddLine("Summon one of your characters to join the party.", 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
  end)
  ui.sideTabs[i] = t
end
ui.tacticsTab = SideTab(6, -65 - 5 * 49 - 18)
ui.tacticsTab:SetNormalTexture("Interface\\Icons\\Ability_Warrior_BattleShout")
ui.tacticsTab:SetScript("OnClick", function(self)
  state.view = state.view == "tactics" and "gear" or "tactics"
  PlaySound("igCharacterInfoTab")
  ui.Refresh()
end)
ui.tacticsTab:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText("Tactics")
  GameTooltip:AddLine("Party stance and orders.", 0.8, 0.8, 0.8, true)
  GameTooltip:Show()
end)
ui.lookTab = SideTab(7, -65 - 6 * 49 - 18)
ui.lookTab:SetNormalTexture("Interface\\Icons\\INV_Chest_Cloth_17")
ui.lookTab:SetScript("OnClick", function(self)
  self:SetChecked(false)
  if state.selected then PartyManager_OpenWardrobe(state.selected) end
end)
ui.lookTab:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetText("Appearance")
  GameTooltip:AddLine("Open the wardrobe for this companion.", 0.8, 0.8, 0.8, true)
  GameTooltip:Show()
end)

local menu = CreateFrame("Frame", "PartyManagerMenu", UIParent, "UIDropDownMenuTemplate")

-- ---------------------------------------------------------------- gear view

local gear = CreateFrame("Frame", nil, pane)
gear:SetAllPoints()

local function LinkId(link) return link and tonumber(string.match(link, "item:(%d+)")) end

-- The bag slot an item on the cursor came from: picking an item up locks its
-- slot, which works with any bag addon; the pickup hook is a tie-breaker.
local function PickedBagSlot(itemId)
  if lastPickup and lastPickup.bag >= 0 and lastPickup.bag <= 4 then
    local _, _, locked = GetContainerItemInfo(lastPickup.bag, lastPickup.slot)
    if locked and LinkId(GetContainerItemLink(lastPickup.bag, lastPickup.slot)) == itemId then
      return lastPickup.bag, lastPickup.slot
    end
  end
  for bag = 0, 4 do
    for slot = 1, GetContainerNumSlots(bag) do
      local _, _, locked = GetContainerItemInfo(bag, slot)
      if locked and LinkId(GetContainerItemLink(bag, slot)) == itemId then return bag, slot end
    end
  end
end

local function EquipFromCursor(slot)
  local kind, itemId = GetCursorInfo()
  if kind ~= "item" then return false end
  if not state.selected then ClearCursor(); return true end
  local cbag, cslot = PickedBagSlot(itemId)
  ClearCursor()
  local bag, bslot
  if cbag then bag, bslot = ServerPos(cbag, cslot) end
  if not bag then
    Print("Drag the item from your bags (not the bank or your own character sheet).")
    return true
  end
  Send(string.format("EQUIP %d %d %d %d", state.selected, bag, bslot, slot))
  return true
end

local function SlotPosition(slot)
  for i, s in ipairs(LEFT_COLUMN) do
    if s == slot then return SheetPos("Character" .. SLOT_NAME[slot], 21, -74 - (i - 1) * 41) end
  end
  for i, s in ipairs(RIGHT_COLUMN) do
    if s == slot then return SheetPos("Character" .. SLOT_NAME[slot], 305, -74 - (i - 1) * 41) end
  end
  for i, s in ipairs(WEAPONS) do
    if s == slot then return SheetPos("Character" .. SLOT_NAME[slot], 122 + (i - 1) * 46, -348) end
  end
end

ui.gearSlots = {}
for slot = 0, 18 do
  local b = MakeSlot(gear)
  b.slot = slot
  b:SetScript("OnClick", function(self, button)
    if EquipFromCursor(self.slot) then return end
    if button == "RightButton" and GearRec(state.selected, self.slot) then
      Send(string.format("UNEQUIP %d %d", state.selected, self.slot))
    end
  end)
  b:SetScript("OnReceiveDrag", function(self) EquipFromCursor(self.slot) end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local rec = GearRec(state.selected, self.slot)
    if rec then
      GameTooltip:SetHyperlink(ItemString(rec))
      if rec.fake == 1 then
        GameTooltip:AddLine("Appearance: hidden", 1, 0.82, 0)
      elseif rec.fake and rec.fake > 1 then
        GameTooltip:AddLine("Appearance: " .. (GetItemInfo(rec.fake) or ("item " .. rec.fake)), 1, 0.82, 0)
      end
      GameTooltip:AddLine("Right-click to take it back into your bags.", 0.6, 0.6, 0.6)
    else
      GameTooltip:SetText(SLOT_LABEL[self.slot])
      GameTooltip:AddLine("Drag an item here from your bags.", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
  end)
  ui.gearSlots[slot] = b
end

ui.model = MakeModel(gear)
ui.modelHint = gear:CreateFontString(nil, "OVERLAY", "GameFontDisable")
ui.modelHint:SetPoint("CENTER", ui.model, "CENTER")
ui.modelHint:SetWidth(180)
ui.rotL = RotateButton(gear, ui.model, -1)
ui.rotR = RotateButton(gear, ui.model, 1)

local function StatBox(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetBackdrop(INSET)
  f:SetBackdropColor(0, 0, 0, 0.6)
  f:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)
  f.lines = {}
  for i = 1, 6 do
    local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    l:SetPoint("TOPLEFT", 7, -6 - (i - 1) * 13)
    local v = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    v:SetPoint("TOPRIGHT", -7, -6 - (i - 1) * 13)
    f.lines[i] = { label = l, value = v }
  end
  return f
end
ui.statsLeft = StatBox(gear)
ui.statsRight = StatBox(gear)

-- Category dropdowns over each box, like the sheet's Base Stats / Melee menus.
local STAT_CATEGORIES = {
  { "base", "Base Stats" }, { "melee", "Melee" }, { "ranged", "Ranged" }, { "spell", "Spell" }, { "defense", "Defenses" },
}
local function StatChoice(low, side)
  PartyManagerDB.statView = PartyManagerDB.statView or {}
  local v = PartyManagerDB.statView[low]
  if v and v[side] then return v[side] end
  if side == "left" then return "base" end
  local c = FindChar(low)
  local cls = c and c.class
  if cls == 3 then return "ranged" end
  if cls == 5 or cls == 8 or cls == 9 then return "spell" end
  return "melee"
end
local function CategoryName(key)
  for _, cat in ipairs(STAT_CATEGORIES) do if cat[1] == key then return cat[2] end end
  return key
end
local function StatDropdown(name, side, box)
  local dd = CreateFrame("Frame", name, gear, "UIDropDownMenuTemplate")
  dd.side, dd.box = side, box
  UIDropDownMenu_Initialize(dd, function(self)
    local current = state.selected and StatChoice(state.selected, side)
    for _, cat in ipairs(STAT_CATEGORIES) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = cat[2]
      info.value = cat[1]
      info.checked = cat[1] == current
      info.func = function(button)
        if not state.selected then return end
        PartyManagerDB.statView = PartyManagerDB.statView or {}
        PartyManagerDB.statView[state.selected] = PartyManagerDB.statView[state.selected] or {}
        PartyManagerDB.statView[state.selected][side] = button.value
        UIDropDownMenu_SetSelectedValue(dd, button.value)
        UIDropDownMenu_SetText(dd, cat[2])
        ui.Refresh()
      end
      UIDropDownMenu_AddButton(info)
    end
  end)
  return dd
end
ui.statsLeftDD = StatDropdown("PartyManagerStatLeftDropDown", "left", ui.statsLeft)
ui.statsRightDD = StatDropdown("PartyManagerStatRightDropDown", "right", ui.statsRight)

-- ---------------------------------------------------------------- tactics view

local tactics = CreateFrame("Frame", nil, pane)
tactics:SetAllPoints()

local function Header(parent, text, x, y)
  local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  h:SetPoint("TOPLEFT", x, y)
  h:SetText(text)
  return h
end

local function IconAction(parent, icon, label, title, body, onClick)
  local b = MakeSlot(parent)
  b.icon:SetTexture("Interface\\Icons\\" .. icon)
  b.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("TOP", b, "BOTTOM", 0, -3)
  b.label:SetText(label)
  b:SetScript("OnClick", onClick)
  Tip(b, title, body)
  return b
end

local STANCES = {
  { "Assist", "Ability_Warrior_BattleShout", "The tank opens on any hostile you target and the rest join in. They defend the party." },
  { "Defend", "Ability_Defend", "They only fight what attacks the party." },
  { "Aggressive", "Ability_Warrior_Rampage", "They also clear hostiles that come within 20 yards of you." },
  { "Passive", "Spell_Nature_Sleep", "They never fight. Good for running past things." },
}
Header(tactics, "Party stance", 24, -80)
ui.stances = {}
for i, s in ipairs(STANCES) do
  local b = IconAction(tactics, s[2], s[1], s[1], s[3], function() Send("STANCE " .. (i - 1)) end)
  b:SetPoint("TOPLEFT", 30 + (i - 1) * 76, -100)
  ui.stances[i] = b
end
ui.stanceText = tactics:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ui.stanceText:SetPoint("TOPLEFT", 26, -158)
ui.stanceText:SetWidth(300)
ui.stanceText:SetJustifyH("LEFT")

Header(tactics, "Whole party", 24, -196)
local PARTY_ORDERS = {
  { "Follow", "Ability_Tracking", "Everyone follows you.", "ORDER 0 follow" },
  { "Hold", "Spell_Nature_TimeStop", "Everyone stays where they are.", "ORDER 0 stay" },
  { "Attack", "Ability_SteelMelee", "Everyone attacks your target.", "ORDER 0 attack" },
  { "Regroup", "Spell_Arcane_Blink", "Anyone lost or stuck comes to you.", "ORDER 0 come" },
}
for i, o in ipairs(PARTY_ORDERS) do
  local b = IconAction(tactics, o[2], o[1], o[1], o[3], function() Send(o[4]) end)
  b:SetPoint("TOPLEFT", 30 + (i - 1) * 76, -216)
end

ui.soloHeader = Header(tactics, "", 24, -276)
local ORDERS = {
  { "Follow", "Ability_Tracking", "Stay close to you.", "follow" },
  { "Hold", "Spell_Nature_TimeStop", "Stay right here.", "stay" },
  { "Attack", "Ability_SteelMelee", "Attack your current target.", "attack" },
  { "Tank", "Ability_Warrior_DefensiveStance", "Taunt and hold your target.", "tank" },
  { "Come", "Spell_Arcane_Blink", "Teleport to you if lost or stuck.", "come" },
  { "Rebuff", "Spell_Holy_WordFortitude", "Recast their buffs on the party.", "rebuff" },
}
for i, o in ipairs(ORDERS) do
  local b = IconAction(tactics, o[2], o[1], o[1], o[3], function()
    if state.selected then Send("ORDER " .. state.selected .. " " .. o[4]) end
  end)
  b:SetPoint("TOPLEFT", 26 + (i - 1) * 50, -296)
end
ui.homeBtn = PanelButton(tactics, "Send home", 110, function() if state.selected then Send("DISMISS " .. state.selected) end end)
ui.homeBtn:SetPoint("TOPLEFT", 26, -362)
Tip(ui.homeBtn, "Send home", "Logs this companion out. What they wear stays on them.")
local allHome = PanelButton(tactics, "Send everyone home", 150, function() Send("DISMISS 0") end)
allHome:SetPoint("LEFT", ui.homeBtn, "RIGHT", 8, 0)
local tacticsNote = tactics:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
tacticsNote:SetPoint("TOPLEFT", 26, -394)
tacticsNote:SetWidth(300)
tacticsNote:SetJustifyH("LEFT")
tacticsNote:SetText("Companions level with you, pick their own talents, loot for you and get back up after a fight.")

-- ---------------------------------------------------------------- empty view

local empty = CreateFrame("Frame", nil, pane)
empty:SetAllPoints()
local emptyText = empty:CreateFontString(nil, "OVERLAY", "GameFontNormal")
emptyText:SetPoint("CENTER", -14, 60)
emptyText:SetWidth(260)
emptyText:SetText("Your party is empty")
local emptyBody = empty:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
emptyBody:SetPoint("TOP", emptyText, "BOTTOM", 0, -8)
emptyBody:SetWidth(260)
emptyBody:SetText("Bring up to four of your own characters. They level with you, wear what you give them and fight at your side.")
local emptyBtn = PanelButton(empty, "Bring a character", 150, function(self) PartyManager_SummonMenu(self) end)
emptyBtn:SetPoint("TOP", emptyBody, "BOTTOM", 0, -14)

-- ---------------------------------------------------------------- pane layout

local function PlacePane()
  CloneArt(PaperDollFrame, artGear, "UI-Character-CharacterTab")
  CloneArt(ReputationFrame, artPlain, "UI-Character-General")
  local p, rel, rp, x, y
  if CharacterLevelText then p, rel, rp, x, y = CharacterLevelText:GetPoint(1) end
  ui.level:ClearAllPoints()
  if p and (rel == CharacterFrame or rel == PaperDollFrame or rel == nil) then ui.level:SetPoint(p, pane, rp, x, y)
  else ui.level:SetPoint("TOP", pane, "TOP", 0, -45) end

  local lx, ly = SlotPosition(0)
  local rx = SlotPosition(9)
  local wx, wy = SlotPosition(15)
  for slot, b in pairs(ui.gearSlots) do
    local sx, sy = SlotPosition(slot)
    b:ClearAllPoints(); b:SetPoint("TOPLEFT", gear, "TOPLEFT", sx, sy)
  end
  local left, right = lx + 41, rx - 4
  -- stats sit just above the weapon row; the model fills the space above them
  local boxH = 6 * 13 + 10
  local statBottom = wy + 6
  local boxTop = statBottom + boxH
  local statTop = boxTop + 28
  local half = (right - left - 6) / 2
  ui.statsLeft:ClearAllPoints(); ui.statsLeft:SetPoint("TOPLEFT", gear, "TOPLEFT", left, boxTop); Size(ui.statsLeft, half, boxH)
  ui.statsRight:ClearAllPoints(); ui.statsRight:SetPoint("TOPLEFT", ui.statsLeft, "TOPRIGHT", 6, 0); Size(ui.statsRight, half, boxH)
  for _, dd in ipairs({ ui.statsLeftDD, ui.statsRightDD }) do
    dd:ClearAllPoints()
    dd:SetPoint("BOTTOMLEFT", dd.box, "TOPLEFT", -16, -4)
    UIDropDownMenu_SetWidth(dd, half - 24)
  end
  local mx, my = SheetPos("CharacterModelFrame", left + 4, ly)
  local mw = right - left - 8
  local cm = _G.CharacterModelFrame
  if cm and cm:GetWidth() > 0 then mw = cm:GetWidth() end
  ui.model:ClearAllPoints()
  ui.model:SetPoint("TOPLEFT", gear, "TOPLEFT", mx, my)
  Size(ui.model, mw, math.max(120, my - statTop - 4))
  ui.rotL:ClearAllPoints(); ui.rotL:SetPoint("TOPLEFT", ui.model, "TOPLEFT", 3, -3)
  ui.rotR:ClearAllPoints(); ui.rotR:SetPoint("LEFT", ui.rotL, "RIGHT", 2, 0)
end

-- ================================================================ wardrobe window

local wf = CreateFrame("Frame", "PartyManagerWardrobe", UIParent)
Size(wf, 776, 500)
wf:SetPoint("CENTER", 0, 30)
wf:SetBackdrop({
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = true, tileSize = 32, edgeSize = 32,
  insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
wf:SetFrameStrata("HIGH")
wf:SetToplevel(true)
wf:EnableMouse(true)
wf:SetMovable(true)
wf:SetClampedToScreen(true)
wf:RegisterForDrag("LeftButton")
wf:SetScript("OnDragStart", function(self) self:StartMoving() end)
wf:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
wf:Hide()
tinsert(UISpecialFrames, "PartyManagerWardrobe")
local wHeader = wf:CreateTexture(nil, "ARTWORK")
wHeader:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
Size(wHeader, 256, 64)
wHeader:SetPoint("TOP", 0, 12)
local wTitle = wf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
wTitle:SetPoint("TOP", wHeader, "TOP", 0, -14)
wTitle:SetText("Transmogrify")
local wClose = CreateFrame("Button", "PartyManagerWardrobeClose", wf, "UIPanelCloseButton")
wClose:SetPoint("TOPRIGHT", -4, -4)

-- left: who, dressing room, slots
wui.prev = PageButton(wf, "Prev", function() PartyManager_CycleWardrobe(-1) end)
wui.prev:SetPoint("TOPLEFT", 20, -26)
wui.next = PageButton(wf, "Next", function() PartyManager_CycleWardrobe(1) end)
wui.next:SetPoint("TOPLEFT", 312, -26)
wui.who = wf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
wui.who:SetPoint("TOP", wf, "TOPLEFT", 180, -30)

local stage = CreateFrame("Frame", nil, wf)
stage:SetPoint("TOPLEFT", 20, -58)
Size(stage, 320, 384)
wui.bg = {}
local BG_PIECES = { { 256, 256, 0, 0 }, { 64, 256, 256, 0 }, { 256, 128, 0, -256 }, { 64, 128, 256, -256 } }
for i, pc in ipairs(BG_PIECES) do
  local t = stage:CreateTexture(nil, "BACKGROUND")
  Size(t, pc[1], pc[2])
  t:SetPoint("TOPLEFT", pc[3], pc[4])
  wui.bg[i] = t
end
local stageBorder = CreateFrame("Frame", nil, wf)
stageBorder:SetPoint("TOPLEFT", stage, "TOPLEFT", -4, 4)
stageBorder:SetPoint("BOTTOMRIGHT", stage, "BOTTOMRIGHT", 4, -4)
stageBorder:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
stageBorder:SetBackdropBorderColor(0.6, 0.6, 0.6)

wui.model = MakeModel(stage)
wui.model:SetPoint("TOPLEFT", 50, -10)
Size(wui.model, 220, 310)
wui.modelHint = stage:CreateFontString(nil, "OVERLAY", "GameFontDisable")
wui.modelHint:SetPoint("CENTER", wui.model, "CENTER")
wui.modelHint:SetWidth(180)
wui.rotL = RotateButton(stage, wui.model, -1)
wui.rotL:SetPoint("BOTTOMLEFT", stage, "BOTTOMLEFT", 54, 50)
wui.rotR = RotateButton(stage, wui.model, 1)
wui.rotR:SetPoint("LEFT", wui.rotL, "RIGHT", 2, 0)

wui.slots = {}
local function WardrobeSlot(slot, x, y)
  local b = MakeSlot(stage)
  b:SetPoint("TOPLEFT", x, y)
  b:SetFrameLevel(wui.model:GetFrameLevel() + 2)
  b.slot = slot
  b:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      wardrobe.pending[self.slot] = nil
      wui.model.dirty = true
    else
      wardrobe.slot = self.slot
      wardrobe.page = 1
      if wardrobe.low and not wardrobe.lists[wardrobe.low .. ":" .. self.slot] then
        Send("TLIST " .. wardrobe.low .. " " .. self.slot)
      end
    end
    wui.Refresh()
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(SLOT_LABEL[self.slot])
    local rec = GearRec(wardrobe.low, self.slot)
    if rec then
      GameTooltip:AddLine("Wearing: " .. (GetItemInfo(rec.entry) or ("item " .. rec.entry)), 1, 1, 1)
      if rec.fake == 1 then GameTooltip:AddLine("Look: hidden", 1, 0.82, 0)
      elseif rec.fake and rec.fake > 1 then GameTooltip:AddLine("Look: " .. (GetItemInfo(rec.fake) or ("item " .. rec.fake)), 1, 0.82, 0) end
    else
      GameTooltip:AddLine("Nothing equipped here.", 0.6, 0.6, 0.6)
    end
    if wardrobe.pending[self.slot] ~= nil then GameTooltip:AddLine("Change waiting - right-click to undo it.", 0.75, 0.55, 1) end
    GameTooltip:Show()
  end)
  wui.slots[slot] = b
end
for i, slot in ipairs({ 0, 2, 14, 4, 3, 18, 8 }) do WardrobeSlot(slot, 6, -6 - (i - 1) * 42) end
for i, slot in ipairs({ 9, 5, 6, 7 }) do WardrobeSlot(slot, 277, -6 - (i - 1) * 42) end
for i, slot in ipairs({ 15, 16, 17 }) do WardrobeSlot(slot, 99 + (i - 1) * 42, -340) end

-- under the stage: outfits
local outfitLabel = wf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
outfitLabel:SetPoint("TOPLEFT", stage, "BOTTOMLEFT", 2, -14)
outfitLabel:SetText("Outfits:")
wui.outfits = {}
for k = 1, 5 do
  local b = PanelButton(wf, tostring(k), 30, nil)
  b:SetPoint("LEFT", outfitLabel, "RIGHT", 6 + (k - 1) * 32, 0)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, button)
    local low = wardrobe.low
    if not low then return end
    local saved = (state.outfits[low] or {})[k - 1]
    if IsShiftKeyDown() then
      Send(string.format("OSAVE %d %d", low, k - 1))
    elseif button == "RightButton" and saved then
      Send(string.format("ODEL %d %d", low, k - 1))
    elseif saved then
      wardrobe.pending = {}
      Send(string.format("OUSE %d %d", low, k - 1))
    else
      Print("Outfit " .. k .. " is empty. Shift-click it to save the current look.")
    end
  end)
  Tip(b, "Outfit " .. k, "Click to wear it - free, works anywhere. Shift-click to save the current look here. Right-click to clear it.")
  wui.outfits[k] = b
end

-- right: the collection
local coll = CreateFrame("Frame", nil, wf)
coll:SetPoint("TOPLEFT", stage, "TOPRIGHT", 14, 28)
Size(coll, 408, 446)
coll:SetBackdrop(INSET)
coll:SetBackdropColor(0, 0, 0, 0.45)
coll:SetBackdropBorderColor(0.6, 0.6, 0.6)
wui.slotTitle = coll:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
wui.slotTitle:SetPoint("TOPLEFT", 12, -12)
wui.count = coll:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
wui.count:SetPoint("BOTTOMLEFT", wui.slotTitle, "BOTTOMRIGHT", 8, 1)
wui.locked = CreateFrame("CheckButton", "PartyManagerShowLocked", coll, "UICheckButtonTemplate")
Size(wui.locked, 24, 24)
wui.locked:SetPoint("TOPRIGHT", -8, -8)
wui.locked:SetScript("OnClick", function(self)
  wardrobe.showLocked = self:GetChecked() and true or false
  wardrobe.page = 1
  wui.Refresh()
end)
local lockedLabel = coll:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
lockedLabel:SetPoint("RIGHT", wui.locked, "LEFT", -2, 1)
lockedLabel:SetText("Show uncollected")
wui.progress = CreateFrame("StatusBar", nil, coll)
wui.progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
wui.progress:SetStatusBarColor(0.1, 0.75, 0.1)
wui.progress:SetMinMaxValues(0, 1)
wui.progress:SetPoint("TOPLEFT", 12, -38)
wui.progress:SetPoint("TOPRIGHT", -12, -38)
wui.progress:SetHeight(8)
local progBorder = CreateFrame("Frame", nil, wui.progress)
progBorder:SetPoint("TOPLEFT", -3, 3)
progBorder:SetPoint("BOTTOMRIGHT", 3, -3)
progBorder:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 8, edgeSize = 8, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
progBorder:SetBackdropColor(0, 0, 0, 0.7)
progBorder:SetFrameLevel(wui.progress:GetFrameLevel() - 1)

wui.cells = {}
for i = 1, 12 do
  local cell = CreateFrame("Button", nil, coll)
  Size(cell, 92, 108)
  cell:SetPoint("TOPLEFT", 12 + ((i - 1) % 4) * 97, -54 - floor((i - 1) / 4) * 113)
  cell:SetBackdrop(INSET)
  cell:SetBackdropColor(0, 0, 0, 0.8)
  cell.model = CreateFrame("DressUpModel", nil, cell)
  cell.model:SetPoint("TOPLEFT", 4, -4)
  cell.model:SetPoint("BOTTOMRIGHT", -4, 4)
  cell.model:EnableMouse(false)
  cell.icon = cell:CreateTexture(nil, "ARTWORK")
  Size(cell.icon, 40, 40)
  cell.icon:SetPoint("CENTER")
  -- models draw over their parent's textures, so marks sit on a layer above
  local top = CreateFrame("Frame", nil, cell)
  top:SetAllPoints()
  top:SetFrameLevel(cell.model:GetFrameLevel() + 1)
  cell.veil = top:CreateTexture(nil, "BACKGROUND")
  cell.veil:SetPoint("TOPLEFT", 4, -4)
  cell.veil:SetPoint("BOTTOMRIGHT", -4, 4)
  cell.veil:SetTexture(0, 0, 0, 0.6)
  cell.lock = top:CreateTexture(nil, "ARTWORK")
  cell.lock:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-LOCK")
  Size(cell.lock, 18, 18)
  cell.lock:SetPoint("TOPRIGHT", -5, -5)
  cell.check = top:CreateTexture(nil, "OVERLAY")
  cell.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  Size(cell.check, 22, 22)
  cell.check:SetPoint("BOTTOMRIGHT", -2, 2)
  cell.hl = top:CreateTexture(nil, "OVERLAY")
  cell.hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
  cell.hl:SetBlendMode("ADD")
  cell.hl:SetPoint("TOPLEFT", 4, -4)
  cell.hl:SetPoint("BOTTOMRIGHT", -4, 4)
  cell.hl:Hide()
  cell:SetScript("OnClick", function(self)
    if not self.entry or not wardrobe.low then return end
    if self.locked then
      Print("You have not collected that look yet. Pick up the item on any character on this account to unlock it.")
      return
    end
    wardrobe.pending[wardrobe.slot] = self.entry
    wui.model.dirty = true
    wui.Refresh()
  end)
  cell:SetScript("OnEnter", function(self)
    self.hl:Show()
    if not self.entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. self.entry)
    if self.locked then GameTooltip:AddLine("Not collected yet", 1, 0.3, 0.3)
    else GameTooltip:AddLine("Collected - click to try it on", 0.3, 1, 0.3) end
    GameTooltip:Show()
  end)
  cell:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
  wui.cells[i] = cell
end
wui.empty = coll:CreateFontString(nil, "OVERLAY", "GameFontDisable")
wui.empty:SetPoint("CENTER", 0, 10)
wui.empty:SetWidth(300)

wui.pagePrev = PageButton(coll, "Prev", function() wardrobe.page = wardrobe.page - 1; wui.Refresh() end)
wui.pageText = coll:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
wui.pageText:SetPoint("BOTTOM", coll, "BOTTOM", 0, 44)
wui.pagePrev:SetPoint("RIGHT", wui.pageText, "LEFT", -6, 0)
wui.pageNext = PageButton(coll, "Next", function() wardrobe.page = wardrobe.page + 1; wui.Refresh() end)
wui.pageNext:SetPoint("LEFT", wui.pageText, "RIGHT", 6, 0)

wui.hide = PanelButton(coll, "Hide", 64, function()
  if GearRec(wardrobe.low, wardrobe.slot) then wardrobe.pending[wardrobe.slot] = 1; wui.model.dirty = true; wui.Refresh() end
end)
wui.hide:SetPoint("BOTTOMLEFT", 10, 10)
Tip(wui.hide, "Hide", "Make this piece invisible while still wearing it.")
wui.reset = PanelButton(coll, "Reset", 64, function()
  if GearRec(wardrobe.low, wardrobe.slot) then wardrobe.pending[wardrobe.slot] = 0; wui.model.dirty = true; wui.Refresh() end
end)
wui.reset:SetPoint("LEFT", wui.hide, "RIGHT", 4, 0)
Tip(wui.reset, "Reset", "Show the item as it really looks.")
wui.apply = PanelButton(coll, "Apply", 84, function()
  if not wardrobe.low then return end
  for slot, entry in pairs(wardrobe.pending) do
    Send(string.format("TSET %d %d %d", wardrobe.low, slot, entry))
  end
end)
wui.apply:SetPoint("BOTTOMRIGHT", -10, 10)
wui.undo = PanelButton(coll, "Undo", 64, function()
  wardrobe.pending = {}
  wui.model.dirty = true
  wui.Refresh()
end)
wui.undo:SetPoint("RIGHT", wui.apply, "LEFT", -4, 0)
wui.status = coll:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
wui.status:SetPoint("BOTTOM", coll, "BOTTOM", 0, 16)

-- ================================================================ refresh: pane

RefreshSideTabs = function()
  local list = Companions()
  local n = 0
  for i, t in ipairs(ui.sideTabs) do
    local c = list[i]
    if c then
      n = i
      t.low = c.low
      t:SetNormalTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
      t:GetNormalTexture():SetTexCoord(unpack(CLASS_ICON_TCOORDS[CLASS_FILE[c.class] or "WARRIOR"]))
      t:GetNormalTexture():SetDesaturated(DownText(c.low) ~= nil)
      t:SetChecked(state.selected == c.low and state.view == "gear")
      t:Show()
    else
      t:Hide()
      t.low = nil
    end
  end
  if #list < state.maxCompanions then
    local t = ui.sideTabs[n + 1]
    t.low = nil
    t:SetNormalTexture("Interface\\Icons\\Spell_ChargePositive")
    t:GetNormalTexture():SetTexCoord(0, 1, 0, 1)
    t:SetChecked(false)
    t:Show()
  end
  local any = #list > 0
  if any then ui.tacticsTab:Show(); ui.lookTab:Show() else ui.tacticsTab:Hide(); ui.lookTab:Hide() end
  ui.tacticsTab:SetChecked(state.view == "tactics")
  ui.lookTab:SetChecked(false)
end

local function StatLines(box, rows)
  for i, line in ipairs(box.lines) do
    local r = rows[i]
    line.label:SetText(r and (r[1] .. ":") or "")
    line.value:SetText(r and r[2] or "")
  end
end

-- "down, back in 12s" while a companion waits to get up.
DownText = function(low)
  local s = state.stats[low]
  if not s or s.alive then return nil end
  if s.reviveAt then
    local left = math.max(0, math.ceil(s.reviveAt - GetTime()))
    if left > 0 then return "|cffff4040Down - back in " .. left .. "s|r" end
  end
  return "|cffff4040Down - back after the fight|r"
end

-- While the Party tab shows, the window title belongs to the companion.
local function ShowTitle(c)
  if c then
    local unit = UnitForLow(c.low)
    if unit then SetPortraitTexture(CharacterFramePortrait, unit) end
    CharacterNameText:SetText(c.name)
    local s = state.stats[c.low]
    local role = s and ROLE_NAME[s.role]
    local down = DownText(c.low)
    if down then
      ui.level:SetText(down)
    else
      ui.level:SetText(string.format("Level %d %s %s%s", (s and s.level) or c.level or 0, RACE_NAME[c.race or 0] or "",
        CLASS_NAME[c.class or 0] or "", role and ("  (" .. role .. ")") or ""))
    end
  else
    SetPortraitTexture(CharacterFramePortrait, "player")
    CharacterNameText:SetText("Party")
    ui.level:SetText("No companions yet")
  end
end

local function Pct(v) return v and string.format("%.2f%%", v / 100) or "-" end
local function Dmg(lo, hi)
  if not hi or hi == 0 then return "N/A" end
  return lo .. " - " .. hi
end
local function Speed(v)
  if not v or v == 0 then return "N/A" end
  return string.format("%.2f", v / 100)
end
-- The same lines the character sheet shows for each category.
StatRows = function(key, s, x)
  if not s then return {} end
  if key == "base" then
    return { { "Strength", s.str }, { "Agility", s.agi }, { "Stamina", s.sta }, { "Intellect", s.int }, { "Spirit", s.spi }, { "Armor", s.armor } }
  end
  if not x then return {} end
  if key == "melee" then
    return { { "Damage", Dmg(x.mmin, x.mmax) }, { "Speed", Speed(x.mspeed) }, { "Power", x.ap }, { "Hit Rating", x.mhit },
      { "Crit Chance", Pct(x.mcrit) }, { "Expertise", x.exp } }
  elseif key == "ranged" then
    return { { "Damage", Dmg(x.rmin, x.rmax) }, { "Speed", Speed(x.rspeed) }, { "Power", x.rap }, { "Hit Rating", x.rhit },
      { "Crit Chance", Pct(x.rcrit) } }
  elseif key == "spell" then
    return { { "Bonus Damage", x.sdmg }, { "Bonus Healing", x.heal }, { "Hit Rating", x.shit }, { "Crit Chance", Pct(x.scrit) },
      { "Haste Rating", x.haste }, { "Mana Regen", x.regen } }
  elseif key == "defense" then
    return { { "Armor", x.armor }, { "Defense", x.def }, { "Dodge", Pct(x.dodge) }, { "Parry", Pct(x.parry) },
      { "Block", Pct(x.block) }, { "Resilience", x.resil } }
  end
  return {}
end

local function RefreshGear(c)
  local recs = state.gear[c.low] or {}
  for slot, b in pairs(ui.gearSlots) do
    local rec = recs[slot]
    SetSlotIcon(b, slot, rec and rec.entry)
    if rec and rec.fake and rec.fake > 0 then b.check:Show() else b.check:Hide() end
    if rec and rec.dur < 20 then b.icon:SetVertexColor(1, 0.3, 0.3) end
  end
  local unit = UnitForLow(c.low)
  if unit and UnitIsVisible(unit) then
    ui.model:Show(); ui.rotL:Show(); ui.rotR:Show(); ui.modelHint:Hide()
    SetModelUnit(ui.model, unit)
  else
    ui.model:Hide(); ui.rotL:Hide(); ui.rotR:Hide(); ui.model.unit = nil
    ui.modelHint:SetText("Out of sight. Use Regroup in Tactics.")
    ui.modelHint:Show()
  end
  for _, dd in ipairs({ ui.statsLeftDD, ui.statsRightDD }) do
    local key = StatChoice(c.low, dd.side)
    UIDropDownMenu_SetSelectedValue(dd, key)
    UIDropDownMenu_SetText(dd, CategoryName(key))
    StatLines(dd.box, StatRows(key, state.stats[c.low], state.ext[c.low]))
  end
end

local function RefreshTactics(c)
  for i, b in ipairs(ui.stances) do
    if state.stance == i - 1 then b.border:SetVertexColor(1, 0.82, 0); b.border:Show() else b.border:Hide() end
  end
  ui.stanceText:SetText(STANCES[state.stance + 1][3])
  ui.soloHeader:SetText(c.name .. " only")
end

function ui.Refresh()
  if not pane:IsShown() then return end
  local list = Companions()
  if state.selected then
    local c = FindChar(state.selected)
    if not c or c.state ~= "S" then state.selected = nil end
  end
  if not state.selected and list[1] then
    state.selected = list[1].low
    Send("GEAR " .. state.selected)
  end
  RefreshSideTabs()
  local c = state.selected and FindChar(state.selected)
  gear:Hide(); tactics:Hide(); empty:Hide()
  ShowTitle(c)
  if not c then
    artGear:Hide(); artPlain:Show(); empty:Show()
    return
  end
  if state.view == "tactics" then
    artGear:Hide(); artPlain:Show(); tactics:Show(); RefreshTactics(c)
  else
    artPlain:Hide(); artGear:Show(); gear:Show(); RefreshGear(c)
  end
end

-- ================================================================ refresh: wardrobe

local function CurrentLook(slot)
  local rec = GearRec(wardrobe.low, slot)
  if not rec then return nil end
  if wardrobe.pending[slot] ~= nil then return wardrobe.pending[slot] end
  return rec.fake or 0
end

local function DressPending(model)
  for _, entry in pairs(wardrobe.pending) do
    if entry > 1 then model:TryOn("item:" .. entry) end
  end
end

local function VisibleEntries(list)
  local out = {}
  for _, e in ipairs(list.entries) do
    local locked = e < 0
    if wardrobe.showLocked or not locked then out[#out + 1] = { entry = locked and -e or e, locked = locked } end
  end
  return out
end

function wui.Refresh()
  if not wf:IsShown() then return end
  local c = wardrobe.low and FindChar(wardrobe.low)
  if not c or c.state ~= "S" then
    local first = Companions()[1]
    if not first then wf:Hide(); return end
    wardrobe.low, wardrobe.pending = first.low, {}
    c = first
    Send("GEAR " .. c.low); Send("OUTFITS " .. c.low)
  end
  wui.who:SetText(c.name)
  wui.who:SetTextColor(ClassColor(c.class))
  if #Companions() > 1 then wui.prev:Show(); wui.next:Show() else wui.prev:Hide(); wui.next:Hide() end
  local file = RACE_FILE[c.race or 1] or "Human"
  for i, t in ipairs(wui.bg) do t:SetTexture("Interface\\DressUpFrame\\DressUpBackground-" .. file .. i) end

  local unit = UnitForLow(c.low)
  local visible = unit and UnitIsVisible(unit)
  if visible then
    wui.model:Show(); wui.rotL:Show(); wui.rotR:Show(); wui.modelHint:Hide()
    SetModelUnit(wui.model, unit, DressPending)
  else
    wui.model:Hide(); wui.rotL:Hide(); wui.rotR:Hide(); wui.model.unit = nil; wui.modelHint:Show()
    wui.modelHint:SetText("Bring them closer to see them here.")
  end

  local pendingCount = 0
  for slot, b in pairs(wui.slots) do
    local rec = GearRec(c.low, slot)
    local lookEntry = CurrentLook(slot)
    SetSlotIcon(b, slot, rec and ((lookEntry and lookEntry > 1) and lookEntry or rec.entry))
    if lookEntry == 1 then b.icon:SetVertexColor(0.4, 0.4, 0.4) end
    if wardrobe.pending[slot] ~= nil then
      b.border:SetVertexColor(0.75, 0.45, 1); b.border:Show(); pendingCount = pendingCount + 1
    elseif wardrobe.slot == slot then
      b.border:SetVertexColor(1, 0.82, 0); b.border:Show()
    else
      b.border:Hide()
    end
    if rec and rec.fake and rec.fake > 0 then b.check:Show() else b.check:Hide() end
  end
  local saved = state.outfits[c.low] or {}
  for k, b in ipairs(wui.outfits) do
    if saved[k - 1] then b:LockHighlight() else b:UnlockHighlight() end
  end

  local list = wardrobe.lists[c.low .. ":" .. wardrobe.slot]
  local near = list and list.near
  wui.slotTitle:SetText(SLOT_LABEL[wardrobe.slot])
  if list and list.total > 0 then
    wui.count:SetText(list.collected .. " / " .. list.total .. " collected")
    wui.progress:SetValue(list.collected / list.total)
    wui.progress:Show()
  else
    wui.count:SetText("")
    wui.progress:Hide()
  end
  wui.locked:SetChecked(wardrobe.showLocked)
  local hasItem = GearRec(c.low, wardrobe.slot) ~= nil
  if hasItem and HIDEABLE[wardrobe.slot] and (not list or list.allowHide) then wui.hide:Enable() else wui.hide:Disable() end
  if hasItem then wui.reset:Enable() else wui.reset:Disable() end
  if pendingCount > 0 then
    wui.status:SetText(near and (pendingCount .. " change(s) - free") or "|cffff6060Apply at a Transmogrifier|r")
  else
    wui.status:SetText("")
  end
  if pendingCount > 0 and near then wui.apply:Enable() else wui.apply:Disable() end
  if pendingCount > 0 then wui.undo:Enable() else wui.undo:Disable() end

  local entries = list and VisibleEntries(list) or {}
  local perPage = #wui.cells
  local pages = math.max(1, math.ceil(#entries / perPage))
  wardrobe.page = math.min(math.max(wardrobe.page, 1), pages)
  local current = CurrentLook(wardrobe.slot)
  local rec = GearRec(c.low, wardrobe.slot)
  local cam = SLOT_CAMERA[wardrobe.slot] or { 0, 0, 0.35 }
  for i, cell in ipairs(wui.cells) do
    local e = entries[(wardrobe.page - 1) * perPage + i]
    cell.entry, cell.locked = e and e.entry, e and e.locked
    if not e then
      cell:Hide()
    else
      cell:Show()
      if visible then
        cell.icon:Hide(); cell.model:Show()
        if cell.model.entry ~= e.entry or cell.model.unit ~= unit or cell.model.slot ~= wardrobe.slot then
          cell.model:SetUnit(unit)
          cell.model:Undress()
          cell.model:TryOn("item:" .. e.entry)
          cell.model:SetFacing(cam[3])
          cell.model:SetPosition(cam[1], 0, cam[2])
          cell.model.entry, cell.model.unit, cell.model.slot = e.entry, unit, wardrobe.slot
        end
      else
        cell.model:Hide(); cell.icon:Show()
        cell.icon:SetTexture(GetItemIcon(e.entry) or "Interface\\Icons\\INV_Misc_QuestionMark")
      end
      if e.locked then
        cell.veil:Show(); cell.lock:Show(); cell.icon:SetDesaturated(true)
        cell:SetBackdropBorderColor(0.35, 0.35, 0.35)
      else
        cell.veil:Hide(); cell.lock:Hide(); cell.icon:SetDesaturated(false)
        if current == e.entry then cell:SetBackdropBorderColor(0.75, 0.45, 1)
        elseif rec and rec.fake == e.entry then cell:SetBackdropBorderColor(1, 0.82, 0)
        else cell:SetBackdropBorderColor(0.6, 0.6, 0.6) end
      end
      if rec and rec.fake == e.entry then cell.check:Show() else cell.check:Hide() end
    end
  end
  if not hasItem then
    wui.empty:SetText("Nothing is equipped in this slot. Give them something to wear there first.")
    wui.empty:Show()
  elseif not list then
    wui.empty:SetText("Loading looks...")
    wui.empty:Show()
  elseif #entries == 0 then
    wui.empty:SetText("No look fits this piece yet.")
    wui.empty:Show()
  else
    wui.empty:Hide()
  end
  wui.pageText:SetText(string.format("Page %d / %d", wardrobe.page, pages))
  if wardrobe.page > 1 then wui.pagePrev:Enable() else wui.pagePrev:Disable() end
  if wardrobe.page < pages then wui.pageNext:Enable() else wui.pageNext:Disable() end
end

function PartyManager_OpenWardrobe(low, nearNpc)
  if wardrobe.low ~= low then wardrobe.pending = {} end
  wardrobe.low = low
  wardrobe.lists = {}
  if not GearRec(low, wardrobe.slot) then
    for _, s in ipairs({ 4, 0, 2, 14, 6, 7, 9, 5, 8, 15, 16, 17, 3, 18 }) do
      if GearRec(low, s) then wardrobe.slot = s; break end
    end
  end
  wf:Show()
  wui.model.dirty = true
  Send("WATCH 1")
  Send("GEAR " .. low)
  Send("OUTFITS " .. low)
  Send("TLIST " .. low .. " " .. wardrobe.slot)
  wui.Refresh()
end

function PartyManager_CycleWardrobe(step)
  local list = Companions()
  if #list == 0 then return end
  local idx = 1
  for i, c in ipairs(list) do if c.low == wardrobe.low then idx = i end end
  idx = ((idx - 1 + step) % #list) + 1
  PartyManager_OpenWardrobe(list[idx].low)
end

wf:SetScript("OnShow", function() PlaySound("igCharacterInfoOpen") end)
wf:SetScript("OnHide", function()
  wardrobe.pending = {}
  if not pane:IsShown() then Send("WATCH 0") end
  PlaySound("igCharacterInfoClose")
end)

-- ================================================================ actions

function PartyManager_Select(low)
  state.selected = low
  state.view = "gear"
  ui.model.dirty = true
  Send("GEAR " .. low)
  PlaySound("igCharacterInfoTab")
  ui.Refresh()
end

function PartyManager_SummonMenu(anchor)
  local items = { { text = "Bring a character", isTitle = true, notCheckable = true } }
  local full = #Companions() >= state.maxCompanions
  for _, c in ipairs(state.roster) do
    if c.state ~= "S" then
      local r, g, b = ClassColor(c.class)
      local color = string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
      items[#items + 1] = {
        text = string.format("%s%s|r  %d %s%s", color, c.name, c.level, CLASS_NAME[c.class] or "",
          c.state == "B" and "  (busy)" or (c.state == "F" and "  (other faction)" or "")),
        notCheckable = true,
        disabled = full or c.state == "B" or c.state == "F",
        func = function() Send("SUMMON " .. c.low) end,
      }
    end
  end
  if #items == 1 then items[2] = { text = "No other characters on this account", disabled = true, notCheckable = true } end
  items[#items + 1] = { text = CANCEL, notCheckable = true, func = function() end }
  EasyMenu(items, menu, anchor, 0, 0, "MENU")
end

-- ================================================================ protocol

local handlers = {}

handlers.RB = function() buffers.R = {} end
handlers.R = function(p)
  for _, rec in ipairs(Split(p[2], ";")) do
    local f = Split(rec, ":")
    if #f >= 7 then
      buffers.R[#buffers.R + 1] = {
        low = tonumber(f[1]), name = f[2], race = tonumber(f[3]), class = tonumber(f[4]),
        gender = tonumber(f[5]), level = tonumber(f[6]), state = f[7],
      }
    end
  end
end
handlers.RE = function(p)
  state.roster = buffers.R
  state.maxCompanions = tonumber(p[2]) or 4
  state.levelLock = p[3] == "1"
  state.stance = tonumber(p[4]) or 0
  ui.Refresh(); wui.Refresh()
end

handlers.S = function(p)
  local low = tonumber(p[2])
  if low == 0 then return end
  state.stats[low] = {
    hp = tonumber(p[3]), maxhp = tonumber(p[4]), powertype = tonumber(p[5]), power = tonumber(p[6]), maxpower = tonumber(p[7]),
    level = tonumber(p[8]), str = p[9], agi = p[10], sta = p[11], int = p[12], spi = p[13], armor = p[14],
    ap = p[15], rap = p[16], sp = p[17], crit = tonumber(p[18]) or 0, scrit = tonumber(p[19]) or 0,
    ilvl = p[20], alive = p[21] == "1", role = p[22], near = p[23] == "1", talents = p[24],
  }
  local reviveIn = tonumber(p[25]) or 0
  state.stats[low].reviveAt = reviveIn > 0 and (GetTime() + reviveIn) or nil
  local c = FindChar(low)
  if c then c.level = state.stats[low].level end
  if pane:IsShown() then RefreshSideTabs() end
  if pane:IsShown() and low == state.selected and c then
    ShowTitle(c)
    if state.view == "gear" then RefreshGear(c) end
  end
end

handlers.X = function(p)
  local low = tonumber(p[2])
  if not low or low == 0 then return end
  local function n(i) return tonumber(p[i]) or 0 end
  state.ext[low] = {
    mmin = n(3), mmax = n(4), mspeed = n(5), ap = n(6), mhit = n(7), mcrit = n(8), exp = n(9),
    rmin = n(10), rmax = n(11), rspeed = n(12), rap = n(13), rhit = n(14), rcrit = n(15),
    sdmg = n(16), heal = n(17), shit = n(18), scrit = n(19), haste = n(20), regen = n(21), regenCasting = n(22),
    armor = n(23), def = n(24), dodge = n(25), parry = n(26), block = n(27), resil = n(28),
  }
  local c = FindChar(low)
  if pane:IsShown() and low == state.selected and c and state.view == "gear" then
    for _, dd in ipairs({ ui.statsLeftDD, ui.statsRightDD }) do
      StatLines(dd.box, StatRows(StatChoice(low, dd.side), state.stats[low], state.ext[low]))
    end
  end
end

handlers.GB = function() buffers.G = {} end
handlers.G = function(p)
  for _, rec in ipairs(Split(p[2], ";")) do
    local f = Split(rec, ":")
    if #f >= 9 then
      buffers.G[tonumber(f[1])] = {
        entry = tonumber(f[2]), ench = tonumber(f[3]), g1 = tonumber(f[4]), g2 = tonumber(f[5]), g3 = tonumber(f[6]),
        suffix = tonumber(f[7]), fake = tonumber(f[8]), dur = tonumber(f[9]),
      }
    end
  end
end
handlers.GE = function(p)
  local low = tonumber(p[2])
  state.gear[low] = buffers.G
  if low == state.selected then ui.model.dirty = true end
  if low == wardrobe.low then
    for slot, entry in pairs(wardrobe.pending) do
      local rec = buffers.G[slot]
      if rec and (rec.fake or 0) == entry then wardrobe.pending[slot] = nil end
    end
    wui.model.dirty = true
    for _, cell in ipairs(wui.cells) do cell.model.entry = nil end
    if wf:IsShown() and not wardrobe.lists[low .. ":" .. wardrobe.slot] then Send("TLIST " .. low .. " " .. wardrobe.slot) end
  end
  ui.Refresh(); wui.Refresh()
end

local scanTip = CreateFrame("GameTooltip", "PartyManagerScanTip", UIParent, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

handlers.TB = function() buffers.T = {} end
handlers.T = function(p)
  for _, e in ipairs(Split(p[2], ";")) do
    local n = tonumber(e)
    if n then buffers.T[#buffers.T + 1] = n end
  end
end
handlers.TE = function(p)
  local low, slot = tonumber(p[2]), tonumber(p[3])
  wardrobe.lists[low .. ":" .. slot] = {
    entries = buffers.T, near = p[5] == "1", allowHide = p[6] == "1",
    collected = tonumber(p[7]) or 0, total = tonumber(p[8]) or 0,
  }
  for i = 1, math.min(#buffers.T, 30) do
    local e = math.abs(buffers.T[i])
    if not GetItemInfo(e) then scanTip:SetHyperlink("item:" .. e) end
  end
  wui.Refresh()
end

handlers.OB = function() buffers.O = {} end
handlers.O = function(p)
  local k = tonumber(p[3])
  local looks = {}
  for _, pair in ipairs(Split(p[4] or "", ",")) do
    local s, v = string.match(pair, "(%d+)=(%d+)")
    if s then looks[tonumber(s)] = tonumber(v) end
  end
  if k then buffers.O[k] = looks end
end
handlers.OE = function(p)
  state.outfits[tonumber(p[2])] = buffers.O
  wui.Refresh()
end

handlers.M = function(p) Print(table.concat(p, "|", 2)) end
handlers.P = function(p)
  local spent = tonumber(p[2]) or 0
  if spent > 0 then Print("Party repaired for " .. Money(spent) .. ".") else Print("Your party's gear is already in good shape.") end
  if p[3] == "1" then Print("You ran out of gold before everything was repaired.") end
end

-- ================================================================ the Party tab on the Character window

local partyTab

local function ShowPartyPane()
  for i = 1, (CharacterFrame.numTabs or 5) do
    local t = _G["CharacterFrameTab" .. i]
    if t then PanelTemplates_DeselectTab(t) end
  end
  PanelTemplates_SelectTab(partyTab)
  CharacterFrame_ShowSubFrame("PartyManagerPane")
end

local function PlacePartyTab()
  if not partyTab then return end
  local last
  for i = 1, 5 do
    local t = _G["CharacterFrameTab" .. i]
    if t and t:IsShown() then last = t end
  end
  partyTab:ClearAllPoints()
  if last then partyTab:SetPoint("LEFT", last, "RIGHT", -16, 0) else partyTab:SetPoint("TOPLEFT", CharacterFrame, "BOTTOMLEFT", 300, 78) end
  if not pane:IsShown() then PanelTemplates_DeselectTab(partyTab) end
end

pane:SetScript("OnShow", function()
  ui.model.dirty = true
  Send("WATCH 1")
  Send("HELLO")
  if state.selected then Send("GEAR " .. state.selected) end
  ui.Refresh()
end)
pane:SetScript("OnHide", function()
  if partyTab then PanelTemplates_DeselectTab(partyTab) end
  CloseDropDownMenus()
  -- give the title back to you
  SetPortraitTexture(CharacterFramePortrait, "player")
  CharacterNameText:SetText(UnitPVPName("player"))
  if not wf:IsShown() then Send("WATCH 0") end
end)

local function IsTransmogrifier()
  local guid = UnitGUID("npc")
  return guid and tonumber(string.sub(guid, -12, -7), 16) == TRANSMOGRIFIER
end

local repairButton
local function ShowRepairButton()
  if not repairButton then
    repairButton = PanelButton(MerchantFrame, "Repair party", 110, function()
      local guid = UnitGUID("npc")
      if guid then Send("REPAIR " .. string.sub(guid, 3)) end
    end)
    repairButton:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", -32, -80)
  end
  if CanMerchantRepair() and #Companions() > 0 then repairButton:Show() else repairButton:Hide() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("GOSSIP_SHOW")
events:RegisterEvent("MERCHANT_SHOW")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("UNIT_MODEL_CHANGED")
events:RegisterEvent("UNIT_PORTRAIT_UPDATE")
events:SetScript("OnEvent", function(self, event, a1, a2, a3, a4)
  if event == "CHAT_MSG_ADDON" then
    if a1 ~= PREFIX or a3 ~= "WHISPER" or a4 ~= UnitName("player") then return end
    local parts = Split(a2, "|")
    local h = handlers[parts[1]]
    if h then h(parts) end
  elseif event == "PLAYER_LOGIN" then
    tinsert(CHARACTERFRAME_SUBFRAMES, "PartyManagerPane")
    PlacePane()
    partyTab = CreateFrame("Button", "PartyManagerCharacterTab", CharacterFrame, "CharacterFrameTabButtonTemplate")
    partyTab:SetText("Party")
    PanelTemplates_TabResize(partyTab, 0)
    partyTab:SetScript("OnClick", function()
      ShowPartyPane()
      PlaySound("igCharacterInfoTab")
    end)
    partyTab:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Party")
      GameTooltip:AddLine("Your companions: gear, tactics and appearance.", 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end)
    partyTab:SetScript("OnLeave", function() GameTooltip:Hide() end)
    CharacterFrame:HookScript("OnShow", PlacePartyTab)
    PlacePartyTab()
    Send("HELLO")
  elseif event == "GOSSIP_SHOW" then
    if IsTransmogrifier() then
      local first = (state.selected and FindChar(state.selected)) or Companions()[1]
      if first then PartyManager_OpenWardrobe(first.low) end
    end
  elseif event == "MERCHANT_SHOW" then
    ShowRepairButton()
  elseif event == "PARTY_MEMBERS_CHANGED" then
    if pane:IsShown() or wf:IsShown() then ui.model.dirty = true; wui.model.dirty = true; Send("HELLO") end
  elseif event == "UNIT_MODEL_CHANGED" or event == "UNIT_PORTRAIT_UPDATE" then
    if a1 and ui.model.unit and UnitIsUnit(a1, ui.model.unit) then ui.model.dirty = true; ui.Refresh() end
    if a1 and wui.model.unit and UnitIsUnit(a1, wui.model.unit) then wui.model.dirty = true; wui.Refresh() end
  end
end)

local countdown = 0
events:SetScript("OnUpdate", function(self, elapsed)
  countdown = countdown + elapsed
  if countdown < 1 then return end
  countdown = 0
  if not pane:IsShown() then return end
  local c = state.selected and FindChar(state.selected)
  local s = c and state.stats[c.low]
  if s and not s.alive then ShowTitle(c) end
end)

SLASH_PARTYMANAGER1 = "/pm"
SLASH_PARTYMANAGER2 = "/companions"
SlashCmdList.PARTYMANAGER = function(msg)
  msg = string.lower(msg or "")
  if msg == "look" or msg == "wardrobe" then
    local c = (state.selected and FindChar(state.selected)) or Companions()[1]
    if c then PartyManager_OpenWardrobe(c.low) else Print("Summon a companion first.") end
  else
    if not CharacterFrame:IsShown() then ToggleCharacter("PaperDollFrame") end
    ShowPartyPane()
  end
end
