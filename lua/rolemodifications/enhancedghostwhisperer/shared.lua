local player = player

local PlayerIterator = player.Iterator

------------------
-- ROLE CONVARS --
------------------
---
local ghostwhisperer_max_abilities = CreateConVar("ttt_ghostwhisperer_max_abilities", "4", FCVAR_REPLICATED, "The maximum number of abilities the target of the Ghost Whisperer can buy. (Set to 0 to disable abilities)", 0, 9)

table.insert(ROLE_CONVARS[ROLE_GHOSTWHISPERER], {
    cvar = "ttt_ghostwhisperer_max_abilities",
    type = ROLE_CONVAR_TYPE_NUM,
    decimal = 0
})

--------------------------
-- ABILITY REGISTRATION --
--------------------------

GHOSTWHISPERER = {
    Abilities = {}
}

-- The reveal ability doesn't work for non-traitors so it isn't relevant here
local blockedAbilities = {"reveal"}

function GHOSTWHISPERER:RegisterAbility(ability, defaultEnabled)
    local abilityCopy = table.Copy(ability)
    defaultEnabled = defaultEnabled or 1

    if table.HasValue(blockedAbilities, abilityCopy.Id) then return end

    if GHOSTWHISPERER.Abilities[abilityCopy.Id] then
        ErrorNoHalt("[GHOST WHISPERER] Ghost Whisperer ability already exists with ID '" .. abilityCopy.Id .. "'\n")
        return
    end

    local enabled = CreateConVar("ttt_ghostwhisperer_" .. abilityCopy.Id .. "_enabled", tostring(defaultEnabled), FCVAR_REPLICATED)
    abilityCopy.Enabled = function()
        return enabled:GetBool()
    end
    table.insert(ROLE_CONVARS[ROLE_GHOSTWHISPERER], {
        cvar = "ttt_ghostwhisperer_" .. abilityCopy.Id .. "_enabled",
        type = ROLE_CONVAR_TYPE_BOOL
    })

    GHOSTWHISPERER.Abilities[abilityCopy.Id] = abilityCopy
end

for _, v in pairs(SOULBOUND.Abilities) do
    if v.DefaultEnabled then
        GHOSTWHISPERER:RegisterAbility(v, v.DefaultEnabled)
    else
        GHOSTWHISPERER:RegisterAbility(v)
    end
end

