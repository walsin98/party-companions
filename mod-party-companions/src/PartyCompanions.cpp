/*
 * mod-party-companions: summon your own characters as companions, keep them at
 * your level, and manage their gear and transmog from one window (the
 * PartyCompanions client addon). Built on mod-playerbots altbots and the
 * account-wide mod-transmog collection.
 *
 * Client <-> server traffic is addon whispers to self with prefix "PMGR".
 * Everything that touches another player runs on the world thread (session
 * handlers and WorldScript::OnUpdate run between map updates); hooks that fire
 * inside map threads only read the guarded companion registry or queue work.
 */

#include "AiObjectContext.h"
#include "Bag.h"
#include "CellImpl.h"
#include "CharacterCache.h"
#include "Chat.h"
#include "Config.h"
#include "Creature.h"
#include "DatabaseEnv.h"
#include "Formulas.h"
#include "GridNotifiers.h"
#include "GridNotifiersImpl.h"
#include "Group.h"
#include "Item.h"
#include "Log.h"
#include "ObjectAccessor.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "PlayerbotAI.h"
#include "PlayerbotMgr.h"
#include "QuestDef.h"
#include "ScriptMgr.h"
#include "Transmogrification.h"
#include "World.h"
#include "WorldPacket.h"
#include "WorldSession.h"

