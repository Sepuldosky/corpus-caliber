-- corpus_caliber_config.lua — toolgun de debug (aplicar armadura/limbs efímeros, inspect).
-- Migrado desde ADS 2.0 (ads_config.lua). El modo de toolgun (nombre de archivo)
-- prefija sus ClientConVars: corpus_caliber_config_*. Módulo vía Corpus.GetModule (lazy).
TOOL.Category="Caliber"
TOOL.Name="#tool.corpus_caliber_config.name"
TOOL.Command=nil
TOOL.ConfigName=""

TOOL.ClientConVar={
    apply_armor      = "1",
    apply_limbs      = "1",
    limb_head_frac   = "0.5",
    limb_arms_frac   = "0.5",
    limb_legs_frac   = "0.5",
}

if CLIENT then
    language.Add("tool.corpus_caliber_config.name","Caliber Debug")
    language.Add("tool.corpus_caliber_config.desc","Apply ephemeral armor/limbs to NPCs for testing. Does not save to JSON.")
    language.Add("tool.corpus_caliber_config.0","Left: Apply to NPC  |  Right: Copy from NPC  |  Reload: Inspect")
end

local function Notify(ply,t,err)
    if SERVER then
        ply:SendLua(string.format("notification.AddLegacy(%q,%s,4) surface.PlaySound(%q)",
            t, err and "NOTIFY_ERROR" or "NOTIFY_GENERIC",
            err and "buttons/button10.wav" or "buttons/button14.wav"))
    end
end

local function Validate(self,tr)
    local ply=self:GetOwner()
    if not IsValid(ply) or not ply:IsAdmin() then
        if SERVER then Notify(ply,"Caliber: admin only",true) end return nil
    end
    local e=tr.Entity
    if not IsValid(e) then return nil end
    if e:IsPlayer() then if SERVER then Notify(ply,"Caliber: NPCs only",true) end return nil end
    if not e:IsNPC() then if SERVER then Notify(ply,"Caliber: not an NPC",true) end return nil end
    return e,ply
end

function TOOL:LeftClick(tr)
    local e,ply=Validate(self,tr)
    if not e then return false end
    if CLIENT then
        -- El cliente envía el perfil completo; el servidor lo aplica via net.Receive("corpus_caliber_tool_apply")
        net.Start("corpus_caliber_tool_apply")
        net.WriteEntity(e)
        net.WriteBool(GetConVar("corpus_caliber_config_apply_armor"):GetBool())
        net.WriteBool(GetConVar("corpus_caliber_config_apply_limbs"):GetBool())
        net.WriteTable(toolState and toolState.armor or {})
        net.WriteFloat(GetConVar("corpus_caliber_config_limb_head_frac"):GetFloat())
        net.WriteFloat(GetConVar("corpus_caliber_config_limb_arms_frac"):GetFloat())
        net.WriteFloat(GetConVar("corpus_caliber_config_limb_legs_frac"):GetFloat())
        net.SendToServer()
        return true
    end
    return true  -- servidor: manejado por net.Receive("corpus_caliber_tool_apply") en corpus_caliber_core.lua
end

function TOOL:RightClick(tr)
    local e,ply=Validate(self,tr)
    if not e then return false end
    if CLIENT then
        -- Solicita leer armadura+limbs del NPC; respuesta llega en corpus_caliber_tool_copy_result
        net.Start("corpus_caliber_tool_copy")
        net.WriteEntity(e)
        net.SendToServer()
        return true
    end
    return true  -- servidor: manejado por net.Receive("corpus_caliber_tool_copy") en corpus_caliber_core.lua
end

function TOOL:Reload(tr)
    local e,ply=Validate(self,tr)
    if not e then return false end
    if CLIENT then return true end
    local cal  = Corpus.GetModule("caliber")
    local info = cal and cal.InspectNPC(e)
    if not info then return false end
    net.Start("corpus_caliber_inspect_result") net.WriteTable(info) net.Send(ply)
    return true
end

if CLIENT then

-- Estado local del toolgun: armadura a aplicar y zona seleccionada en el panel
local toolState = {
    armor        = {},   -- {zones={["1"]={class,dur_max,material},...}, fallback_generic={...}}
    selectedZone = "2",  -- hitgroup string; "2"=chest por defecto
}
local toolRefresh = nil  -- función asignada por BuildCPanel; llamada al recibir copy result