if SERVER then
    util.AddNetworkString("TTT_GhostWhispererBuyAbility")
    util.AddNetworkString("TTT_GhostWhispererUseAbility")

    ---------------
    -- ABILITIES --
    ---------------

    net.Receive("TTT_GhostWhispererUseAbility", function(len, ply)
        local num = net.ReadUInt(4)
        if ply:IsSoulbound() or not ply.TTTIsGhosting then return end

        local id = ply:GetNWString("TTTGhostWhispererAbility" .. tostring(num), "")
        if #id == 0 then return end

        local ability = GHOSTWHISPERER.Abilities[id]
        if not ability.Use then return end
        if not ability:Enabled() then return end

        local target = ply:GetObserverMode() ~= OBS_MODE_ROAMING and ply:GetObserverTarget() or nil
        if not ability:Condition(ply, target) then return end
        ability:Use(ply, target)
    end)

    -----------------------
    -- PASSIVE ABILITIES --
    -----------------------

    hook.Add("Think", "GhostWhisperer_Think", function()
        for _, p in PlayerIterator() do
            if not p:IsSoulbound() and p.TTTIsGhosting then
                local max = ghostwhisperer_max_abilities:GetInt()
                for i = 1, max do
                    local id = p:GetNWString("TTTGhostWhispererAbility" .. tostring(i), "")
                    if #id == 0 then break end

                    local ability = GHOSTWHISPERER.Abilities[id]
                    if not ability.Passive then continue end
                    if not ability:Enabled() then continue end

                    local target = p:GetObserverMode() ~= OBS_MODE_ROAMING and p:GetObserverTarget() or nil
                    if not ability:Condition(p, target) then continue end
                    ability:Passive(p, target)
                end
            end
        end
    end)

    ----------------------
    -- ABILITY PURCHASE --
    ----------------------

    net.Receive("TTT_GhostWhispererBuyAbility", function(len, ply)
        local id = net.ReadString()
        if ply:IsSoulbound() or not ply.TTTIsGhosting then return end

        local max = ghostwhisperer_max_abilities:GetInt()
        for i = 1, max do
            local slotId = ply:GetNWString("TTTGhostWhispererAbility" .. tostring(i), "")
            if #slotId > 0 then continue end

            ply:SetNWString("TTTGhostWhispererAbility" .. tostring(i), id)

            local ability = GHOSTWHISPERER.Abilities[id]
            ability:Bought(ply)
            return
        end
        ply:PrintMessage(HUD_PRINTTALK, "You can't buy another ability!")
    end)

    -------------
    -- CLEANUP --
    -------------

    hook.Add("TTTPrepareRound", "GhostWhisperer_Cleanup_TTTPrepareRound", function()
        for _, p in PlayerIterator() do
            for i = 1, ghostwhisperer_max_abilities:GetInt() do
                local id = p:GetNWString("TTTGhostWhispererAbility" .. tostring(i), "")
                if #id > 0 then
                    local ability = GHOSTWHISPERER.Abilities[id]
                    ability:Cleanup(p)
                    p:SetNWString("TTTGhostWhispererAbility" .. tostring(i), "")
                end
            end
        end
    end)

    -----------------
    -- ALIVE CHECK --
    -----------------

    hook.Add("TTTPlayerSpawnForRound", "GhostWhisperer_Cleanup_TTTPlayerSpawnForRound", function(ply, dead_only)
        if not IsPlayer(ply) then return end
        for i = 1, ghostwhisperer_max_abilities:GetInt() do
            local id = ply:GetNWString("TTTGhostWhispererAbility" .. tostring(i), "")
            if #id > 0 then
                local ability = GHOSTWHISPERER.Abilities[id]
                ability:Cleanup(ply)
                ply:SetNWString("TTTGhostWhispererAbility" .. tostring(i), "")
            end
        end
    end)

    ------------------------------
    -- GHOSTING DEVICE OVERRIDE --
    ------------------------------

    hook.Add("PreRegisterSWEP", "GhostWhisperer_PreRegisterSWEP", function(SWEP, class)
        if class ~= "weapon_ttt_gwh_ghosting" then return end

        function SWEP:OnSuccess(ply, body)
            local message = ROLE_STRINGS_EXT[ROLE_GHOSTWHISPERER]
            message = message:gsub("^%l", string.upper)
            message = message .. " has granted you the ability to talk in chat and use abilities!"
            ply:QueueMessage(MSG_PRINTBOTH, message)
            ply:SetProperty("TTTIsGhosting", true)
        end
    end)
end