#include <algorithm>
#include <array>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace
{
    constexpr char const* PREFIX = "PMGR";
    constexpr uint32 SOUL_SHARD = 6265;
    constexpr uint32 MAX_PAYLOAD = 240;

    struct Settings
    {
        bool enable = true;
        uint32 maxCompanions = 4;
        bool levelLock = true;
        bool fullSoloXp = true;
        bool forwardLoot = true;
        bool forwardMoney = true;
        float transmogRange = 15.0f;
        uint32 reviveDelay = 30;   // seconds a fallen companion stays down
    } cfg;

    struct CompanionState
    {
        ObjectGuid master;
        uint32 seenTicks = 0;      // reconcile ticks since first seen
        bool arrived = false;      // post-login teleport done
        bool bagsFullNoticed = false;
        uint32 apartTicks = 0;     // seconds spent separated from the master
        int32 appliedStance = -1;  // stance whose strategies are applied
        ObjectGuid engaged;        // target we pointed this companion at
        bool tamed = false;        // quests dropped, chatter strategies removed
        bool sitting = false;      // sat down while the master idles
        uint32 deadTicks = 0;      // seconds since this companion fell
    };

    // Party stance, stored per master as a player setting.
    enum Stance : uint32
    {
        STANCE_ASSIST = 0,         // default: defend, and open on whatever you target
        STANCE_DEFEND = 1,         // only fight what attacks the party
        STANCE_AGGRESSIVE = 2,     // also clear hostiles that come near you
        STANCE_PASSIVE = 3,        // never fight
    };
    constexpr char const* SETTING_SOURCE = "mod-party-manager";

    // Player settings (source SETTING_SOURCE): 0 stance; LOOK_BASE+slot the look
    // remembered for that slot; OUTFIT_BASE + k*OUTFIT_STRIDE + slot an outfit,
    // with OUTFIT_STRIDE-1 flagging that outfit k exists.
    constexpr uint32 LOOK_BASE = 10;
    constexpr uint32 OUTFIT_BASE = 100;
    constexpr uint32 OUTFIT_STRIDE = 20;
    constexpr uint32 MAX_OUTFITS = 5;

    struct MasterState
    {
        uint32 calmTicks = 0;      // seconds the whole party has been out of combat
        uint32 stillTicks = 0;     // seconds the master has not moved
        float lastX = 0.0f, lastY = 0.0f;
        bool hasTank = false;      // a companion tank leads the pulls
    };

    // Registry: map threads read it from XP and money hooks, so guard it.
    std::mutex g_lock;
    std::unordered_map<ObjectGuid, ObjectGuid> g_companionMaster;         // companion -> master
    std::unordered_map<ObjectGuid, std::unordered_set<ObjectGuid>> g_masterCompanions;
    std::vector<std::pair<ObjectGuid, uint32>> g_moneyQueue;              // master, copper

    // World-thread only.
    std::unordered_map<ObjectGuid, CompanionState> g_state;
    std::unordered_set<ObjectGuid> g_watchers;                           // masters with the window open
    std::unordered_map<ObjectGuid, MasterState> g_masters;
    // Item seen in each slot when its remembered look was last settled.
    std::unordered_map<ObjectGuid, std::array<ObjectGuid, EQUIPMENT_SLOT_END>> g_lookSeen;
    uint32 g_tickTimer = 0;
    uint32 g_tick = 0;

    void Send(Player* master, std::string const& payload)
    {
        if (!master || !master->GetSession())
            return;
        WorldPacket data;
        ChatHandler::BuildChatPacket(data, CHAT_MSG_WHISPER, LANG_ADDON, master, master,
                                     std::string(PREFIX) + "\t" + payload);
        master->SendDirectMessage(&data);
    }

    void Notify(Player* master, std::string const& text)
    {
        Send(master, "M|" + text.substr(0, MAX_PAYLOAD - 2));
    }

    // Sends "<head>|rec;rec;..." in as many messages as needed, then "<head>E|<tail>".
    void SendList(Player* master, std::string const& head, std::vector<std::string> const& records, std::string const& tail)
    {
        Send(master, head + "B|" + tail);
        std::string line;
        for (std::string const& rec : records)
        {
            if (!line.empty() && line.size() + rec.size() + head.size() + 3 > MAX_PAYLOAD)
            {
                Send(master, head + "|" + line);
                line.clear();
            }
            if (!line.empty())
                line += ';';
            line += rec;
        }
        if (!line.empty())
            Send(master, head + "|" + line);
        Send(master, head + "E|" + tail);
    }

    bool IsCompanion(ObjectGuid guid)
    {
        std::lock_guard<std::mutex> lock(g_lock);
        return g_companionMaster.count(guid) != 0;
    }

    std::vector<Player*> CompanionsOf(Player* master)
    {
        std::vector<Player*> out;
        std::vector<ObjectGuid> guids;
        {
            std::lock_guard<std::mutex> lock(g_lock);
            auto it = g_masterCompanions.find(master->GetGUID());
            if (it != g_masterCompanions.end())
                guids.assign(it->second.begin(), it->second.end());
        }
        for (ObjectGuid const& g : guids)
            if (Player* p = ObjectAccessor::FindPlayer(g))
                if (p->IsInWorld())
                    out.push_back(p);
        std::sort(out.begin(), out.end(), [](Player* a, Player* b) { return a->GetGUID() < b->GetGUID(); });
        return out;
    }

    // A companion is an altbot of the master's own account, controlled by that master.
    Player* GetCompanion(Player* master, uint32 guidLow)
    {
        if (!guidLow)
            return nullptr;
        PlayerbotMgr* mgr = sPlayerbotsMgr.GetPlayerbotMgr(master);
        if (!mgr)
            return nullptr;
        Player* bot = mgr->GetPlayerBot(ObjectGuid::Create<HighGuid::Player>(guidLow));
        if (!bot || !bot->IsInWorld() || !bot->GetSession())
            return nullptr;
        if (bot->GetSession()->GetAccountId() != master->GetSession()->GetAccountId())
            return nullptr;
        return bot;
    }

    // Target for wardrobe commands: 0 means the master.
    Player* GetWardrobeTarget(Player* master, uint32 guidLow)
    {
        return guidLow ? GetCompanion(master, guidLow) : master;
    }

    std::string InventoryError(InventoryResult r)
    {
        switch (r)
        {
            case EQUIP_ERR_CANT_EQUIP_LEVEL_I: return "Too low level for that item.";
            case EQUIP_ERR_CANT_EQUIP_SKILL:
            case EQUIP_ERR_NO_REQUIRED_PROFICIENCY: return "They lack the proficiency for that item.";
            case EQUIP_ERR_ITEM_DOESNT_GO_TO_SLOT: return "That item does not go in that slot.";
            case EQUIP_ERR_YOU_CAN_NEVER_USE_THAT_ITEM:
            case EQUIP_ERR_YOU_CAN_NEVER_USE_THAT_ITEM2: return "Their class or race can never use that item.";
            case EQUIP_ERR_INVENTORY_FULL:
            case EQUIP_ERR_BAG_FULL: return "Not enough bag space.";
            case EQUIP_ERR_ITEM_UNIQUE_EQUIPABLE:
            case EQUIP_ERR_ITEM_MAX_COUNT_EQUIPPED_SOCKETED: return "They already wear one of those (unique).";
            case EQUIP_ERR_CANT_EQUIP_WITH_TWOHANDED: return "Remove the two-handed weapon first.";
            case EQUIP_ERR_CANT_DUAL_WIELD: return "They cannot dual wield.";
            case EQUIP_ERR_NOT_IN_COMBAT: return "Not while in combat.";
            case EQUIP_ERR_CANT_DO_RIGHT_NOW: return "They can't do that right now.";
            default: return "That item can't be moved right now (code " + std::to_string(uint32(r)) + ").";
        }
    }

    // Moves an item between two players' inventories, mirroring the trade path.
    bool TransferItem(Player* from, Item* item, Player* to, CharacterDatabaseTransaction trans)
    {
        ItemPosCountVec dest;
        if (to->CanStoreItem(NULL_BAG, NULL_SLOT, dest, item, false) != EQUIP_ERR_OK)
            return false;
        item->ClearSoulboundTradeable(from);
        from->MoveItemFromInventory(item->GetBagSlot(), item->GetSlot(), true);
        to->MoveItemToInventory(dest, item, true, true);
        from->SaveInventoryAndGoldToDB(trans);
        to->SaveInventoryAndGoldToDB(trans);
        return true;
    }

    // Quest drops are rolled per character, so each companion on the quest gets
    // its own copy. Those stay with the companion instead of piling up on you.
    bool KeepOnCompanion(Player* comp, Item* item)
    {
        ItemTemplate const* proto = item->GetTemplate();
        if (!proto || item->IsInTrade() || item->IsNotEmptyBag())
            return true;
        if (comp->HasQuestForItem(proto->ItemId))
            return true;
        return proto->Class == ITEM_CLASS_QUEST || proto->Class == ITEM_CLASS_PROJECTILE ||
               proto->Class == ITEM_CLASS_REAGENT || proto->Class == ITEM_CLASS_QUIVER ||
               proto->ItemId == SOUL_SHARD || proto->StartQuest != 0;
    }

    // Shared stash: whatever a companion picks up goes to the master's bags.
    uint32 SweepCompanionBags(Player* comp, Player* master)
    {
        std::vector<Item*> items;
        for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
            if (Item* it = comp->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
                items.push_back(it);
        for (uint8 bag = INVENTORY_SLOT_BAG_START; bag < INVENTORY_SLOT_BAG_END; ++bag)
            if (Bag* b = comp->GetBagByPos(bag))
                for (uint32 slot = 0; slot < b->GetBagSize(); ++slot)
                    if (Item* it = b->GetItemByPos(uint8(slot)))
                        items.push_back(it);

        uint32 moved = 0, stuck = 0;
        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        for (Item* it : items)
        {
            if (KeepOnCompanion(comp, it))
                continue;
            if (TransferItem(comp, it, master, trans))
                ++moved;
            else
                ++stuck;
        }
        CharacterDatabase.CommitTransaction(trans);

        CompanionState& st = g_state[comp->GetGUID()];
        if (stuck && !st.bagsFullNoticed)
        {
            Notify(master, "Your bags are full - " + comp->GetName() + " is holding " + std::to_string(stuck) + " item(s) for you.");
            st.bagsFullNoticed = true;
        }
        else if (!stuck)
            st.bagsFullNoticed = false;
        return moved;
    }

    bool BringToMaster(Player* comp, Player* master, bool force)
    {
        if (comp->IsInCombat() || master->IsInFlight() || master->InBattleground() || master->InArena() ||
            comp->IsBeingTeleported() || master->IsBeingTeleported())
            return false;
        if (!force && comp->GetMapId() == master->GetMapId() && comp->GetDistance(master) < 60.0f)
            return true;
        return comp->TeleportTo(master->GetMapId(), master->GetPositionX(), master->GetPositionY(),
                                master->GetPositionZ(), master->GetOrientation());
    }

    void SyncLevel(Player* comp, Player* master)
    {
        if (!cfg.levelLock || comp->GetLevel() >= master->GetLevel())
            return;
        comp->GiveLevel(master->GetLevel());
        comp->InitTalentForLevel();
        comp->SetUInt32Value(PLAYER_XP, 0);
    }

    char const* RoleOf(Player* p)
    {
        if (PlayerbotAI::IsTank(p, true))
            return "T";
        if (PlayerbotAI::IsHeal(p, true))
            return "H";
        return "D";
    }

    uint32 AverageItemLevel(Player* p)
    {
        uint32 total = 0, count = 0;
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            if (slot == EQUIPMENT_SLOT_BODY || slot == EQUIPMENT_SLOT_TABARD)
                continue;
            if (Item* it = p->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
            {
                total += it->GetTemplate()->ItemLevel;
                ++count;
            }
        }
        return count ? total / count : 0;
    }

    uint32 ReviveIn(Player* comp)
    {
        if (comp->IsAlive())
            return 0;
        auto it = g_state.find(comp->GetGUID());
        uint32 dead = it != g_state.end() ? it->second.deadTicks : 0;
        return dead < cfg.reviveDelay ? cfg.reviveDelay - dead : 1;
    }

    void SendStats(Player* master, Player* comp)
    {
        std::ostringstream s;
        s << "S|" << (comp == master ? 0 : comp->GetGUID().GetCounter()) << '|' << comp->GetHealth() << '|' << comp->GetMaxHealth() << '|'
          << uint32(comp->getPowerType()) << '|' << comp->GetPower(comp->getPowerType()) << '|'
          << comp->GetMaxPower(comp->getPowerType()) << '|' << uint32(comp->GetLevel()) << '|'
          << uint32(comp->GetStat(STAT_STRENGTH)) << '|' << uint32(comp->GetStat(STAT_AGILITY)) << '|' << uint32(comp->GetStat(STAT_STAMINA)) << '|'
          << uint32(comp->GetStat(STAT_INTELLECT)) << '|' << uint32(comp->GetStat(STAT_SPIRIT)) << '|' << comp->GetArmor() << '|'
          << uint32(comp->GetTotalAttackPowerValue(BASE_ATTACK)) << '|' << uint32(comp->GetTotalAttackPowerValue(RANGED_ATTACK)) << '|'
          << comp->GetBaseSpellPowerBonus() << '|' << uint32(comp->GetFloatValue(PLAYER_CRIT_PERCENTAGE) * 100) << '|'
          << uint32(comp->GetFloatValue(PLAYER_SPELL_CRIT_PERCENTAGE1 + uint32(SPELL_SCHOOL_HOLY)) * 100) << '|'
          << AverageItemLevel(comp) << '|' << (comp->IsAlive() ? 1 : 0) << '|' << RoleOf(comp) << '|'
          << (comp->GetMapId() == master->GetMapId() && comp->GetDistance(master) < 100.0f ? 1 : 0) << '|'
          << comp->GetFreeTalentPoints() << '|' << ReviveIn(comp);
        Send(master, s.str());

        // Melee, ranged, spell and defense numbers for the sheet's stat dropdowns.
        auto rating = [comp](CombatRating cr) { return comp->GetUInt32Value(PLAYER_FIELD_COMBAT_RATING_1 + uint16(cr)); };
        auto pct = [comp](uint16 field) { return uint32(comp->GetFloatValue(field) * 100); };
        uint32 spellDamage = 0;
        for (uint16 school = SPELL_SCHOOL_HOLY; school < MAX_SPELL_SCHOOL; ++school)
            spellDamage = std::max<uint32>(spellDamage, comp->GetUInt32Value(PLAYER_FIELD_MOD_DAMAGE_DONE_POS + school));
        std::ostringstream x;
        x << std::fixed << std::setprecision(0)
          << "X|" << (comp == master ? 0 : comp->GetGUID().GetCounter()) << '|'
          << comp->GetFloatValue(UNIT_FIELD_MINDAMAGE) << '|' << comp->GetFloatValue(UNIT_FIELD_MAXDAMAGE) << '|'
          << comp->GetAttackTime(BASE_ATTACK) / 10 << '|' << uint32(comp->GetTotalAttackPowerValue(BASE_ATTACK)) << '|'
          << rating(CR_HIT_MELEE) << '|' << pct(PLAYER_CRIT_PERCENTAGE) << '|' << comp->GetUInt32Value(PLAYER_EXPERTISE) << '|'
          << comp->GetFloatValue(UNIT_FIELD_MINRANGEDDAMAGE) << '|' << comp->GetFloatValue(UNIT_FIELD_MAXRANGEDDAMAGE) << '|'
          << comp->GetAttackTime(RANGED_ATTACK) / 10 << '|' << uint32(comp->GetTotalAttackPowerValue(RANGED_ATTACK)) << '|'
          << rating(CR_HIT_RANGED) << '|' << pct(PLAYER_RANGED_CRIT_PERCENTAGE) << '|'
          << spellDamage << '|' << comp->GetUInt32Value(PLAYER_FIELD_MOD_HEALING_DONE_POS) << '|'
          << rating(CR_HIT_SPELL) << '|' << pct(PLAYER_SPELL_CRIT_PERCENTAGE1 + uint32(SPELL_SCHOOL_HOLY)) << '|' << rating(CR_HASTE_SPELL) << '|'
          << uint32(comp->GetFloatValue(UNIT_FIELD_POWER_REGEN_FLAT_MODIFIER) * 5) << '|'
          << uint32(comp->GetFloatValue(UNIT_FIELD_POWER_REGEN_INTERRUPTED_FLAT_MODIFIER) * 5) << '|'
          << comp->GetArmor() << '|' << comp->GetDefenseSkillValue() << '|' << pct(PLAYER_DODGE_PERCENTAGE) << '|'
          << pct(PLAYER_PARRY_PERCENTAGE) << '|' << pct(PLAYER_BLOCK_PERCENTAGE) << '|' << rating(CR_CRIT_TAKEN_MELEE);
        Send(master, x.str());
    }

    uint32 GetStance(Player* master)
    {
        uint32 s = master->GetPlayerSetting(SETTING_SOURCE, 0).value;
        return s <= STANCE_PASSIVE ? s : STANCE_ASSIST;
    }

    void SendRoster(Player* master)
    {
        uint32 account = master->GetSession()->GetAccountId();
        std::vector<std::string> recs;
        QueryResult result = CharacterDatabase.Query(
            "SELECT guid, name, race, class, gender, level FROM characters WHERE account = {} AND guid <> {} AND deleteInfos_Account IS NULL ORDER BY level DESC, name",
            account, master->GetGUID().GetCounter());
        if (result)
        {
            do
            {
                Field* f = result->Fetch();
                uint32 low = f[0].Get<uint32>();
                ObjectGuid guid = ObjectGuid::Create<HighGuid::Player>(low);
                Player* online = ObjectAccessor::FindConnectedPlayer(guid);
                uint32 level = online ? online->GetLevel() : f[5].Get<uint8>();
                char state = 'O';                                   // offline
                if (online)
                    state = GetCompanion(master, low) ? 'S' : 'B';  // summoned / busy elsewhere
                else if (Player::TeamIdForRace(f[2].Get<uint8>()) != master->GetTeamId())
                    state = 'F';                                    // other faction
                std::ostringstream r;
                r << low << ':' << f[1].Get<std::string>() << ':' << uint32(f[2].Get<uint8>()) << ':'
                  << uint32(f[3].Get<uint8>()) << ':' << uint32(f[4].Get<uint8>()) << ':' << level << ':' << state;
                recs.push_back(r.str());
            } while (result->NextRow());
        }
        std::ostringstream tail;
        tail << cfg.maxCompanions << '|' << (cfg.levelLock ? 1 : 0) << '|' << GetStance(master);
        SendList(master, "R", recs, tail.str());
    }

    void SendGear(Player* master, Player* target)
    {
        std::vector<std::string> recs;
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            Item* it = target->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
            if (!it)
                continue;
            uint32 maxDur = it->GetUInt32Value(ITEM_FIELD_MAXDURABILITY);
            uint32 dur = maxDur ? it->GetUInt32Value(ITEM_FIELD_DURABILITY) * 100 / maxDur : 100;
            std::ostringstream r;
            r << uint32(slot) << ':' << it->GetEntry() << ':' << it->GetEnchantmentId(PERM_ENCHANTMENT_SLOT) << ':'
              << it->GetEnchantmentId(SOCK_ENCHANTMENT_SLOT) << ':' << it->GetEnchantmentId(SOCK_ENCHANTMENT_SLOT_2) << ':'
              << it->GetEnchantmentId(SOCK_ENCHANTMENT_SLOT_3) << ':' << it->GetItemRandomPropertyId() << ':'
              << sTransmogrification->GetFakeEntry(it->GetGUID()) << ':' << dur;
            recs.push_back(r.str());
        }
        uint32 low = target == master ? 0 : target->GetGUID().GetCounter();
        SendList(master, "G", recs, std::to_string(low));
        SendStats(master, target);
    }

    // ---- remembered looks (slot based, like retail outfits) ----------------

    uint32 Setting(Player* p, uint32 index)
    {
        return p->GetPlayerSetting(SETTING_SOURCE, index).value;
    }

    bool HasCollected(Player* p, uint32 entry)
    {
        auto acc = sTransmogrification->collectionCache.find(p->GetSession()->GetAccountId());
        return acc != sTransmogrification->collectionCache.end() && acc->second.count(entry);
    }

    // look: 0 original item, HIDDEN_ITEM_ID hidden, else an appearance entry.
    bool ApplyLook(Player* p, uint8 slot, uint32 look)
    {
        Item* item = p->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
        if (!item)
            return false;
        TransmogStrings res;
        if (look == 0)
        {
            if (!sTransmogrification->GetFakeEntry(item->GetGUID()))
                return true;
            res = sTransmogrification->Transmogrify(p, static_cast<Item*>(nullptr), slot, true, false);
        }
        else if (look == HIDDEN_ITEM_ID)
            res = sTransmogrification->Transmogrify(p, static_cast<Item*>(nullptr), slot, true, true);
        else
        {
            if (!HasCollected(p, look))
                return false;
            Item* source = Item::CreateItem(look, 1, nullptr);
            if (!source)
                return false;
            res = sTransmogrification->Transmogrify(p, source, slot, true, false);
            delete source;
        }
        return res == LANG_TRANSMOG_OK || res == LANG_TRANSMOG_UNTRANSMOG_OK;
    }

    void RememberLook(Player* p, uint8 slot, uint32 look)
    {
        p->UpdatePlayerSetting(SETTING_SOURCE, LOOK_BASE + slot, look);
        if (Item* item = p->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
            g_lookSeen[p->GetGUID()][slot] = item->GetGUID();
    }

    // New gear in a slot takes on the look remembered for that slot. A look
    // changed some other way (the NPC menu) becomes the remembered one.
    void SettleLooks(Player* p)
    {
        auto& seen = g_lookSeen[p->GetGUID()];
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            uint32 look = Setting(p, LOOK_BASE + slot);
            Item* item = p->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
            if (!look || !item || seen[slot] == item->GetGUID())
            {
                uint32 fake = item ? sTransmogrification->GetFakeEntry(item->GetGUID()) : 0;
                if (look && fake && fake != look)
                    p->UpdatePlayerSetting(SETTING_SOURCE, LOOK_BASE + slot, fake);
                continue;
            }
            if (sTransmogrification->GetFakeEntry(item->GetGUID()) != look)
                ApplyLook(p, slot, look);
            seen[slot] = item->GetGUID();
        }
    }

    void SendOutfits(Player* master, Player* target)
    {
        uint32 low = target == master ? 0 : target->GetGUID().GetCounter();
        Send(master, "OB|" + std::to_string(low));
        for (uint32 k = 0; k < MAX_OUTFITS; ++k)
        {
            uint32 base = OUTFIT_BASE + k * OUTFIT_STRIDE;
            if (!Setting(target, base + OUTFIT_STRIDE - 1))
                continue;
            std::ostringstream o;
            o << "O|" << low << '|' << k << '|';
            bool first = true;
            for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
                if (uint32 v = Setting(target, base + slot))
                {
                    o << (first ? "" : ",") << uint32(slot) << '=' << v;
                    first = false;
                }
            Send(master, o.str());
        }
        Send(master, "OE|" + std::to_string(low));
    }

    void CmdOutfitSave(Player* master, Player* target, uint32 k)
    {
        if (k >= MAX_OUTFITS)
            return;
        uint32 base = OUTFIT_BASE + k * OUTFIT_STRIDE;
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            Item* item = target->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
            uint32 v = item ? sTransmogrification->GetFakeEntry(item->GetGUID()) : Setting(target, LOOK_BASE + slot);
            target->UpdatePlayerSetting(SETTING_SOURCE, base + slot, v);
        }
        target->UpdatePlayerSetting(SETTING_SOURCE, base + OUTFIT_STRIDE - 1, 1);
        Notify(master, "Outfit " + std::to_string(k + 1) + " saved for " + target->GetName() + ".");
        SendOutfits(master, target);
    }

    // Wearing a saved outfit is free and works anywhere: it only holds looks
    // that were already applied at a Transmogrifier.
    void CmdOutfitUse(Player* master, Player* target, uint32 k)
    {
        if (k >= MAX_OUTFITS)
            return;
        uint32 base = OUTFIT_BASE + k * OUTFIT_STRIDE;
        if (!Setting(target, base + OUTFIT_STRIDE - 1))
            return Notify(master, "That outfit is empty.");
        if (target->IsInCombat())
            return Notify(master, "Not while in combat.");
        for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
        {
            uint32 v = Setting(target, base + slot);
            ApplyLook(target, slot, v);
            RememberLook(target, slot, v);
        }
        SendGear(master, target);
    }

    void CmdOutfitDelete(Player* master, Player* target, uint32 k)
    {
        if (k >= MAX_OUTFITS)
            return;
        target->UpdatePlayerSetting(SETTING_SOURCE, OUTFIT_BASE + k * OUTFIT_STRIDE + OUTFIT_STRIDE - 1, 0);
        SendOutfits(master, target);
    }

    // Companions travel with you: no quest log of their own and no chatter.
    void Tame(Player* comp)
    {
        if (PlayerbotAI* ai = sPlayerbotsMgr.GetPlayerbotAI(comp))
        {
            ai->ChangeStrategy("-quest,-chat,-emote,-duel,-rpg,-new rpg", BOT_STATE_NON_COMBAT);
            if (Player* master = ai->GetMaster())
                ai->HandleCommand(CHAT_MSG_WHISPER, "formation chaos", master);
        }
        for (uint8 slot = 0; slot < MAX_QUEST_LOG_SIZE; ++slot)
        {
            uint32 questId = comp->GetQuestSlotQuestId(slot);
            if (!questId || !comp->TakeQuestSourceItem(questId, true))
                continue;
            if (Quest const* quest = sObjectMgr->GetQuestTemplate(questId))
                if (quest->HasSpecialFlag(QUEST_SPECIAL_FLAGS_TIMED))
                    comp->RemoveTimedQuest(questId);
            comp->AbandonQuest(questId);
            comp->RemoveActiveQuest(questId);
            comp->RemoveTimedAchievement(ACHIEVEMENT_TIMED_TYPE_QUEST, questId);
            comp->SetQuestSlot(slot, 0);
        }
    }

    // ---- commands --------------------------------------------------------

    void CmdSummon(Player* master, uint32 low)
    {
        ObjectGuid guid = ObjectGuid::Create<HighGuid::Player>(low);
        uint32 account = master->GetSession()->GetAccountId();
        if (!low || guid == master->GetGUID() || sCharacterCache->GetCharacterAccountIdByGuid(guid) != account)
            return Notify(master, "That character is not on your account.");
        if (CharacterCacheEntry const* entry = sCharacterCache->GetCharacterCacheByGuid(guid))
            if (Player::TeamIdForRace(entry->Race) != master->GetTeamId())
                return Notify(master, entry->Name + " belongs to the other faction and can't join you.");
        if (master->InBattleground() || master->InArena())
            return Notify(master, "Companions can't join you in a battleground.");
        if (CompanionsOf(master).size() >= cfg.maxCompanions)
            return Notify(master, "Your party is full (" + std::to_string(cfg.maxCompanions) + " companions).");
        if (Group* group = master->GetGroup())
            if (!group->isRaidGroup() && group->GetMembersCount() >= MAXGROUPSIZE)
                return Notify(master, "Your group is full.");
        if (Player* online = ObjectAccessor::FindConnectedPlayer(guid))
        {
            if (GetCompanion(master, low))
                return Notify(master, online->GetName() + " is already with you.");
            return Notify(master, online->GetName() + " is busy elsewhere.");
        }
        PlayerbotMgr* mgr = sPlayerbotsMgr.GetPlayerbotMgr(master);
        if (!mgr)
            return Notify(master, "Companions are unavailable right now.");
        mgr->AddPlayerBot(guid, account);
        std::string name;
        sCharacterCache->GetCharacterNameByGuid(guid, name);
        Notify(master, name + " is on the way.");
    }

    void CmdDismiss(Player* master, uint32 low)
    {
        PlayerbotMgr* mgr = sPlayerbotsMgr.GetPlayerbotMgr(master);
        if (!mgr)
            return;
        std::vector<Player*> targets;
        if (low)
        {
            if (Player* c = GetCompanion(master, low))
                targets.push_back(c);
        }
        else
            targets = CompanionsOf(master);
        for (Player* c : targets)
        {
            if (cfg.forwardLoot)
                SweepCompanionBags(c, master);
            mgr->LogoutPlayerBot(c->GetGUID());
        }
    }

    void CmdOrder(Player* master, uint32 low, std::string const& order)
    {
        static std::unordered_map<std::string, std::string> const orders = {
            {"follow", "follow"}, {"stay", "stay"}, {"attack", "attack"}, {"tank", "tank attack"},
            {"pull", "pull"}, {"flee", "flee"}, {"maxdps", "max dps"}, {"rebuff", "rebuff"}};
        std::vector<Player*> targets;
        if (low)
        {
            if (Player* c = GetCompanion(master, low))
                targets.push_back(c);
        }
        else
            targets = CompanionsOf(master);

        if (order == "come")
        {
            for (Player* c : targets)
                if (!BringToMaster(c, master, true))
                    Notify(master, c->GetName() + " can't come right now.");
            return;
        }
        auto it = orders.find(order);
        if (it == orders.end())
            return;
        for (Player* c : targets)
            if (PlayerbotAI* ai = sPlayerbotsMgr.GetPlayerbotAI(c))
                ai->HandleCommand(CHAT_MSG_WHISPER, it->second, master);
    }

    void CmdEquip(Player* master, uint32 low, uint8 bag, uint8 slot, uint8 wanted)
    {
        Player* comp = GetCompanion(master, low);
        if (!comp)
            return Notify(master, "That companion is not with you.");
        if (master->IsInCombat() || comp->IsInCombat())
            return Notify(master, "Not while in combat.");
        Item* item = master->GetItemByPos(bag, slot);
        if (!item || item->IsInTrade() || item->IsNotEmptyBag())
            return Notify(master, "That item is no longer in your bags.");
        ItemTemplate const* proto = item->GetTemplate();
        if (proto->InventoryType == INVTYPE_NON_EQUIP || proto->InventoryType == INVTYPE_BAG ||
            proto->InventoryType == INVTYPE_QUIVER || proto->InventoryType == INVTYPE_AMMO)
            return Notify(master, "That is not something they can wear.");

        InventoryResult r = comp->CanUseItem(proto);
        if (r != EQUIP_ERR_OK)
            return Notify(master, InventoryError(r));
        uint8 eslot = comp->FindEquipSlot(proto, wanted < EQUIPMENT_SLOT_END ? wanted : NULL_SLOT, true);
        if (eslot == NULL_SLOT)
            return Notify(master, InventoryError(EQUIP_ERR_ITEM_DOESNT_GO_TO_SLOT));

        // Two-handers need the off hand cleared first; it goes back to your bags.
        if (eslot == EQUIPMENT_SLOT_MAINHAND && proto->InventoryType == INVTYPE_2HWEAPON && !comp->CanTitanGrip())
            if (Item* off = comp->GetItemByPos(INVENTORY_SLOT_BAG_0, EQUIPMENT_SLOT_OFFHAND))
            {
                CharacterDatabaseTransaction t = CharacterDatabase.BeginTransaction();
                bool ok = TransferItem(comp, off, master, t);
                CharacterDatabase.CommitTransaction(t);
                if (!ok)
                    return Notify(master, "Make room in your bags for their off-hand first.");
            }

        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        if (!TransferItem(master, item, comp, trans))
        {
            CharacterDatabase.CommitTransaction(trans);
            return Notify(master, comp->GetName() + " has no room to take it.");
        }
        uint16 dest;
        r = comp->CanEquipItem(eslot, dest, item, true);
        if (r != EQUIP_ERR_OK)
        {
            TransferItem(comp, item, master, trans);
            CharacterDatabase.CommitTransaction(trans);
            return Notify(master, InventoryError(r));
        }
        comp->SwapItem(item->GetPos(), dest);
        comp->SaveInventoryAndGoldToDB(trans);
        CharacterDatabase.CommitTransaction(trans);

        if (comp->GetItemByPos(INVENTORY_SLOT_BAG_0, eslot) != item)
            Notify(master, comp->GetName() + " could not put it on.");
        SweepCompanionBags(comp, master);   // the replaced piece comes back to you
        SendGear(master, comp);
    }

    void CmdUnequip(Player* master, uint32 low, uint8 eslot)
    {
        Player* comp = GetCompanion(master, low);
        if (!comp || eslot >= EQUIPMENT_SLOT_END)
            return;
        if (comp->IsInCombat())
            return Notify(master, "Not while in combat.");
        Item* item = comp->GetItemByPos(INVENTORY_SLOT_BAG_0, eslot);
        if (!item)
            return;
        InventoryResult r = comp->CanUnequipItem(item->GetPos(), false);
        if (r != EQUIP_ERR_OK)
            return Notify(master, InventoryError(r));
        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        bool ok = TransferItem(comp, item, master, trans);
        CharacterDatabase.CommitTransaction(trans);
        if (!ok)
            Notify(master, InventoryError(EQUIP_ERR_INVENTORY_FULL));
        SendGear(master, comp);
    }

    bool NearTransmogrifier(Player* master)
    {
        return master->FindNearestCreature(TMOG_VENDOR_CREATURE_ID, cfg.transmogRange) != nullptr;
    }

    // Every appearance that could go on an item, one representative item per
    // visual (DisplayInfoID), like the retail wardrobe. Built once per
    // (item, class) and kept; collected state is applied at send time.
    struct Appearance
    {
        uint32 display;
        std::vector<uint32> items;
        uint32 itemLevel;
    };
    std::unordered_map<uint64, std::vector<Appearance>> g_appearanceCache;

    bool LooksLikeRealItem(ItemTemplate const& proto)
    {
        if (!proto.DisplayInfoID || (proto.Class != ITEM_CLASS_ARMOR && proto.Class != ITEM_CLASS_WEAPON))
            return false;
        std::string const& n = proto.Name1;
        for (char const* bad : {"Monster", "TEST", "Test ", "Deprecated", "OLD", "QA ", "zz", "[PH]", "NPC Equip"})
            if (n.find(bad) != std::string::npos)
                return false;
        return true;
    }

    std::vector<Appearance> const& AppearancesFor(Player* target, ItemTemplate const* dest)
    {
        uint64 key = (uint64(dest->ItemId) << 8) | target->getClass();
        auto it = g_appearanceCache.find(key);
        if (it != g_appearanceCache.end())
            return it->second;
        std::unordered_map<uint32, size_t> byDisplay;
        std::vector<Appearance> list;
        for (auto const& [id, proto] : *sObjectMgr->GetItemTemplateStore())
        {
            if (!LooksLikeRealItem(proto) || proto.DisplayInfoID == dest->DisplayInfoID)
                continue;
            if (!sTransmogrification->CanTransmogrifyItemWithItem(target, dest, &proto))
                continue;
            auto found = byDisplay.find(proto.DisplayInfoID);
            if (found == byDisplay.end())
            {
                byDisplay[proto.DisplayInfoID] = list.size();
                list.push_back({proto.DisplayInfoID, {id}, proto.ItemLevel});
            }
            else
            {
                Appearance& a = list[found->second];
                a.items.push_back(id);
                a.itemLevel = std::max(a.itemLevel, proto.ItemLevel);
            }
        }
        return g_appearanceCache.emplace(key, std::move(list)).first->second;
    }

    void CmdTransmogList(Player* master, uint32 low, uint8 eslot)
    {
        Player* target = GetWardrobeTarget(master, low);
        if (!target || eslot >= EQUIPMENT_SLOT_END)
            return;
        Item* item = target->GetItemByPos(INVENTORY_SLOT_BAG_0, eslot);
        std::vector<std::string> recs;
        uint32 collected = 0, total = 0;
        if (item)
        {
            auto acc = sTransmogrification->collectionCache.find(master->GetSession()->GetAccountId());
            static std::unordered_set<uint32> const none;
            auto const& have = acc != sTransmogrification->collectionCache.end() ? acc->second : none;
            std::vector<std::pair<uint32, uint32>> owned, missing;    // (entry, item level)
            for (Appearance const& a : AppearancesFor(target, item->GetTemplate()))
            {
                uint32 pick = 0;
                for (uint32 id : a.items)
                    if (have.count(id))
                    {
                        pick = id;
                        break;
                    }
                if (pick)
                    owned.emplace_back(pick, a.itemLevel);
                else
                    missing.emplace_back(a.items.front(), a.itemLevel);
            }
            auto byLevel = [](auto const& x, auto const& y) { return x.second != y.second ? x.second > y.second : x.first < y.first; };
            std::sort(owned.begin(), owned.end(), byLevel);
            std::sort(missing.begin(), missing.end(), byLevel);
            collected = owned.size();
            total = owned.size() + missing.size();
            for (auto const& [e, lvl] : owned)
                recs.push_back(std::to_string(e));
            // Uncollected looks are shown locked, as in the retail wardrobe; capped to keep it light.
            size_t room = owned.size() < 720 ? 720 - owned.size() : 0;
            for (size_t i = 0; i < missing.size() && i < room; ++i)
                recs.push_back("-" + std::to_string(missing[i].first));
        }
        std::ostringstream tail;
        tail << low << '|' << uint32(eslot) << '|' << (item ? sTransmogrification->GetFakeEntry(item->GetGUID()) : 0) << '|'
             << (NearTransmogrifier(master) ? 1 : 0) << '|' << (sTransmogrification->GetAllowHiddenTransmog() ? 1 : 0) << '|'
             << collected << '|' << total;
        SendList(master, "T", recs, tail.str());
    }

    void CmdTransmogSet(Player* master, uint32 low, uint8 eslot, uint32 entry)
    {
        Player* target = GetWardrobeTarget(master, low);
        if (!target || eslot >= EQUIPMENT_SLOT_END)
            return;
        if (!NearTransmogrifier(master))
            return Notify(master, "Visit a Transmogrifier to change appearances.");
        if (!target->GetItemByPos(INVENTORY_SLOT_BAG_0, eslot))
            return Notify(master, "Nothing is equipped in that slot.");
        if (entry == HIDDEN_ITEM_ID && !sTransmogrification->GetAllowHiddenTransmog())
            return Notify(master, "Hiding pieces is disabled on this realm.");
        if (entry > HIDDEN_ITEM_ID && !HasCollected(target, entry))
            return Notify(master, "You have not collected that appearance yet.");
        if (!ApplyLook(target, eslot, entry))
            return Notify(master, "That appearance does not fit this item.");
        RememberLook(target, eslot, entry);
        SendGear(master, target);
    }

    void CmdRepair(Player* master, std::string const& vendorHex)
    {
        ObjectGuid vendorGuid(uint64(std::strtoull(vendorHex.c_str(), nullptr, 16)));
        Creature* vendor = master->GetNPCIfCanInteractWith(vendorGuid, UNIT_NPC_FLAG_REPAIR);
        if (!vendor)
            return Notify(master, "Talk to a repair merchant first.");
        float discount = master->GetReputationPriceDiscount(vendor);
        uint32 spentTotal = 0;
        bool shortOfGold = false;
        for (Player* c : CompanionsOf(master))
        {
            // Lend the companion your purse for the repair, then take the rest back.
            uint32 lend = master->GetMoney();
            master->SetMoney(0);
            c->SetMoney(c->GetMoney() + lend);
            uint32 before = c->GetMoney();
            c->DurabilityRepairAll(true, discount, false);
            uint32 after = c->GetMoney();
            spentTotal += before - after;
            c->SetMoney(0);
            master->SetMoney(after);
            for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
                if (Item* it = c->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
                    if (it->GetUInt32Value(ITEM_FIELD_MAXDURABILITY) &&
                        it->GetUInt32Value(ITEM_FIELD_DURABILITY) < it->GetUInt32Value(ITEM_FIELD_MAXDURABILITY))
                        shortOfGold = true;
        }
        CharacterDatabaseTransaction trans = CharacterDatabase.BeginTransaction();
        master->SaveInventoryAndGoldToDB(trans);
        CharacterDatabase.CommitTransaction(trans);
        Send(master, "P|" + std::to_string(spentTotal) + "|" + (shortOfGold ? "1" : "0"));
    }

    void HandleCommand(Player* master, std::string const& msg)
    {
        std::istringstream in(msg);
        std::string cmd;
        in >> cmd;
        uint32 low = 0;
        if (cmd == "HELLO")
        {
            SendRoster(master);
            for (Player* c : CompanionsOf(master))
                SendStats(master, c);
        }
        else if (cmd == "WATCH")
        {
            uint32 on = 0;
            in >> on;
            if (on)
                g_watchers.insert(master->GetGUID());
            else
                g_watchers.erase(master->GetGUID());
        }
        else if (cmd == "OUTFITS" || cmd == "OSAVE" || cmd == "OUSE" || cmd == "ODEL")
        {
            uint32 k = 0;
            if (!(in >> low))
                return;
            Player* target = GetWardrobeTarget(master, low);
            if (!target)
                return;
            if (cmd == "OUTFITS")
                SendOutfits(master, target);
            else if (in >> k)
            {
                if (cmd == "OSAVE")
                    CmdOutfitSave(master, target, k);
                else if (cmd == "OUSE")
                    CmdOutfitUse(master, target, k);
                else
                    CmdOutfitDelete(master, target, k);
            }
        }
        else if (cmd == "STANCE")
        {
            uint32 s = 0;
            if ((in >> s) && s <= STANCE_PASSIVE)
            {
                master->UpdatePlayerSetting(SETTING_SOURCE, 0, s);
                static char const* const names[] = {
                    "Assist: they open on whatever hostile you target.",
                    "Defend: they only fight what attacks the party.",
                    "Aggressive: they also clear hostiles that come near you.",
                    "Passive: they will not fight."};
                Notify(master, names[s]);
                SendRoster(master);
            }
        }
        else if (cmd == "SUMMON" && (in >> low))
            CmdSummon(master, low);
        else if (cmd == "DISMISS" && (in >> low))
            CmdDismiss(master, low);
        else if (cmd == "ORDER")
        {
            std::string order;
            if (in >> low >> order)
                CmdOrder(master, low, order);
        }
        else if (cmd == "GEAR" && (in >> low))
        {
            if (Player* t = GetWardrobeTarget(master, low))
                SendGear(master, t);
        }
        else if (cmd == "EQUIP")
        {
            uint32 bag = 0, slot = 0, wanted = NULL_SLOT;
            if (in >> low >> bag >> slot >> wanted)
                CmdEquip(master, low, uint8(bag), uint8(slot), uint8(wanted));
        }
        else if (cmd == "UNEQUIP")
        {
            uint32 eslot = 0;
            if (in >> low >> eslot)
                CmdUnequip(master, low, uint8(eslot));
        }
        else if (cmd == "TLIST")
        {
            uint32 eslot = 0;
            if (in >> low >> eslot)
                CmdTransmogList(master, low, uint8(eslot));
        }
        else if (cmd == "TSET")
        {
            uint32 eslot = 0, entry = 0;
            if (in >> low >> eslot >> entry)
                CmdTransmogSet(master, low, uint8(eslot), entry);
        }
        else if (cmd == "REPAIR")
        {
            std::string hex;
            if (in >> hex)
                CmdRepair(master, hex);
        }
    }

    // ---- companion brain ---------------------------------------------------
    // Target choice lives here; how to fight it (spells, threat, healing) stays
    // with the playerbots AI, which treats prioritized targets as attackers.

    bool WorthFighting(Player* master, Unit* u, bool requireHostile)
    {
        if (!u || !u->IsAlive() || !u->IsInWorld() || u->GetMapId() != master->GetMapId())
            return false;
        Creature* c = u->ToCreature();
        if (!c || c->IsCivilian() || c->IsInEvadeMode())
            return false;
        if (!master->IsValidAttackTarget(u))
            return false;
        if (requireHostile && !u->IsHostileTo(master))
            return false;
        if (c->hasLootRecipient() && !c->isTappedBy(master))
            return false;                                   // someone else's kill
        return master->GetDistance(u) <= 40.0f;
    }

    Unit* NearestThreat(Player* master)
    {
        std::list<Unit*> units;
        Acore::AnyUnfriendlyUnitInObjectRangeCheck check(master, master, 20.0f);
        Acore::UnitListSearcher<Acore::AnyUnfriendlyUnitInObjectRangeCheck> searcher(master, units, check);
        Cell::VisitObjects(master, searcher, 20.0f);
        uint8 gray = Acore::XP::GetGrayLevel(master->GetLevel());
        Unit* best = nullptr;
        for (Unit* u : units)
        {
            if (!WorthFighting(master, u, true) || u->GetLevel() <= gray || !master->IsWithinLOSInMap(u))
                continue;
            if (!best || master->GetDistance(u) < master->GetDistance(best))
                best = u;
        }
        return best;
    }

    // Who should the party open on right now, if anyone?
    Unit* PartyTarget(Player* master, uint32 stance)
    {
        if (stance == STANCE_PASSIVE || stance == STANCE_DEFEND)
            return nullptr;
        if (!master->IsAlive() || master->IsMounted() || master->IsInFlight() || master->InBattleground())
            return nullptr;
        Unit* t = ObjectAccessor::GetUnit(*master, master->GetTarget());
        if (WorthFighting(master, t, true) || (t && t->GetVictim() == master && WorthFighting(master, t, false)))
            return t;
        if (stance == STANCE_AGGRESSIVE && !master->HasPlayerFlag(PLAYER_FLAGS_RESTING))
            return NearestThreat(master);
        return nullptr;
    }

    void ApplyStance(Player* comp, CompanionState& st, uint32 stance)
    {
        if (st.appliedStance == int32(stance))
            return;
        PlayerbotAI* ai = sPlayerbotsMgr.GetPlayerbotAI(comp);
        if (!ai)
            return;
        bool passive = stance == STANCE_PASSIVE;
        ai->ChangeStrategy(passive ? "+passive" : "-passive", BOT_STATE_COMBAT);
        ai->ChangeStrategy(passive ? "+passive" : "-passive", BOT_STATE_NON_COMBAT);
        st.appliedStance = int32(stance);
    }

    void PointAt(Player* comp, CompanionState& st, Unit* target)
    {
        ObjectGuid guid = target ? target->GetGUID() : ObjectGuid::Empty;
        if (st.engaged == guid)
            return;
        PlayerbotAI* ai = sPlayerbotsMgr.GetPlayerbotAI(comp);
        if (!ai)
            return;
        GuidVector targets;
        if (target)
            targets.push_back(guid);
        ai->GetAiObjectContext()->GetValue<GuidVector>("prioritized targets")->Set(targets);
        st.engaged = guid;
    }

    // Companions get back on their feet once a fight is over (no corpse runs).
    void ReviveIfCalm(Player* comp, Player* master, MasterState const& ms, CompanionState& st)
    {
        if (comp->IsAlive())
        {
            st.deadTicks = 0;
            return;
        }
        if (++st.deadTicks == 1)
            Notify(master, comp->GetName() + " has fallen - back on their feet in " + std::to_string(cfg.reviveDelay) +
                " seconds once the fight is over.");
        if (st.deadTicks < cfg.reviveDelay || !master->IsAlive() || ms.calmTicks < 3)
            return;
        comp->ResurrectPlayer(0.5f);
        comp->SpawnCorpseBones();
        BringToMaster(comp, master, true);
        Notify(master, comp->GetName() + " gets back on their feet.");
    }

    // Lost, stuck or left behind: catch up once out of combat.
    void KeepTogether(Player* comp, Player* master, CompanionState& st)
    {
        bool apart = comp->GetMapId() != master->GetMapId() || comp->GetDistance(master) > 80.0f;
        if (!apart || comp->IsInCombat() || !comp->IsAlive() || !master->IsAlive())
        {
            st.apartTicks = 0;
            return;
        }
        if (++st.apartTicks >= 4 && BringToMaster(comp, master, false))
            st.apartTicks = 0;
    }

    // ---- reconciliation (world thread, once per second) -----------------

    void Reconcile()
    {
        std::unordered_map<ObjectGuid, ObjectGuid> found;    // companion -> master
        std::vector<ObjectGuid> dressers;                     // real players
        {
            std::shared_lock<std::shared_mutex> lock(*HashMapHolder<Player>::GetLock());
            for (auto const& [guid, p] : ObjectAccessor::GetPlayers())
            {
                if (!p || !p->IsInWorld() || !p->GetSession())
                    continue;
                PlayerbotMgr* mgr = sPlayerbotsMgr.GetPlayerbotMgr(p);
                if (!mgr)
                    continue;
                dressers.push_back(p->GetGUID());
                if (!mgr->GetPlayerbotsCount())
                    continue;
                uint32 account = p->GetSession()->GetAccountId();
                for (auto it = mgr->GetPlayerBotsBegin(); it != mgr->GetPlayerBotsEnd(); ++it)
                {
                    Player* bot = it->second;
                    if (bot && bot->IsInWorld() && bot->GetSession() && bot->GetSession()->GetAccountId() == account)
                        found[bot->GetGUID()] = p->GetGUID();
                }
            }
        }

        std::unordered_set<ObjectGuid> changedMasters;
        {
            std::lock_guard<std::mutex> lock(g_lock);
            for (auto const& [comp, master] : g_companionMaster)
                if (!found.count(comp))
                    changedMasters.insert(master);
            for (auto const& [comp, master] : found)
                if (!g_companionMaster.count(comp))
                    changedMasters.insert(master);
            g_companionMaster = found;
            g_masterCompanions.clear();
            for (auto const& [comp, master] : found)
                g_masterCompanions[master].insert(comp);
        }
        for (auto it = g_state.begin(); it != g_state.end();)
            it = found.count(it->first) ? std::next(it) : g_state.erase(it);

        ++g_tick;
        std::unordered_map<ObjectGuid, Unit*> partyTargets;
        std::unordered_map<ObjectGuid, uint32> stances;
        for (auto const& [compGuid, masterGuid] : found)
        {
            if (stances.count(masterGuid))
                continue;
            Player* master = ObjectAccessor::FindPlayer(masterGuid);
            if (!master)
                continue;
            uint32 stance = GetStance(master);
            stances[masterGuid] = stance;
            partyTargets[masterGuid] = PartyTarget(master, stance);
            bool fighting = master->IsInCombat();
            for (Player* c : CompanionsOf(master))
                fighting = fighting || c->IsInCombat();
            MasterState& ms = g_masters[masterGuid];
            ms.calmTicks = fighting ? 0 : ms.calmTicks + 1;
            bool moved = master->GetExactDist2d(ms.lastX, ms.lastY) > 0.5f;
            ms.stillTicks = moved ? 0 : ms.stillTicks + 1;
            ms.lastX = master->GetPositionX();
            ms.lastY = master->GetPositionY();
            ms.hasTank = false;
            for (Player* c : CompanionsOf(master))
                ms.hasTank = ms.hasTank || (c->IsAlive() && PlayerbotAI::IsTank(c, true));
        }
        for (auto it = g_masters.begin(); it != g_masters.end();)
            it = stances.count(it->first) ? std::next(it) : g_masters.erase(it);

        for (auto const& [compGuid, masterGuid] : found)
        {
            Player* comp = ObjectAccessor::FindPlayer(compGuid);
            Player* master = ObjectAccessor::FindPlayer(masterGuid);
            if (!comp || !master)
                continue;
            CompanionState& st = g_state[compGuid];
            st.master = masterGuid;
            ++st.seenTicks;
            SyncLevel(comp, master);
            if (!st.arrived && st.seenTicks >= 3)
                st.arrived = BringToMaster(comp, master, false) || st.seenTicks > 30;
            if (comp->GetTeamId() != master->GetTeamId())
            {
                if (PlayerbotMgr* mgr = sPlayerbotsMgr.GetPlayerbotMgr(master))
                {
                    Notify(master, comp->GetName() + " belongs to the other faction and was sent home.");
                    mgr->LogoutPlayerBot(compGuid);
                }
                continue;
            }
            if (st.arrived && !st.tamed)
            {
                Tame(comp);
                st.tamed = true;
            }
            if (st.arrived)
            {
                ApplyStance(comp, st, stances[masterGuid]);
                MasterState const& ms = g_masters[masterGuid];
                Unit* target = comp->IsAlive() ? partyTargets[masterGuid] : nullptr;
                bool tank = PlayerbotAI::IsTank(comp, true);
                if (target)
                {
                    if (PlayerbotAI::IsHeal(comp, true))
                        target = nullptr;                   // healers keep healing
                    else if (comp->IsInCombat() && tank)
                        target = nullptr;                   // mid-fight the tank picks up loose adds itself
                    else if (!comp->IsInCombat() && !tank && ms.hasTank && !target->IsInCombat())
                        target = nullptr;                   // let the tank open the fight
                }
                PointAt(comp, st, target);

                // Companions sit down around you while you stand still out of combat.
                bool idle = ms.stillTicks >= 15 && ms.calmTicks >= 15 && !master->IsMounted() && master->IsAlive();
                if (idle && !st.sitting && comp->IsAlive() && !comp->IsInCombat() && !comp->isMoving() &&
                    comp->GetMapId() == master->GetMapId() && comp->GetDistance(master) < 30.0f)
                {
                    comp->SetStandState(UNIT_STAND_STATE_SIT);
                    st.sitting = true;
                }
                else if (!idle && st.sitting)
                {
                    if (comp->getStandState() == UNIT_STAND_STATE_SIT)
                        comp->SetStandState(UNIT_STAND_STATE_STAND);
                    st.sitting = false;
                }
                ReviveIfCalm(comp, master, g_masters[masterGuid], st);
                KeepTogether(comp, master, st);
            }
            if (cfg.forwardLoot && g_tick % 3 == 0)
                SweepCompanionBags(comp, master);
            if (g_watchers.count(masterGuid) && g_tick % 2 == 0)
                SendStats(master, comp);
        }

        if (g_tick % 2 == 0)
        {
            for (ObjectGuid const& g : dressers)
                if (Player* p = ObjectAccessor::FindPlayer(g))
                    SettleLooks(p);
            for (auto const& [compGuid, masterGuid] : found)
                if (Player* c = ObjectAccessor::FindPlayer(compGuid))
                    SettleLooks(c);
        }
        for (auto it = g_lookSeen.begin(); it != g_lookSeen.end();)
            it = ObjectAccessor::FindPlayer(it->first) ? std::next(it) : g_lookSeen.erase(it);

        std::vector<std::pair<ObjectGuid, uint32>> money;
        {
            std::lock_guard<std::mutex> lock(g_lock);
            money.swap(g_moneyQueue);
        }
        for (auto const& [masterGuid, copper] : money)
            if (Player* master = ObjectAccessor::FindPlayer(masterGuid))
                master->ModifyMoney(int32(copper));

        for (ObjectGuid const& m : changedMasters)
            if (Player* master = ObjectAccessor::FindPlayer(m))
                if (g_watchers.count(m))
                    SendRoster(master);

        for (auto it = g_watchers.begin(); it != g_watchers.end();)
            it = ObjectAccessor::FindPlayer(*it) ? std::next(it) : g_watchers.erase(it);
    }
}