-- ── Listas (mantenidas para que Caliber_ListsUpdated no rompa otros hooks) ───────
net.Receive("corpus_caliber_send_lists", function()
    local len  = net.ReadUInt(32)
    local data = net.ReadData(len)
    local json = util.Decompress(data)
    local tbl  = (json and util.JSONToTable(json)) or {whitelist={}, blacklist={}}
    local cal = Corpus.GetModule("caliber")
    if cal then cal.ClientLists = tbl end
    hook.Run("Caliber_ListsUpdated")
end)

-- ── Inspect (R) — notificación breve + dump completo en consola ───────────────
net.Receive("corpus_caliber_inspect_result", function()
    local info = net.ReadTable()
    if not info then return end
    -- Notificación: Armored + Whitelisted únicamente
    local armedStr = info.is_armored and "ARMORED" or "not armored"
    local wlStr    = info.is_whitelisted and "WL:yes" or "WL:no"
    notification.AddLegacy(string.format("Caliber: %s | %s | %s",
        info.classname or "?", armedStr, wlStr), NOTIFY_GENERIC, 6)
    surface.PlaySound("buttons/button14.wav")
    -- Dump completo a consola
    Corpus.Log("caliber", "======== Caliber NPC Inspect ========")
    Corpus.Log("caliber", "classname      : " .. tostring(info.classname))
    Corpus.Log("caliber", "config_key     : " .. tostring(info.config_key))
    Corpus.Log("caliber", "is_vj          : " .. tostring(info.is_vj))
    Corpus.Log("caliber", "vj_class       : " .. tostring(info.vj_class))
    Corpus.Log("caliber", "is_armored     : " .. tostring(info.is_armored))
    Corpus.Log("caliber", "is_whitelisted : " .. tostring(info.is_whitelisted))
    Corpus.Log("caliber", "reason         : " .. tostring(info.reason))
    if info.override then
        Corpus.Log("caliber", "override       :")
        for k, v in pairs(info.override) do
            if type(v) == "table" then
                Corpus.Log("caliber", "  " .. k .. " :")
                for k2, v2 in pairs(v) do Corpus.Log("caliber", "    " .. k2 .. " = " .. tostring(v2)) end
            else
                Corpus.Log("caliber", "  " .. k .. " = " .. tostring(v))
            end
        end
    else
        Corpus.Log("caliber", "override       : (none, uses globals)")
    end
    if info.armor_slots then
        Corpus.Log("caliber", "--- Armor Slots ---")
        if info.tool_override then Corpus.Log("caliber", "  [MANUAL OVERRIDE ACTIVE]") end
        local ZONE_NAMES = {["0"]="Generic",["1"]="Head",["2"]="Chest",["3"]="Stomach",
                            ["4"]="L.Arm",["5"]="R.Arm",["6"]="L.Leg",["7"]="R.Leg"}
        for _, hg in ipairs({"0","1","2","3","4","5","6","7"}) do
            local s = info.armor_slots[hg]
            if s then
                Corpus.Log("caliber", string.format("  slot %-2s %-10s : cls=%d  dur=%d/%d  mat=%s",
                    hg, "(" .. (ZONE_NAMES[hg] or hg) .. ")",
                    s.class, s.dur, s.dur_max, s.material))
            end
        end
    else
        Corpus.Log("caliber", "armor_slots    : (not initialized)")
    end
    if info.limbs then
        Corpus.Log("caliber", "--- Limb HP ---")
        for _, k in ipairs({"head","arm_l","arm_r","leg_l","leg_r"}) do
            local l = info.limbs[k]
            if l then
                Corpus.Log("caliber", string.format("  %-6s : %.1f / %.1f  (%.0f%%)", k, l.hp, l.max, l.ratio * 100))
            end
        end
    end
    if info.scavenger then
        Corpus.Log("caliber", "--- Scavenger ---")
        Corpus.Log("caliber", "  can_scavenge       = " .. tostring(info.scavenger.can_scavenge))
        Corpus.Log("caliber", string.format("  cooldown_remaining = %.1fs", info.scavenger.cooldown_remaining or 0))
        Corpus.Log("caliber", "  target_weapon      = " .. tostring(info.scavenger.target_weapon or "(none)"))
        Corpus.Log("caliber", "  current_weapon     = " .. tostring(info.scavenger.current_weapon or "(none)"))
        if info.scavenger.current_weapon_weight then
            Corpus.Log("caliber", string.format("  weapon_weight      = %.2f", info.scavenger.current_weapon_weight))
        end
    end
    if info.shield then
        Corpus.Log("caliber", "--- Energy Shield ---")
        Corpus.Log("caliber", string.format("  type       = %-10s state = %s",
            tostring(info.shield.type), tostring(info.shield.state)))
        Corpus.Log("caliber", string.format("  pool       = %.1f / %d", info.shield.hp or 0, info.shield.max or 0))
        Corpus.Log("caliber", string.format("  regen      = %s  (rate=%.1f HP/s, delay=%.1fs)",
            tostring(info.shield.can_regen), info.shield.recharge_rate or 0, info.shield.recharge_delay or 0))
        Corpus.Log("caliber", string.format("  regen_in   = %.1fs   lockout_in = %.1fs",
            info.shield.regen_in or 0, info.shield.lockout_in or 0))
    end
    Corpus.Log("caliber", "=================================")
end)