if CLIENT then
    local client

    ----------
    -- SHOP --
    ----------

    local function CreateFavTable()
        if not sql.TableExists("ttt_soulbound_fav") then
            local query = "CREATE TABLE ttt_soulbound_fav (sid64 TEXT, ability_id TEXT)"
            sql.Query(query)
        end
    end

    local function AddFavorite(sid64, ability_id)
        local query = "INSERT INTO ttt_soulbound_fav VALUES('" .. sid64 .. "','" .. ability_id .. "')"
        sql.Query(query)
    end

    local function RemoveFavorite(sid64, ability_id)
        local query = "DELETE FROM ttt_soulbound_fav WHERE sid64 = '" .. sid64 .. "' AND `ability_id` = '" .. ability_id .. "'"
        sql.Query(query)
    end

    local function GetFavorites(sid64)
        local query = "SELECT ability_id FROM ttt_soulbound_fav WHERE sid64 = '" .. sid64 .. "'"
        return sql.Query(query)
    end

    local function IsFavorite(favorites, ability_id)
        for _, value in pairs(favorites) do
            local dbid = value["ability_id"]
            if dbid == ability_id then
                return true
            end
        end
        return false
    end

    local dshop
    local function OpenGhostWhispererShop()
        local maxAbilities = ghostwhisperer_max_abilities:GetInt()
        if maxAbilities == 0 then return end

        local ownedAbilities = {}
        for i = 1, maxAbilities do
            local slotId = client:GetNWString("TTTGhostWhispererAbility" .. tostring(i), "")
            if #slotId == 0 then break end
            table.insert(ownedAbilities, slotId)
        end

        local numCols = GetGlobalInt("ttt_bem_sv_cols", 4)
        local numRows = GetGlobalInt("ttt_bem_sv_rows", 5)
        local itemSize = GetGlobalInt("ttt_bem_sv_size", 64)

        if GetGlobalBool("ttt_bem_allow_change", true) then
            numCols = GetConVar("ttt_bem_cols"):GetInt()
            numRows = GetConVar("ttt_bem_rows"):GetInt()
            itemSize = GetConVar("ttt_bem_size"):GetInt()
        end

        -- margin
        local m = 5
        -- item list width
        local dlistw = ((itemSize + 2) * numCols) - 2 + 15
        local dlisth = ((itemSize + 2) * numRows) - 2 + 45
        -- right column width
        local diw = 270
        -- frame size
        local w = dlistw + diw + (m * 2)
        local h = dlisth + 75

        -- Close any existing shop menu
        if IsValid(dshop) then dshop:Close() end

        local dframe = vgui.Create("DFrame")
        dframe:SetSize(w, h)
        dframe:Center()
        dframe:SetTitle(LANG.GetTranslation("sbd_abilities_title"))
        dframe:SetVisible(true)
        dframe:ShowCloseButton(true)
        dframe:SetMouseInputEnabled(true)
        dframe:SetDeleteOnClose(true)

        local dequip = vgui.Create("DPanel", dframe)
        dequip:SetPaintBackground(false)
        dequip:StretchToParent(m, m + 25, m, m)

        local dsearchheight = 25
        local dsearchpadding = 5
        local dsearch = vgui.Create("DTextEntry", dequip)
        dsearch:SetPos(0, 0)
        dsearch:SetSize(dlistw, dsearchheight)
        dsearch:SetPlaceholderText("Search...")
        dsearch:SetUpdateOnType(true)
        dsearch.OnGetFocus = function() dframe:SetKeyboardInputEnabled(true) end
        dsearch.OnLoseFocus = function() dframe:SetKeyboardInputEnabled(false) end

        --- Construct icon listing
        --- icon size = 64 x 64
        local dlist = vgui.Create("EquipSelect", dequip)
        -- local dlistw = 288
        dlist:SetPos(0, dsearchheight + dsearchpadding)
        dlist:SetSize(dlistw, dlisth + m)
        dlist:EnableVerticalScrollbar(true)
        dlist:EnableHorizontal(true)

        local bw, bh = 104, 25

        -- Whole right column
        local dih = h - bh - m - 4
        local dinfobg = vgui.Create("DPanel", dequip)
        dinfobg:SetPaintBackground(false)
        dinfobg:SetSize(diw, dih)
        dinfobg:SetPos(dlistw + m, 0)

        -- item info pane
        local dinfo = vgui.Create("ColoredBox", dinfobg)
        dinfo:SetColor(Color(90, 90, 95))
        dinfo:SetPos(0, 0)
        dinfo:StretchToParent(0, 0, m * 2, bh + (m * 2))

        local dfields = {}
        for _, k in pairs({ "Name", "Description" }) do
            dfields[k] = vgui.Create("DLabel", dinfo)
            dfields[k]:SetTooltip(LANG.GetTranslation("equip_spec_" .. k))
            dfields[k]:SetPos(m * 3, m * 2)
            dfields[k]:SetWidth(diw - m * 6)
        end

        dfields.Name:SetFont("TabLarge")

        dfields.Description:SetFont("DermaDefaultBold")
        dfields.Description:SetContentAlignment(7)
        dfields.Description:MoveBelow(dfields.Name, 1)

        local dhelp = vgui.Create("DPanel", dinfobg)
        dhelp:SetPaintBackground(false)
        dhelp:SetSize(diw, 64)
        dhelp:MoveBelow(dinfo, m)

        local function FillAbilityList(abilities)
            dlist:Clear()

            local paneltablefav = {}
            local paneltable = {}

            local ic = nil
            for _, ability in pairs(abilities) do
                if not ability:Enabled() then continue end

                if ability.Icon then
                    ic = vgui.Create("LayeredIcon", dlist)

                    ic.favorite = false
                    local favorites = GetFavorites(client:SteamID64())
                    if favorites then
                        if IsFavorite(favorites, ability.Id) then
                            ic.favorite = true
                            if GetConVar("ttt_bem_marker_fav"):GetBool() then
                                local star = vgui.Create("DImage")
                                star:SetImage("icon16/star.png")
                                star.PerformLayout = function(s)
                                    s:AlignTop(2)
                                    s:AlignRight(2)
                                    s:SetSize(12, 12)
                                end
                                star:SetTooltip("Favorite")
                                ic:AddLayer(star)
                                ic:EnableMousePassthrough(star)
                            end
                        end
                    end

                    ic:SetIconSize(itemSize)
                    ic:SetIcon(ability.Icon)
                else
                    ErrorNoHalt("Ability does not have model or material specified: " .. ability.Name .. "\n")
                end

                ic.ability = ability

                ic:SetTooltip(ability.Name)

                if #ownedAbilities >= maxAbilities or table.HasValue(ownedAbilities, ability.Id) then
                    ic:SetIconColor(Color(255, 255, 255, 80))
                end

                if ic.favorite then
                    table.insert(paneltablefav, ic)
                else
                    table.insert(paneltable, ic)
                end
            end

            local AddNameSortedItems = function(panels)
                if GetConVar("ttt_sort_alphabetically"):GetBool() then
                    table.sort(panels, function(a, b) return string.lower(a.ability.Name) < string.lower(b.ability.Name) end)
                end
                for _, panel in pairs(panels) do
                    dlist:AddPanel(panel)
                end
            end
            AddNameSortedItems(paneltablefav)
            if GetConVar("ttt_shop_random_position"):GetBool() then
                paneltable = table.Shuffle(paneltable)
                for _, panel in ipairs(paneltable) do
                    dlist:AddPanel(panel)
                end
            else
                AddNameSortedItems(paneltable)
            end

            dlist:SelectPanel(dlist:GetItems()[1])
        end

        local function DoesValueMatch(ability, data, value)
            local itemdata = ability[data]
            if isfunction(itemdata) then
                itemdata = itemdata()
            end
            return itemdata and string.find(string.lower(LANG.TryTranslation(itemdata)), string.lower(value), 1, true)
        end

        dsearch.OnValueChange = function(box, value)
            local filtered = {}
            for _, v in pairs(GHOSTWHISPERER.Abilities) do
                if v and (DoesValueMatch(v, "Name", value) or DoesValueMatch(v, "Description", value)) then
                    table.insert(filtered, v)
                end
            end
            FillAbilityList(filtered)
        end

        dhelp:SizeToContents()

        local dconfirm = vgui.Create("DButton", dinfobg)
        dconfirm:SetPos(0, dih - bh - m)
        dconfirm:SetSize(bw, bh)
        dconfirm:SetDisabled(true)
        dconfirm:SetText(LANG.GetTranslation("sbd_abilities_confirm"))

        dlist.OnActivePanelChanged = function(self, _, new)
            if new and new.ability then
                for k, v in pairs(new.ability) do
                    if dfields[k] then
                        local value = v
                        if type(v) == "function" then
                            value = v()
                        end
                        dfields[k]:SetText(LANG.TryTranslation(value))
                        dfields[k]:SetAutoStretchVertical(true)
                        dfields[k]:SetWrap(true)
                    end
                end
                if #ownedAbilities >= maxAbilities or table.HasValue(ownedAbilities, new.ability.Id) then
                    dconfirm:SetDisabled(true)
                else
                    dconfirm:SetDisabled(false)
                end
            end
        end

        dconfirm.DoClick = function()
            local pnl = dlist.SelectedPanel
            if not pnl or not pnl.ability then return end
            local choice = pnl.ability
            net.Start("TTT_GhostWhispererBuyAbility")
            net.WriteString(choice.Id)
            net.SendToServer()
            dframe:Close()
        end

        local dfav = vgui.Create("DButton", dinfobg)
        dfav:MoveRightOf(dconfirm)
        local bx, _ = dfav:GetPos()
        dfav:SetPos(bx + 1, dih - bh - m)
        dfav:SetSize(bh, bh)
        dfav:SetDisabled(false)
        dfav:SetText("")
        dfav:SetImage("icon16/star.png")
        dfav:SetTooltip(LANG.GetTranslation("buy_favorite_toggle"))
        dfav.DoClick = function()
            local sid64 = client:SteamID64()
            local pnl = dlist.SelectedPanel
            if not pnl or not pnl.ability then return end
            local choice = pnl.ability
            local id = choice.Id
            CreateFavTable()
            if pnl.favorite then
                RemoveFavorite(sid64, id)
            else
                AddFavorite(sid64, id)
            end

            dsearch:OnTextChanged()
        end

        local drdm = vgui.Create("DButton", dinfobg)
        drdm:MoveRightOf(dfav)
        bx, _ = drdm:GetPos()
        drdm:SetPos(bx + 1, dih - bh - m)
        drdm:SetSize(bh, bh)
        drdm:SetDisabled(false)
        drdm:SetText("")
        drdm:SetImage("icon16/basket_go.png")
        drdm:SetTooltip(LANG.GetTranslation("sbd_abilities_random"))
        drdm.DoClick = function()
            local ability_panels = dlist:GetItems()
            local buyable_abilities = {}
            for _, panel in pairs(ability_panels) do
                if panel.ability and #ownedAbilities < maxAbilities and not table.HasValue(ownedAbilities, panel.ability.Id) then
                    table.insert(buyable_abilities, panel)
                end
            end

            if #buyable_abilities == 0 then return end

            local random_panel = buyable_abilities[math.random(1, #buyable_abilities)]
            dlist:SelectPanel(random_panel)
            dconfirm.DoClick()
        end

        local dcancel = vgui.Create("DButton", dinfobg)
        dcancel:MoveRightOf(drdm)
        bx, _ = dcancel:GetPos()
        dcancel:SetPos(bx + 1, dih - bh - m)
        dcancel:SetSize(bw, bh)
        dcancel:SetDisabled(false)
        dcancel:SetText(LANG.GetTranslation("close"))
        dcancel.DoClick = function() dframe:Close() end

        FillAbilityList(GHOSTWHISPERER.Abilities)

        dframe:MakePopup()
        dframe:SetKeyboardInputEnabled(false)

        dshop = dframe
    end

    hook.Add("OnContextMenuOpen", "GhostWhisperer_OnContextMenuOpen", function()
        if GetRoundState() ~= ROUND_ACTIVE then return end

        if not client then
            client = LocalPlayer()
        end
        if client:IsSoulbound() or not client.TTTIsGhosting then return end

        if IsValid(dshop) then
            dshop:Close()
        else
            OpenGhostWhispererShop()
        end
    end)

    ---------------
    -- ABILITIES --
    ---------------

    local function UseAbility(num)
        if num > ghostwhisperer_max_abilities:GetInt() then return end
        net.Start("TTT_GhostWhispererUseAbility")
        net.WriteUInt(num, 4)
        net.SendToServer()
    end

    hook.Add("PlayerBindPress", "GhostWhisperer_PlayerBindPress", function(ply, bind, pressed)
        if not IsPlayer(ply) then return end
        if ply:IsSoulbound() or not ply.TTTIsGhosting then return end
        if not pressed then return end

        if string.StartsWith(bind, "slot") then
            local num = tonumber(string.Replace(bind, "slot", "")) or 1
            UseAbility(num)
        end
    end)

    ---------
    -- HUD --
    ---------

    hook.Add("HUDPaint", "GhostWhisperer_HUDPaint", function()
        if GetRoundState() ~= ROUND_ACTIVE then return end

        if not client then
            client = LocalPlayer()
        end
        if client:IsSoulbound() or not client.TTTIsGhosting then return end

        local max_abilities = ghostwhisperer_max_abilities:GetInt()
        if max_abilities == 0 then return end

        local margin = 2
        local width = 300
        local titleHeight = 28
        local bodyHeight = titleHeight * 2 + margin
        local x = ScrW() - width - 20
        local y = ScrH() - 20 + margin

        for i = max_abilities, 1, -1 do
            local slot = tostring(i)
            local id = client:GetNWString("TTTGhostWhispererAbility" .. slot, "")
            local ability = GHOSTWHISPERER.Abilities[id]
            if #id == 0 or not ability then
                y = y - titleHeight - margin
                draw.RoundedBox(8, x, y, width, titleHeight, Color(20, 20, 20, 200))
                draw.RoundedBoxEx(8, x, y, titleHeight, titleHeight, Color(90, 90, 90, 255), true, false, true, false)
                draw.SimpleText("Unassigned", "TimeLeft", x + titleHeight + (margin * 2), y + (titleHeight / 2), COLOR_WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            else
                y = y - titleHeight - bodyHeight - (margin * 2)
                draw.RoundedBox(8, x, y, width, titleHeight + bodyHeight + margin, Color(20, 20, 20, 200))
                draw.SimpleText(ability.Name, "TimeLeft", x + titleHeight + (margin * 2), y + (titleHeight / 2), COLOR_WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                local ready = ability:DrawHUD(client, x, y + titleHeight + margin, width, bodyHeight, Key("slot" .. slot, slot))
                local slotColor = Color(90, 90, 90, 255)
                if ready then
                    slotColor = ROLE_COLORS[client:GetRole()]
                end
                draw.RoundedBoxEx(8, x, y, titleHeight, titleHeight, slotColor, true, false, false, true)
            end
            CRHUD:ShadowedText(slot, "Trebuchet22", x + (titleHeight / 2), y + (titleHeight / 2), COLOR_WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end

        local sights_opacity = GetConVar("ttt_ironsights_crosshair_opacity")
        local crosshair_brightness = GetConVar("ttt_crosshair_brightness")
        local crosshair_size = GetConVar("ttt_crosshair_size")
        local disable_crosshair = GetConVar("ttt_disable_crosshair")

        if disable_crosshair:GetBool() then return end

        x = math.floor(ScrW() / 2.0)
        y = math.floor(ScrH() / 2.0)
        local scale = 0.2

        local alpha = sights_opacity:GetFloat() or 1
        local bright = crosshair_brightness:GetFloat() or 1

        local color = ROLE_COLORS_HIGHLIGHT[ROLE_TRAITOR]

        local r, g, b, _ = color:Unpack()
        surface.SetDrawColor(Color(r * bright, g * bright, b * bright, 255 * alpha))

        local gap = math.floor(20 * scale)
        local length = math.floor(gap + (25 * crosshair_size:GetFloat()) * scale)
        surface.DrawLine(x - length, y, x - gap, y)
        surface.DrawLine(x + length, y, x + gap, y)
        surface.DrawLine(x, y - length, x, y - gap)
        surface.DrawLine(x, y + length, x, y + gap)
    end)
end