class PartyManagerPlayer : public PlayerScript
{
public:
    PartyManagerPlayer() : PlayerScript("PartyManagerPlayer", {
        PLAYERHOOK_CAN_PLAYER_USE_PRIVATE_CHAT, PLAYERHOOK_ON_GIVE_EXP, PLAYERHOOK_ON_MONEY_CHANGED}) { }

    bool OnPlayerCanUseChat(Player* player, uint32 type, uint32 lang, std::string& msg, Player* receiver) override
    {
        if (!cfg.enable || lang != LANG_ADDON || type != CHAT_MSG_WHISPER || receiver != player)
            return true;
        std::string const head = std::string(PREFIX) + "\t";
        if (msg.compare(0, head.size(), head) != 0)
            return true;
        if (!sPlayerbotsMgr.GetPlayerbotAI(player))       // real players only
            HandleCommand(player, msg.substr(head.size()));
        return false;
    }

    void OnPlayerGiveXP(Player* player, uint32& amount, Unit* victim, uint8 xpSource) override
    {
        if (!cfg.enable)
            return;
        std::lock_guard<std::mutex> lock(g_lock);
        if (cfg.levelLock && g_companionMaster.count(player->GetGUID()))
        {
            amount = 0;                                   // companions only level with you
            return;
        }
        if (!cfg.fullSoloXp || xpSource != XPSOURCE_KILL || !victim || !amount)
            return;
        auto it = g_masterCompanions.find(player->GetGUID());
        if (it == g_masterCompanions.end() || it->second.empty())
            return;
        Group* group = player->GetGroup();
        if (!group)
            return;
        for (auto const& slot : group->GetMemberSlots())
            if (it->second.count(slot.guid))
            {
                amount = std::max(amount, Acore::XP::Gain(player, victim, false));   // your companions don't split your XP
                return;
            }
    }