-- ── Copy result (M2) — popula toolState y refresca el panel ──────────────────
net.Receive("corpus_caliber_tool_copy_result", function()
    local armor = net.ReadTable()
    local hf    = net.ReadFloat()
    local af    = net.ReadFloat()
    local lf    = net.ReadFloat()
    toolState.armor = armor or {}
    if toolRefresh then toolRefresh(hf, af, lf) end
    notification.AddLegacy("Caliber: Copied from NPC", NOTIFY_GENERIC, 3)
    surface.PlaySound("buttons/button14.wav")
end)

-- ── BuildCPanel ───────────────────────────────────────────────────────────────
function TOOL.BuildCPanel(cp)
    local MAT_LIST    = {"aramid","titanium","ceramic","poly_ceramic",
                         "nano_titanium","electrified_aramid","m_stf","uranium_matrix"}
    local MAT_DISPLAY = {
        aramid             = "Aramid",
        titanium           = "Titanium",
        ceramic            = "Ceramic",
        poly_ceramic       = "Poly-Ceramic",
        nano_titanium      = "Nano-Titanium",
        electrified_aramid = "Elec. Aramid",
        m_stf              = "M-STF",
        uranium_matrix     = "Uranium Matrix",
    }
    local ZONE_DEFAULTS = {class = 3, dur_max = 80, material = "aramid"}
    local ZONE_OPTIONS  = {
        {"1","HEAD (1)"}, {"2","CHEST (2)"}, {"3","STOMACH (3)"},
        {"4","L. ARM (4)"}, {"5","R. ARM (5)"}, {"6","L. LEG (6)"}, {"7","R. LEG (7)"},
    }
    local DUR_MIN, DUR_MAX = 10, 250

    cp:Help("Caliber Debug Tool  (admin only)")
    cp:Help("Left: Apply to NPC  |  Right: Copy from NPC  |  Reload: Inspect")

    cp:Button("Open Configuration").DoClick = function()
        RunConsoleCommand("caliber_browser")
    end

    -- Gate checkboxes
    cp:CheckBox("Apply Armor on Left Click",  "corpus_caliber_config_apply_armor")
    cp:CheckBox("Apply Limbs on Left Click",  "corpus_caliber_config_apply_limbs")

    -- ── ARMOR ────────────────────────────────────────────────────────────────
    cp:Help("Armor  (per-entity, ephemeral — not saved to JSON)")

    -- Zone selector
    local zoneSelRow = vgui.Create("DPanel", cp)
    zoneSelRow:SetTall(24)
    zoneSelRow.Paint = function() end
    local zoneSelLabel = vgui.Create("DLabel", zoneSelRow)
    zoneSelLabel:Dock(LEFT)
    zoneSelLabel:SetWide(38)
    zoneSelLabel:SetText("Zone:")
    zoneSelLabel:SetFont("DermaDefault")
    local zoneCombo = vgui.Create("DComboBox", zoneSelRow)
    zoneCombo:Dock(FILL)
    for _, opt in ipairs(ZONE_OPTIONS) do
        zoneCombo:AddChoice(opt[2], opt[1], opt[1] == toolState.selectedZone)
    end
    cp:AddItem(zoneSelRow)

    -- Armored checkbox
    local zoneCB = vgui.Create("DCheckBoxLabel", cp)
    zoneCB:SetTall(20)
    zoneCB:SetText("Armored")
    zoneCB:SetValue(false)
    cp:AddItem(zoneCB)

    -- Class buttons
    local clsRow = vgui.Create("DPanel", cp)
    clsRow:SetTall(26)
    clsRow:DockMargin(0, 2, 0, 2)
    clsRow.Paint = function() end
    local clsLabel = vgui.Create("DLabel", clsRow)
    clsLabel:Dock(LEFT)
    clsLabel:SetWide(38)
    clsLabel:SetText("Class:")
    clsLabel:SetFont("DermaDefault")
    local classBtns     = {}
    local clsContainer  = vgui.Create("DPanel", clsRow)
    clsContainer:Dock(FILL)
    clsContainer.Paint = function() end
    clsContainer.PerformLayout = function(self, w, h)
        local bw = math.floor(w / 8)
        for i, btn in ipairs(classBtns) do
            btn:SetPos((i - 1) * bw, 0)
            btn:SetSize(bw - 1, h)
        end
    end
    for i = 1, 8 do
        local btn = vgui.Create("DButton", clsContainer)
        btn:SetText(tostring(i))
        btn:SetFont("DermaDefault")
        classBtns[i] = btn
    end
    cp:AddItem(clsRow)

    -- Material
    local matRow = vgui.Create("DPanel", cp)
    matRow:SetTall(24)
    matRow:DockMargin(0, 2, 0, 2)
    matRow.Paint = function() end
    local matLabel = vgui.Create("DLabel", matRow)
    matLabel:Dock(LEFT)
    matLabel:SetWide(52)
    matLabel:SetText("Material:")
    matLabel:SetFont("DermaDefault")
    local matCombo = vgui.Create("DComboBox", matRow)
    matCombo:Dock(FILL)
    for _, mat in ipairs(MAT_LIST) do
        matCombo:AddChoice(MAT_DISPLAY[mat] or mat, mat, mat == ZONE_DEFAULTS.material)
    end
    cp:AddItem(matRow)

    -- Dur Max — fila manual (misma solución que el browser tras el fix)
    local durRow = vgui.Create("DPanel", cp)
    durRow:SetTall(20)
    durRow:DockMargin(0, 2, 0, 2)
    durRow.Paint = function() end
    local durLabel = vgui.Create("DLabel", durRow)
    durLabel:Dock(LEFT)
    durLabel:SetWide(52)
    durLabel:SetText("Dur Max")
    durLabel:SetFont("DermaDefault")
    local durEntry = vgui.Create("DTextEntry", durRow)
    durEntry:Dock(RIGHT)
    durEntry:SetWide(36)
    durEntry:SetNumeric(true)
    local durSlider = vgui.Create("DSlider", durRow)
    durSlider:Dock(FILL)
    local durUpdating  = false
    local toolRefreshing = false
    local function durSetValue(v)
        v = math.Clamp(math.floor(v), DUR_MIN, DUR_MAX)
        durUpdating = true
        durSlider:SetSlideX((v - DUR_MIN) / (DUR_MAX - DUR_MIN))
        durEntry:SetText(tostring(v))
        durUpdating = false
    end
    durSetValue(ZONE_DEFAULTS.dur_max)
    cp:AddItem(durRow)

    -- Enable/disable zone controls
    local function setZoneControlsEnabled(en)
        for _, b in ipairs(classBtns) do b:SetEnabled(en) end
        matCombo:SetEnabled(en)
        durSlider:SetEnabled(en)
        durEntry:SetEnabled(en)
    end
    setZoneControlsEnabled(false)

    -- Carga datos de una zona en los controles
    local function loadZone(hgKey)
        toolRefreshing = true
        local zones   = type(toolState.armor.zones) == "table" and toolState.armor.zones or {}
        local z       = zones[hgKey]
        zoneCB:SetValue(z ~= nil)
        setZoneControlsEnabled(z ~= nil)
        local activeCls = z and (z.class or ZONE_DEFAULTS.class) or ZONE_DEFAULTS.class
        for i, btn in ipairs(classBtns) do
            local active = (i == activeCls)
            btn:SetFont(active and "DermaDefaultBold" or "DermaDefault")
            btn:SetTextColor(active and Color(255, 255, 255) or Color(180, 180, 180))
        end
        if z then
            matCombo:SetValue(MAT_DISPLAY[z.material] or z.material or MAT_DISPLAY[ZONE_DEFAULTS.material])
            durSetValue(z.dur_max or ZONE_DEFAULTS.dur_max)
        else
            matCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
            durSetValue(ZONE_DEFAULTS.dur_max)
        end
        toolRefreshing = false
    end

    -- Wire zone combo
    zoneCombo.OnSelect = function(_, _, _, data)
        toolState.selectedZone = data
        loadZone(data)
    end

    -- Wire armored checkbox
    zoneCB.OnChange = function(_, val)
        if toolRefreshing then return end
        toolState.armor.zones = toolState.armor.zones or {}
        if val then
            toolState.armor.zones[toolState.selectedZone] = {
                class = ZONE_DEFAULTS.class, dur_max = ZONE_DEFAULTS.dur_max, material = ZONE_DEFAULTS.material,
            }
            setZoneControlsEnabled(true)
            loadZone(toolState.selectedZone)
        else
            toolState.armor.zones[toolState.selectedZone] = nil
            if not next(toolState.armor.zones) then toolState.armor.zones = nil end
            setZoneControlsEnabled(false)
        end
    end

    -- Wire class buttons
    for i, btn in ipairs(classBtns) do
        btn.DoClick = function()
            if toolRefreshing then return end
            local zones = toolState.armor.zones
            if zones and zones[toolState.selectedZone] then
                zones[toolState.selectedZone].class = i
                for j, b in ipairs(classBtns) do
                    b:SetFont(j == i and "DermaDefaultBold" or "DermaDefault")
                    b:SetTextColor(j == i and Color(255, 255, 255) or Color(180, 180, 180))
                end
            end
        end
    end

    -- Wire material combo
    matCombo.OnSelect = function(_, _, _, data)
        if toolRefreshing then return end
        local zones = toolState.armor.zones
        if zones and zones[toolState.selectedZone] then
            zones[toolState.selectedZone].material = data
        end
    end

    -- Wire dur slider
    durSlider.OnValueChanged = function(_, x)
        if toolRefreshing or durUpdating then return end
        local v = math.floor(DUR_MIN + x * (DUR_MAX - DUR_MIN))
        durUpdating = true
        durEntry:SetText(tostring(v))
        durUpdating = false
        local zones = toolState.armor.zones
        if zones and zones[toolState.selectedZone] then
            zones[toolState.selectedZone].dur_max = v
        end
    end

    -- Wire dur entry
    durEntry.OnEnter = function(self)
        if toolRefreshing then return end
        local v = math.Clamp(tonumber(self:GetText()) or DUR_MIN, DUR_MIN, DUR_MAX)
        durSetValue(v)
        local zones = toolState.armor.zones
        if zones and zones[toolState.selectedZone] then
            zones[toolState.selectedZone].dur_max = v
        end
    end
    durEntry.OnLostFocus = durEntry.OnEnter

    -- ── Separator ─────────────────────────────────────────────────────────────
    local sep = vgui.Create("DPanel", cp)
    sep:SetTall(6)
    sep.Paint = function(self, w, h)
        surface.SetDrawColor(70, 70, 70)
        surface.DrawRect(0, 3, w, 1)
    end
    cp:AddItem(sep)

    -- ── Fallback Generic ──────────────────────────────────────────────────────
    local fgCB = vgui.Create("DCheckBoxLabel", cp)
    fgCB:SetTall(20)
    fgCB:SetText("Fallback / GENERIC  (non-humanoid or unmatched hitgroups)")
    fgCB:SetValue(false)
    cp:AddItem(fgCB)

    local fgClassBtns    = {}
    local fgClsRow       = vgui.Create("DPanel", cp)
    fgClsRow:SetTall(26)
    fgClsRow:DockMargin(0, 2, 0, 2)
    fgClsRow.Paint = function() end
    local fgClsLabel = vgui.Create("DLabel", fgClsRow)
    fgClsLabel:Dock(LEFT)
    fgClsLabel:SetWide(38)
    fgClsLabel:SetText("Class:")
    fgClsLabel:SetFont("DermaDefault")
    local fgContainer = vgui.Create("DPanel", fgClsRow)
    fgContainer:Dock(FILL)
    fgContainer.Paint = function() end
    fgContainer.PerformLayout = function(self, w, h)
        local bw = math.floor(w / 8)
        for i, btn in ipairs(fgClassBtns) do
            btn:SetPos((i - 1) * bw, 0)
            btn:SetSize(bw - 1, h)
        end
    end
    for i = 1, 8 do
        local btn = vgui.Create("DButton", fgContainer)
        btn:SetText(tostring(i))
        btn:SetFont("DermaDefault")
        fgClassBtns[i] = btn
    end
    cp:AddItem(fgClsRow)

    local fgMatRow = vgui.Create("DPanel", cp)
    fgMatRow:SetTall(24)
    fgMatRow:DockMargin(0, 2, 0, 2)
    fgMatRow.Paint = function() end
    local fgMatLabel = vgui.Create("DLabel", fgMatRow)
    fgMatLabel:Dock(LEFT)
    fgMatLabel:SetWide(52)
    fgMatLabel:SetText("Material:")
    fgMatLabel:SetFont("DermaDefault")
    local fgMatCombo = vgui.Create("DComboBox", fgMatRow)
    fgMatCombo:Dock(FILL)
    for _, mat in ipairs(MAT_LIST) do
        fgMatCombo:AddChoice(MAT_DISPLAY[mat] or mat, mat, mat == ZONE_DEFAULTS.material)
    end
    cp:AddItem(fgMatRow)

    local fgDurRow = vgui.Create("DPanel", cp)
    fgDurRow:SetTall(20)
    fgDurRow:DockMargin(0, 2, 0, 2)
    fgDurRow.Paint = function() end
    local fgDurLabel = vgui.Create("DLabel", fgDurRow)
    fgDurLabel:Dock(LEFT)
    fgDurLabel:SetWide(52)
    fgDurLabel:SetText("Dur Max")
    fgDurLabel:SetFont("DermaDefault")
    local fgDurEntry = vgui.Create("DTextEntry", fgDurRow)
    fgDurEntry:Dock(RIGHT)
    fgDurEntry:SetWide(36)
    fgDurEntry:SetNumeric(true)
    local fgDurSlider = vgui.Create("DSlider", fgDurRow)
    fgDurSlider:Dock(FILL)
    local fgDurUpdating = false
    local function fgDurSetValue(v)
        v = math.Clamp(math.floor(v), DUR_MIN, DUR_MAX)
        fgDurUpdating = true
        fgDurSlider:SetSlideX((v - DUR_MIN) / (DUR_MAX - DUR_MIN))
        fgDurEntry:SetText(tostring(v))
        fgDurUpdating = false
    end
    fgDurSetValue(ZONE_DEFAULTS.dur_max)
    cp:AddItem(fgDurRow)

    local function setFGEnabled(en)
        for _, b in ipairs(fgClassBtns) do b:SetEnabled(en) end
        fgMatCombo:SetEnabled(en)
        fgDurSlider:SetEnabled(en)
        fgDurEntry:SetEnabled(en)
    end
    setFGEnabled(false)

    fgCB.OnChange = function(_, val)
        if toolRefreshing then return end
        setFGEnabled(val)
        if val then
            toolState.armor.fallback_generic = {
                class = ZONE_DEFAULTS.class, dur_max = ZONE_DEFAULTS.dur_max, material = ZONE_DEFAULTS.material,
            }
            for j, b in ipairs(fgClassBtns) do
                b:SetFont(j == ZONE_DEFAULTS.class and "DermaDefaultBold" or "DermaDefault")
                b:SetTextColor(j == ZONE_DEFAULTS.class and Color(255, 255, 255) or Color(180, 180, 180))
            end
            fgMatCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
            fgDurSetValue(ZONE_DEFAULTS.dur_max)
        else
            toolState.armor.fallback_generic = nil
        end
    end

    for i, btn in ipairs(fgClassBtns) do
        btn.DoClick = function()
            if toolRefreshing then return end
            if toolState.armor.fallback_generic then
                toolState.armor.fallback_generic.class = i
                for j, b in ipairs(fgClassBtns) do
                    b:SetFont(j == i and "DermaDefaultBold" or "DermaDefault")
                    b:SetTextColor(j == i and Color(255, 255, 255) or Color(180, 180, 180))
                end
            end
        end
    end

    fgMatCombo.OnSelect = function(_, _, _, data)
        if toolRefreshing then return end
        if toolState.armor.fallback_generic then
            toolState.armor.fallback_generic.material = data
        end
    end

    fgDurSlider.OnValueChanged = function(_, x)
        if toolRefreshing or fgDurUpdating then return end
        local v = math.floor(DUR_MIN + x * (DUR_MAX - DUR_MIN))
        fgDurUpdating = true
        fgDurEntry:SetText(tostring(v))
        fgDurUpdating = false
        if toolState.armor.fallback_generic then
            toolState.armor.fallback_generic.dur_max = v
        end
    end

    fgDurEntry.OnEnter = function(self)
        if toolRefreshing then return end
        local v = math.Clamp(tonumber(self:GetText()) or DUR_MIN, DUR_MIN, DUR_MAX)
        fgDurSetValue(v)
        if toolState.armor.fallback_generic then
            toolState.armor.fallback_generic.dur_max = v
        end
    end
    fgDurEntry.OnLostFocus = fgDurEntry.OnEnter

    -- ── LIMBS ─────────────────────────────────────────────────────────────────
    cp:Help("Limbs  (pool resize per-entity, current set to max on apply)")
    cp:NumSlider("Head HP frac",  "corpus_caliber_config_limb_head_frac", 0, 2, 2)
    cp:NumSlider("Arms HP frac",  "corpus_caliber_config_limb_arms_frac", 0, 2, 2)
    cp:NumSlider("Legs HP frac",  "corpus_caliber_config_limb_legs_frac", 0, 2, 2)

    -- Reset
    cp:Button("Reset to defaults").DoClick = function()
        RunConsoleCommand("corpus_caliber_config_limb_head_frac", "0.5")
        RunConsoleCommand("corpus_caliber_config_limb_arms_frac", "0.5")
        RunConsoleCommand("corpus_caliber_config_limb_legs_frac", "0.5")
        toolState.armor        = {}
        toolState.selectedZone = "2"
        toolRefreshing = true
        zoneCB:SetValue(false)
        setZoneControlsEnabled(false)
        durSetValue(ZONE_DEFAULTS.dur_max)
        matCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
        fgCB:SetValue(false)
        setFGEnabled(false)
        fgDurSetValue(ZONE_DEFAULTS.dur_max)
        fgMatCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
        toolRefreshing = false
    end

    -- Callback para net.Receive("corpus_caliber_tool_copy_result")
    toolRefresh = function(hf, af, lf)
        -- Actualizar fracs (convars)
        RunConsoleCommand("corpus_caliber_config_limb_head_frac", tostring(math.Round(hf, 2)))
        RunConsoleCommand("corpus_caliber_config_limb_arms_frac", tostring(math.Round(af, 2)))
        RunConsoleCommand("corpus_caliber_config_limb_legs_frac", tostring(math.Round(lf, 2)))
        -- Refrescar zona actual
        loadZone(toolState.selectedZone)
        -- Refrescar fallback
        toolRefreshing = true
        local fg = toolState.armor.fallback_generic
        fgCB:SetValue(fg ~= nil)
        setFGEnabled(fg ~= nil)
        if fg then
            local fgCls = fg.class or ZONE_DEFAULTS.class
            for j, b in ipairs(fgClassBtns) do
                b:SetFont(j == fgCls and "DermaDefaultBold" or "DermaDefault")
                b:SetTextColor(j == fgCls and Color(255, 255, 255) or Color(180, 180, 180))
            end
            fgMatCombo:SetValue(MAT_DISPLAY[fg.material] or fg.material or MAT_DISPLAY[ZONE_DEFAULTS.material])
            fgDurSetValue(fg.dur_max or ZONE_DEFAULTS.dur_max)
        else
            fgMatCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
            fgDurSetValue(ZONE_DEFAULTS.dur_max)
        end
        toolRefreshing = false
    end

    -- Estado inicial del panel
    loadZone(toolState.selectedZone)
end

end