    void OnPlayerMoneyChanged(Player* player, int32& amount) override
    {
        if (!cfg.enable || !cfg.forwardMoney || amount <= 0)
            return;
        std::lock_guard<std::mutex> lock(g_lock);
        auto it = g_companionMaster.find(player->GetGUID());
        if (it == g_companionMaster.end())
            return;
        g_moneyQueue.emplace_back(it->second, uint32(amount));     // shared purse
        amount = 0;
    }
};

class PartyManagerWorld : public WorldScript
{
public:
    PartyManagerWorld() : WorldScript("PartyManagerWorld", {
        WORLDHOOK_ON_AFTER_CONFIG_LOAD, WORLDHOOK_ON_UPDATE}) { }

    void OnAfterConfigLoad(bool /*reload*/) override
    {
        cfg.enable = sConfigMgr->GetOption<bool>("PartyManager.Enable", true);
        cfg.maxCompanions = std::clamp<uint32>(sConfigMgr->GetOption<uint32>("PartyManager.MaxCompanions", 4), 1, 4);
        cfg.levelLock = sConfigMgr->GetOption<bool>("PartyManager.LevelLock", true);
        cfg.fullSoloXp = sConfigMgr->GetOption<bool>("PartyManager.FullSoloXP", true);
        cfg.forwardLoot = sConfigMgr->GetOption<bool>("PartyManager.SharedBags", true);
        cfg.forwardMoney = sConfigMgr->GetOption<bool>("PartyManager.SharedPurse", true);
        cfg.transmogRange = sConfigMgr->GetOption<float>("PartyManager.TransmogRange", 15.0f);
        cfg.reviveDelay = sConfigMgr->GetOption<uint32>("PartyManager.ReviveDelay", 30);
    }

    void OnUpdate(uint32 diff) override
    {
        if (!cfg.enable)
            return;
        g_tickTimer += diff;
        if (g_tickTimer < 1000)
            return;
        g_tickTimer = 0;
        Reconcile();
    }
};

void AddSC_party_manager()
{
    new PartyManagerPlayer();
    new PartyManagerWorld();
}
