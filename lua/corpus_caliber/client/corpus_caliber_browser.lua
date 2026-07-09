-- corpus_caliber_browser.lua — browser de configuración por-NPC (client)
-- Migrado desde ADS 2.0 (cl_ads_browser.lua). DFrame con 6 sub-tabs internos
-- (Armor / Limbs-WL / Weapons / Energy Shield / Scavenger / General); se abre por el
-- concommand caliber_browser (botón del tab Corpus y del toolgun).
if SERVER then return end

local CALIBER = Corpus.GetModule("caliber")

local DBG    = CreateClientConVar("caliber_browser_debug",     "0",    true, false, "Enable debug prints for the Caliber NPC Browser")
local CV_X   = CreateClientConVar("caliber_browser_x",         "-1",   true, false)
local CV_Y   = CreateClientConVar("caliber_browser_y",         "-1",   true, false)
local CV_W   = CreateClientConVar("caliber_browser_w",         "900",  true, false)
local CV_H   = CreateClientConVar("caliber_browser_h",         "600",  true, false)
local CV_DIV = CreateClientConVar("caliber_browser_div_ratio", "0.70", true, false)

local function dprint(...)
    if DBG:GetBool() then Corpus.Log("caliber", "[Caliber_Browser]", ...) end
end

local function ResolveCategory(raw)
    if type(raw) ~= "string" or raw == "" then return "Other" end
    local phrase = language.GetPhrase(raw)
    if type(phrase) ~= "string" or phrase == "" then return raw end
    return phrase
end

-- Tabla del browser: file-local (no global suelto — contrato de namespace §3).
-- Todo el archivo la referencia como upvalue; el toolgun/panel la alcanzan vía
-- el concommand caliber_browser, no por global.
local Caliber_Browser = {}
Caliber_Browser.Frame = nil
Caliber_Browser.Catalog = {}        -- { [classname] = {class, name, category, model} }
Caliber_Browser.State = {}          -- { [classname] = "wl_user"|"bl_user"|... }
Caliber_Browser.CollapsedCats = {}  -- { [catname] = true/false }
Caliber_Browser.Selected = {}       -- { [classname] = true }
Caliber_Browser.LastClicked = nil   -- para shift-click range
Caliber_Browser.Categories = {}     -- { [catname] = DCollapsibleCategory }
Caliber_Browser.OrderedRows = {}    -- array de {class, row} en orden de pantalla, para shift-click
Caliber_Browser.Filter = {
    search = "",
    category = "All",
    base = "ALL",   -- ALL | HL2 | GMOD | VJ | DRG | ZBASE
    states = {
        wl_user = true, wl_hard = true,
        bl_user = true, bl_hard = true,
        vj_pattern = true, vj_auto = true,
        unknown = true, none = true,
    },
}
Caliber_Browser.Template = {
    head_hp_frac              = 0.30,
    arms_hp_frac              = 0.20,
    legs_hp_frac              = 0.20,
    limb_damage_transfer_head = 1.50,
    limb_damage_transfer_arms = 0.80,
    limb_damage_transfer_legs = 0.60,
    mult_head = 1.0, mult_chest = 1.0, mult_arm = 1.0, mult_leg = 1.0,
    -- Energy Shield (tab propia; viaja en el payload de Whitelist Selected solo
    -- si shield_enabled — shield_enabled es client-only, no persiste)
    shield_enabled        = false,
    shield_type           = "spartan",
    shield_max_hp         = 70,
    shield_color          = nil,   -- nil = color default del tipo
    shield_recharge_delay = 4.0,
    shield_recharge_rate  = 15,
    shield_can_regen      = true,
}
Caliber_Browser.RightPanel = nil
Caliber_Browser.CopyButton = nil
Caliber_Browser._debugged = {}   -- throttle para prints de PaintOver
Caliber_Browser.Armored = {}     -- { [classname] = bool } — tiene perfil de armadura
Caliber_Browser.ArmorEditor = {  -- template de armadura (ya no es por-NPC, es global)
    classname = nil,          -- sin uso funcional; se mantiene por compat
    profile   = {},
    dirty     = false,
}
Caliber_Browser.ArmorEditorRefresh = nil  -- función para actualizar controles del editor
Caliber_Browser.ArmorSourceLabel   = nil  -- DLabel "Copied from: X" en tab Armor
Caliber_Browser.WLSliders = {}  -- refs a sliders del tab WL para refresh in-place
Caliber_Browser._lastClickTime     = 0    -- detección de doble-click por timing
Caliber_Browser._lastClickClass    = nil

local STATUS_LABEL = {
    wl_user    = "WL",
    wl_hard    = "WL-H",
    bl_user    = "BL",
    bl_hard    = "BL-H",
    vj_pattern = "VJ",
    vj_auto    = "VJ",
    unknown    = "?",
    none       = "-",
}

local STATUS_COLOR = {
    wl_user    = Color(120, 200, 120),
    wl_hard    = Color( 90, 160,  90),
    bl_user    = Color(210,  90,  90),
    bl_hard    = Color(160,  60,  60),
    vj_pattern = Color(220, 200,  80),
    vj_auto    = Color(220, 200,  80),
    unknown    = Color(160, 160, 160),
    none       = Color(110, 110, 110),
}

local function ResolveIconPath(class, data)
    -- 1. IconOverride explícito del registro
    if data.IconOverride and data.IconOverride ~= "" then
        return data.IconOverride
    end
    -- 2. Buscar en disco las convenciones conocidas.
    -- Prioridad: .vmt (material Source nativo) > .png (convención moderna).
    -- El path devuelto va SIN extensión para .vmt y CON extensión para .png.
    local bases = {
        "vgui/entities/" .. class, -- Sentry's y packs que heredan su estructura
        "entities/" .. class,      -- HL Resurgence y otros VJ clásicos
    }
    for _, base in ipairs(bases) do
        if file.Exists("materials/" .. base .. ".vmt", "GAME") then
            return base -- sin extensión, Source resuelve el .vmt
        end
        if file.Exists("materials/" .. base .. ".png", "GAME") then
            return base .. ".png"
        end
    end
    return nil
end

-- Clasifica una entrada del catálogo por base de NPCs (para el filtro Base).
-- Se calcula UNA vez por entrada al construir el catálogo (campo entry.base).
-- Orden de chequeo: ZBase ANTES que scripted_ents (sus NPCs spawnean clases de
-- motor, no SENTs). Todo defensivo: cualquiera de las bases puede no estar montada.
-- vjList/drgList: list.Get prefetcheados por el caller (list.Get copia la tabla
-- en cada llamada — no llamarlo por fila).
local function DetectBase(class, data, vjList, drgList)
    if (istable(ZBaseNPCs) and ZBaseNPCs[class] ~= nil)
       or data.ZBaseCategory ~= nil or data.ZBaseEngineClass ~= nil then
        return "ZBASE"
    end
    if (drgList and drgList[class] ~= nil)
       or scripted_ents.IsBasedOn(class, "drgbase_nextbot") then
        return "DRG"
    end
    -- VJ: flag IsVJBaseSNPC del SENT almacenado (tabla cruda, sin herencia —
    -- puede faltar en derivados) + cadena de Base contra las DOS raíces VJ
    -- (humana y creature declaran Base="base_entity", no encadenan entre sí)
    -- + registro del spawner VJ. Tres señales redundantes, todas baratas.
    local stored = scripted_ents.GetStored(class)
    if (stored and istable(stored.t) and stored.t.IsVJBaseSNPC)
       or scripted_ents.IsBasedOn(class, "npc_vj_human_base")
       or scripted_ents.IsBasedOn(class, "npc_vj_creature_base")
       or (vjList and vjList[class] ~= nil) then
        return "VJ"
    end
    -- HL2 stock: todas las entradas de garrysmod/lua/autorun/base_npcs.lua
    -- llevan Author = "VALVe".
    if data.Author == "VALVe" then return "HL2" end
    return "GMOD"
end

local function BuildCatalog()
    local cat = {}
    local vjList  = list.Get("VJBASE_SPAWNABLE_NPC")
    local drgList = list.Get("DrGBaseNextbots")

    -- Fuente A: list.Get("NPC") - Sandbox + lo que VJ registre aqu�
    local npcs = list.Get("NPC") or {}
    for class, data in pairs(npcs) do
        if type(data) == "table" then
            cat[class] = {
                class    = class,
                name     = data.Name     or class,
                category = ResolveCategory(data.Category) or "Other",
                model    = data.Model    or nil,
                icon_path  = ResolveIconPath(class, data),
                base     = DetectBase(class, data, vjList, drgList),
            }
        end
    end

    -- Fuente C: registro interno de VJ Base si est� presente.
    -- VJ expone VJ.AddNPC que rellena list.Get("NPC") en la mayor�a de addons,
    -- pero algunos viejos usan tablas propias. Defensivo: si existe VJ.NPC_Spawner_Addons
    -- o similar, lo recorremos sin romper si no est�.
    if istable(VJ) and istable(VJ.NPC_Spawner_Addons) then
        for _, entry in pairs(VJ.NPC_Spawner_Addons) do
            if istable(entry) and entry.Class and not cat[entry.Class] then
                cat[entry.Class] = {
                    class    = entry.Class,
                    name     = entry.Name     or entry.Class,
                    category = ResolveCategory(entry.Category) or "VJ Base",
                    model    = entry.Model    or nil,
                    icon_path  = ResolveIconPath(entry.Class, entry),
                    base     = "VJ",   -- tabla interna de VJ: pertenencia directa
                }
            end
        end
    end

    return cat
end

-- Agrupa el cat�logo por categor�a y ordena alfab�ticamente dentro de cada una
local function GroupByCategory(catalog)
    local groups = {}
    for class, data in pairs(catalog) do
        local c = data.category or "Other"
        groups[c] = groups[c] or {}
        table.insert(groups[c], data)
    end
    for _, list in pairs(groups) do
        table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
    end
    -- Ordenar tambi�n los nombres de categor�a
    local catNames = {}
    for c, _ in pairs(groups) do table.insert(catNames, c) end
    table.sort(catNames)
    return groups, catNames
end

local function RowMatchesFilter(class, data, status)
    local f = Caliber_Browser.Filter
    if f.base ~= "ALL" and (data.base or "GMOD") ~= f.base then
        return false
    end
    if f.category ~= "All" and data.category ~= f.category then
        return false
    end
    if not f.states[status] then return false end
    if f.search ~= "" then
        local q = string.lower(f.search)
        local n = string.lower(data.name or "")
        local c = string.lower(class)
        if not string.find(n, q, 1, true) and not string.find(c, q, 1, true) then
            return false
        end
    end
    return true
end

local function ApplyFilter()
    if not IsValid(Caliber_Browser.Scroll) then return end
    local catVisibleCount = {}
    for class, row in pairs(Caliber_Browser.Rows or {}) do
        if IsValid(row) then
            local data = Caliber_Browser.Catalog[class]
            local status = Caliber_Browser.State[class] or "none"
            local visible = RowMatchesFilter(class, data, status)
            row:SetVisible(visible)
            if visible then
                local cat = data.category
                catVisibleCount[cat] = (catVisibleCount[cat] or 0) + 1
            end
        end
    end
    for cat, dcat in pairs(Caliber_Browser.Categories or {}) do
        if IsValid(dcat) then
            local visible = (catVisibleCount[cat] or 0) > 0
            dcat:SetVisible(visible)
            if visible and dcat:GetExpanded() then
                dcat:InvalidateLayout(true)
            end
        end
    end
    Caliber_Browser.Scroll:InvalidateLayout(true)
    local canvas = Caliber_Browser.Scroll:GetCanvas()
    if IsValid(canvas) then canvas:InvalidateLayout(true) end
end

-- Repuebla el combo de categorías mostrando solo las de la base activa del
-- filtro (o todas si base=ALL). Se llama al abrir, al cambiar de base y tras
-- un scan-world (filas nuevas pueden traer categorías nuevas).
function Caliber_Browser.RepopulateCategories()
    local combo = Caliber_Browser.CatCombo
    if not IsValid(combo) then return end
    combo:Clear()
    combo:SetValue("All categories")
    combo:AddChoice("All", "All", true)
    local base = Caliber_Browser.Filter.base or "ALL"
    local seen = {}
    for _, data in pairs(Caliber_Browser.Catalog) do
        if base == "ALL" or (data.base or "GMOD") == base then
            seen[data.category] = true
        end
    end
    local sorted = {}
    for c in pairs(seen) do sorted[#sorted + 1] = c end
    table.sort(sorted)
    for _, c in ipairs(sorted) do
        combo:AddChoice(c, c, false)
    end
end

-- Construye una fila custom para un NPC
local function BuildRow(parent, data, status)
    local row = vgui.Create("DPanel", parent)
    row:SetTall(26)
    row:Dock(TOP)
    row:DockMargin(0, 0, 0, 1)
    row.data = data
    row.status = status

    -- Fondo + placeholder gris del icono (resalta azul si está seleccionado)
    row.Paint = function(self, w, h)
        if Caliber_Browser.Selected[self.data.class] then
            surface.SetDrawColor(70, 110, 160, 255)
        else
            surface.SetDrawColor(35, 35, 35, 255)
        end
        surface.DrawRect(0, 0, w, h)
        if not self.hasIcon then
            surface.SetDrawColor(70, 70, 70, 255)
            surface.DrawRect(4, 3, 20, 20)
        end
    end

    -- Selección: click simple, ctrl+click toggle, shift+click rango
    row.OnMousePressed = function(self, code)
        if code ~= MOUSE_LEFT then return end
        local class = self.data.class
        local ctrl  = input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL)
        local shift = input.IsKeyDown(KEY_LSHIFT)   or input.IsKeyDown(KEY_RSHIFT)

        -- Doble-click: dos clicks al mismo NPC en < 0.35s → Copy Selected
        local now = SysTime()
        local isDouble = (class == Caliber_Browser._lastClickClass)
                         and (now - Caliber_Browser._lastClickTime < 0.35)
        Caliber_Browser._lastClickTime  = now
        Caliber_Browser._lastClickClass = class
        if isDouble and not ctrl and not shift then
            Caliber_Browser.CopyFromClass(class)
            return
        end

        if shift and Caliber_Browser.LastClicked then
            local inRange = false
            local a, b = Caliber_Browser.LastClicked, class
            for _, entry in ipairs(Caliber_Browser.OrderedRows) do
                if IsValid(entry.row) and entry.row:IsVisible() then
                    if entry.class == a or entry.class == b then
                        Caliber_Browser.Selected[entry.class] = true
                        if a == b then break end
                        inRange = not inRange
                        if not inRange then break end
                    elseif inRange then
                        Caliber_Browser.Selected[entry.class] = true
                    end
                end
            end
        elseif ctrl then
            Caliber_Browser.Selected[class] = not Caliber_Browser.Selected[class] or nil
            Caliber_Browser.LastClicked = class
        else
            Caliber_Browser.Selected = {}
            Caliber_Browser.Selected[class] = true
            Caliber_Browser.LastClicked = class
        end
        Caliber_Browser.UpdateSelectionCount()
    end

    -- Texto pintado por encima del ícono hijo
    row.PaintOver = function(self, w, h)
        if DBG:GetBool() and not Caliber_Browser._debugged[self.data.class] then
            Caliber_Browser._debugged[self.data.class] = true
            if self.status == "wl_user" then
                local wl = Caliber_Browser.Whitelist and Caliber_Browser.Whitelist[self.data.class]
                dprint("paint wl_user", self.data.class,
                    "| Whitelist=", Caliber_Browser.Whitelist and "set" or "nil",
                    "| entry=", tostring(wl))
            end
        end
        surface.SetFont("DermaDefault")
        surface.SetTextColor(220, 220, 220)
        surface.SetTextPos(32, 6)
        surface.DrawText(string.sub(self.data.name or "?", 1, 26))

        surface.SetTextColor(170, 170, 170)
        surface.SetTextPos(210, 6)
        surface.DrawText(string.sub(self.data.class or "?", 1, 24))

        local col = STATUS_COLOR[self.status] or STATUS_COLOR.none
        local lbl = STATUS_LABEL[self.status] or "-"
        surface.SetFont("DermaDefaultBold")
        surface.SetTextColor(col.r, col.g, col.b, 255)
        surface.SetTextPos(390, 6)
        surface.DrawText(lbl)

        -- Indicador de perfil de armadura (columna Arm)
        if Caliber_Browser.Armored[self.data.class] then
            surface.SetFont("DermaDefaultBold")
            surface.SetTextColor(100, 180, 255, 255)
            surface.SetTextPos(425, 6)
            surface.DrawText("[ARM]")
        end

        -- Multiplicadores de zona (columna H/C/A/L), solo si es wl_user
        -- Muestra 1.0 por defecto cuando no hay override guardado (dmg_mult no persiste si todo es 1.0)
        if self.status == "wl_user" then
            local wl = Caliber_Browser.Whitelist and Caliber_Browser.Whitelist[self.data.class]
            local m  = (type(wl) == "table" and type(wl.dmg_mult) == "table") and wl.dmg_mult or {}
            local txt = string.format("%.1f/%.1f/%.1f/%.1f",
                m.head or 1.0, m.chest or 1.0, m.arm or 1.0, m.leg or 1.0)
            surface.SetFont("DermaDefault")
            surface.SetTextColor(200, 200, 200, 255)
            surface.SetTextPos(465, 6)
            surface.DrawText(txt)
        end

        -- Indicador de escudo de energía (columna Shd): el dato ya viene completo
        -- en el cache del whitelist (corpus_caliber_send_lists) — cero red extra
        local wls = Caliber_Browser.Whitelist and Caliber_Browser.Whitelist[self.data.class]
        if type(wls) == "table" and wls.shield_type then
            surface.SetFont("DermaDefaultBold")
            surface.SetTextColor(120, 220, 255, 255)
            surface.SetTextPos(555, 6)
            surface.DrawText("[SHD]")
        end
    end

    -- Icono: icon_path (IconOverride o convención VJ) > SpawnIcon del modelo > placeholder
    if data.icon_path then
        local img = vgui.Create("DImage", row)
        img:SetPos(4, 3)
        img:SetSize(20, 20)
        img:SetImage(data.icon_path)
        img:SetMouseInputEnabled(false)
        row.hasIcon = true
    elseif data.model and data.model ~= "" then
        local icon = vgui.Create("SpawnIcon", row)
        icon:SetPos(4, 3)
        icon:SetSize(20, 20)
        icon:SetModel(data.model)
        icon:SetMouseInputEnabled(false)
        icon.DoClick = function() end
        icon.OpenMenu = function() end
        row.hasIcon = true
    end

    return row
end


-- Renderiza el acorde�n completo dentro de un scroll
local function RenderCatalog(scroll)
    -- Si ya están construidas las filas, solo actualiza estados
    if Caliber_Browser.RowsBuilt then
        for class, row in pairs(Caliber_Browser.Rows or {}) do
            if IsValid(row) then
                row.status = Caliber_Browser.State[class] or "none"
            end
        end
        scroll:InvalidateLayout(true)
        return
    end

    scroll:Clear()
    Caliber_Browser.Rows = {}
    Caliber_Browser.Categories = {}
    Caliber_Browser.OrderedRows = {}

    local groups, catNames = GroupByCategory(Caliber_Browser.Catalog)

    for _, catName in ipairs(catNames) do
        local dcat = vgui.Create("DCollapsibleCategory", scroll)
        dcat:Dock(TOP)
        dcat:DockMargin(0, 0, 0, 2)
        dcat:SetLabel(catName .. "  (" .. #groups[catName] .. ")")
        dcat:SetExpanded(not Caliber_Browser.CollapsedCats[catName])
        Caliber_Browser.Categories[catName] = dcat

        local body = vgui.Create("DPanel", dcat)
        body:Dock(TOP)
        body.Paint = function() end
        dcat:SetContents(body)

        for _, data in ipairs(groups[catName]) do
            local status = Caliber_Browser.State[data.class] or "none"
            local row = BuildRow(body, data, status)
            Caliber_Browser.Rows[data.class] = row
            table.insert(Caliber_Browser.OrderedRows, {class = data.class, row = row})
        end

        dcat.OnToggle = function(self, expanded)
            Caliber_Browser.CollapsedCats[catName] = not expanded
        end
    end

    Caliber_Browser.RowsBuilt = true
end

-- Net: recibir estados del server y re-renderizar
net.Receive("corpus_caliber_catalog_state", function()
    local count = net.ReadUInt(16)
    local order = Caliber_Browser._stateOrder or {}
    for i = 1, count do
        local status  = net.ReadString()
        local armored = net.ReadBool()
        local class   = order[i]
        if class then
            Caliber_Browser.State[class]   = status
            Caliber_Browser.Armored[class] = armored
        end
    end
    dprint("catalog_state received | count=", count)
    if IsValid(Caliber_Browser.Frame) and IsValid(Caliber_Browser.Scroll) then
        RenderCatalog(Caliber_Browser.Scroll)
    end
end)

-- Recibe perfil de armadura de una clase desde el server (respuesta a request o ACK de save)
net.Receive("corpus_caliber_armor_data", function()
    local classname = net.ReadString()
    local profile   = net.ReadTable() or {}
    dprint("corpus_caliber_armor_data received | class=", classname, "| zones=",
        profile.zones and table.Count(profile.zones) or 0)
    Caliber_Browser.ArmorEditor.classname = classname
    Caliber_Browser.ArmorEditor.profile   = profile
    Caliber_Browser.ArmorEditor.dirty     = false
    if Caliber_Browser.ArmorEditorRefresh then
        Caliber_Browser.ArmorEditorRefresh()
    end
end)

-- Escucha el hook que el stool dispara al recibir corpus_caliber_send_lists.
-- Usar hook en lugar de un segundo net.Receive evita que ambos se pisen.
hook.Add("Caliber_ListsUpdated", "Caliber_Browser_SyncLists", function()
    local t = (CALIBER and CALIBER.ClientLists) or {}
    Caliber_Browser.Whitelist = t.whitelist or {}
    Caliber_Browser.Blacklist = t.blacklist or {}
    dprint("Caliber_ListsUpdated | wl=", table.Count(Caliber_Browser.Whitelist),
        "| bl=", table.Count(Caliber_Browser.Blacklist))
    if IsValid(Caliber_Browser.Frame) then
        Caliber_Browser.RequestState()
        if IsValid(Caliber_Browser.Scroll) then
            Caliber_Browser.Scroll:InvalidateLayout(true)
        end
    end
end)

function Caliber_Browser.RequestState()
    local classnames = {}
    for class, _ in pairs(Caliber_Browser.Catalog) do
        table.insert(classnames, class)
    end
    Caliber_Browser._stateOrder = classnames  -- orden para zippear la respuesta
    net.Start("corpus_caliber_request_catalog_state")
    net.WriteTable(classnames)
    net.SendToServer()
end

-- Constantes locales del editor de armadura
local ZONE_LIST = {
    { hg = 1, label = "HEAD"      },
    { hg = 2, label = "CHEST"     },
    { hg = 3, label = "STOMACH"   },
    { hg = 4, label = "LEFT ARM"  },
    { hg = 5, label = "RIGHT ARM" },
    { hg = 6, label = "LEFT LEG"  },
    { hg = 7, label = "RIGHT LEG" },
}

local MAT_ABBR = {
    aramid             = "AR",
    titanium           = "TI",
    ceramic            = "CE",
    poly_ceramic       = "PC",
    nano_titanium      = "NT",
    electrified_aramid = "EA",
    m_stf              = "MS",
    uranium_matrix     = "UM",
}

local ZONE_DEFAULTS = { class = 3, dur_max = 80, material = "aramid" }
local MAT_LIST = {
    "aramid", "titanium", "ceramic", "poly_ceramic",
    "nano_titanium", "electrified_aramid", "m_stf", "uranium_matrix",
}
local MAT_DISPLAY = {
    aramid             = "Aramid",
    titanium           = "Titanium",
    ceramic            = "Ceramic",
    poly_ceramic       = "Poly Ceramic",
    nano_titanium      = "Nano Titanium",
    electrified_aramid = "Electrified Aramid",
    m_stf              = "M-STF Fluid",
    uranium_matrix     = "Uranium Matrix",
}

-- Forward declaration: BuildWLTab referencia BuildRightPanel (Copy/Reset) antes de
-- su definición léxica. Sin esto el nombre bindea a global nil y crashea al usarse.
local BuildRightPanel

-- Forward declaration: BuildArmorTab estiliza sus DSlider con StyleManualSlider,
-- que se define léxicamente más abajo (junto a Weapons/Scavenger). Sin este forward
-- decl el nombre bindea a global nil dentro del tab Armor.
local StyleManualSlider

-- Copia armor (async) + limbs (sync desde cache WL) de una clase al template.
-- Doble-click en una fila llama a esta función. También la usa el botón Copy Selected.
function Caliber_Browser.CopyFromClass(classname)
    if not classname or classname == "" then return end

    -- Limbs: copiar del cache de whitelist si existe
    local wl = Caliber_Browser.Whitelist and Caliber_Browser.Whitelist[classname]
    if type(wl) == "table" then
        local t = Caliber_Browser.Template
        if wl.head_hp_frac              then t.head_hp_frac              = wl.head_hp_frac              end
        if wl.arms_hp_frac              then t.arms_hp_frac              = wl.arms_hp_frac              end
        if wl.legs_hp_frac              then t.legs_hp_frac              = wl.legs_hp_frac              end
        if wl.limb_damage_transfer_head then t.limb_damage_transfer_head = wl.limb_damage_transfer_head end
        if wl.limb_damage_transfer_arms then t.limb_damage_transfer_arms = wl.limb_damage_transfer_arms end
        if wl.limb_damage_transfer_legs then t.limb_damage_transfer_legs = wl.limb_damage_transfer_legs end
        if type(wl.dmg_mult) == "table" then
            t.mult_head  = wl.dmg_mult.head  or 1.0
            t.mult_chest = wl.dmg_mult.chest or 1.0
            t.mult_arm   = wl.dmg_mult.arm   or 1.0
            t.mult_leg   = wl.dmg_mult.leg   or 1.0
        end
        -- Energy shield: copiar solo lo que el entry trae (los valores numéricos
        -- del template no se resetean); el flag enabled sí refleja al NPC copiado
        if wl.shield_type then
            t.shield_enabled = true
            t.shield_type    = wl.shield_type
            if wl.shield_max_hp         then t.shield_max_hp         = wl.shield_max_hp         end
            if wl.shield_recharge_delay then t.shield_recharge_delay = wl.shield_recharge_delay end
            if wl.shield_recharge_rate  then t.shield_recharge_rate  = wl.shield_recharge_rate  end
            if wl.shield_can_regen ~= nil then t.shield_can_regen = wl.shield_can_regen end
            t.shield_color = type(wl.shield_color) == "table" and table.Copy(wl.shield_color) or nil
        else
            t.shield_enabled = false
        end
    end

    -- Armor: async — corpus_caliber_armor_data receive actualiza ArmorEditor.profile y refresca
    net.Start("corpus_caliber_request_armor")
    net.WriteString(classname)
    net.SendToServer()

    -- Actualizar label de fuente si el panel está visible
    if IsValid(Caliber_Browser.ArmorSourceLabel) then
        Caliber_Browser.ArmorSourceLabel:SetText("Copied from: " .. classname)
        Caliber_Browser.ArmorSourceLabel:SetTextColor(Color(170, 210, 170))
    end

    -- Refrescar sliders WL in-place (sin reconstruir el panel ni destruir el sheet)
    for key, slider in pairs(Caliber_Browser.WLSliders) do
        if IsValid(slider) then
            slider:SetValue(Caliber_Browser.Template[key])
        end
    end
    -- Refrescar controles del tab Energy Shield in-place
    if Caliber_Browser.ShieldTabRefresh then Caliber_Browser.ShieldTabRefresh() end
end

local function BuildArmorTab(parent)
    -- ── Source label (unchanged — CopyFromClass and Reset All write to this) ──
    local srcLabel = vgui.Create("DLabel", parent)
    srcLabel:Dock(TOP)
    srcLabel:DockMargin(4, 6, 4, 0)
    srcLabel:SetText("Armor Template  (use Copy Selected or double-click a NPC)")
    srcLabel:SetFont("DermaDefault")
    srcLabel:SetTextColor(Color(130, 130, 130))
    Caliber_Browser.ArmorSourceLabel = srcLabel

    -- ── Local state ───────────────────────────────────────────────────────────
    local refreshing   = false
    local selectedZone = "2"   -- CHEST selected by default
    local setEditor            -- forward declaration (used in silPanel before definition)

    -- Zone rects in a 130×207 px panel (0.65 scale of the 200×320 prototype viewBox)
    local ZONE_RECTS = {
        ["1"] = { x = 51, y = 5,   w = 28, h = 35 },  -- HEAD
        ["2"] = { x = 42, y = 48,  w = 46, h = 38 },  -- CHEST
        ["3"] = { x = 44, y = 87,  w = 42, h = 27 },  -- STOMACH
        ["4"] = { x = 26, y = 49,  w = 13, h = 66 },  -- LEFT ARM
        ["5"] = { x = 91, y = 49,  w = 13, h = 66 },  -- RIGHT ARM
        ["6"] = { x = 43, y = 116, w = 21, h = 86 },  -- LEFT LEG
        ["7"] = { x = 66, y = 116, w = 21, h = 86 },  -- RIGHT LEG
    }
    -- Wide zones can fit two text lines (class + material abbr)
    local ZONE_WIDE = { ["1"] = true, ["2"] = true, ["3"] = true,
                        ["6"] = true, ["7"] = true }
    local ZONE_LABELS = {
        ["1"] = "HEAD",    ["2"] = "CHEST",   ["3"] = "STOMACH",
        ["4"] = "L.ARM",   ["5"] = "R.ARM",
        ["6"] = "L.LEG",   ["7"] = "R.LEG",
    }

    -- Durability → color: morado (low) → azul (mid) → verde (max/healthy)
    local function DurColor(d)
        local p = { 139, 127, 232 }
        local b = { 55,  138, 221 }
        local g = { 63,  185, 80  }
        local function lerp3(a, c, t)
            return Color(
                math.floor(a[1] + (c[1] - a[1]) * t),
                math.floor(a[2] + (c[2] - a[2]) * t),
                math.floor(a[3] + (c[3] - a[3]) * t)
            )
        end
        d = math.Clamp(d or 10, 10, 250)
        if d <= 125 then return lerp3(p, b, (d - 10) / 115)
                    else return lerp3(b, g, (d - 125) / 125) end
    end

    local function markDirty()
        Caliber_Browser.ArmorEditor.dirty = true
    end

    -- ── Info popup ────────────────────────────────────────────────────────────
    local CLS_TRIVIA = {
        [1] = "Threshold 10. Stops basic pistol rounds (9mm Makarov). Any rifle penetrates.",
        [2] = "Threshold 20. Stops 9mm Luger FMJ, heavy buckshot.  ≈ NIJ IIA.",
        [3] = "Threshold 30. Stops light rifle rounds (5.45 PS, 7.62×39 PS).  ≈ NIJ IIIA–III.",
        [4] = "Threshold 40. Stops standard rifle (5.56 M855, 7.62×39 HP).",
        [5] = "Threshold 50. Stops M855A1, 7.62×39 BP (steel core).",
        [6] = "Threshold 60. Stops heavy AP: .338 Lapua, 7.62×51 M61.  ≈ NIJ IV.",
        [7] = "Threshold 70. Upper limit of the standard EFT arsenal.",
        [8] = "Threshold 80. No standard round penetrates — boss NPCs / power armor only.",
    }
    -- img: path passed to DImage:SetImage() — relative to materials/, no extension.
    -- Files expected at materials/ads/mat_<key>.png  (substitute .vmt when ready).
    local MAT_TRIVIA = {
        aramid             = { name = "Aramid (Kevlar)",      img = "ads/mat_aramid",
            body = "Textile plate. Very durable, repairs easily. Good blunt damage on block.\ncoefDestruc 0.25  ·  blunt 0.30" },
        titanium           = { name = "Titanium",             img = "ads/mat_titanium",
            body = "Balanced metal plate. Middle ground between durability and blunt transfer.\ncoefDestruc 0.50  ·  blunt 0.20" },
        ceramic            = { name = "Ceramic",              img = "ads/mat_ceramic",
            body = "Absorbs the first hit very well, but shatters in 2–3 impacts. Low blunt.\ncoefDestruc 0.85  ·  blunt 0.15" },
        poly_ceramic       = { name = "Poly Ceramic",         img = "ads/mat_poly_ceramic",
            body = "Sci-fi: reactive energy field (HEV charged). Near-indestructible, near-zero blunt.\ncoefDestruc 0.10  ·  blunt 0.05" },
        nano_titanium      = { name = "Nano Titanium",        img = "ads/mat_nano_titanium",
            body = "Sci-fi: hydrostatic gel. Completely nullifies blunt trauma on block.\ncoefDestruc 0.35  ·  blunt 0.00" },
        electrified_aramid = { name = "Electrified Aramid",   img = "ads/mat_electrified_aramid",
            body = "HECU PCV. Aramid base with an electrified outer layer.\ncoefDestruc 0.25  ·  blunt 0.30" },
        m_stf              = { name = "M-STF Fluid",          img = "ads/mat_m_stf",
            body = "Sci-fi: non-Newtonian fluid. Very high blunt without a rigid plate — hardens on impact.\ncoefDestruc 0.15  ·  blunt 0.45" },
        uranium_matrix     = { name = "Uranium Matrix",       img = "ads/mat_uranium_matrix",
            body = "Sci-fi: extremely high class, but cracks quickly once breached.\ncoefDestruc 0.75  ·  blunt 0.10" },
    }

    local function ShowInfoPopup(title, body, imgPath)
        local hasImg = (imgPath ~= nil and imgPath ~= "")
        local fw, fh = 260, hasImg and 185 or 110
        local f = vgui.Create("DFrame")
        f:SetSize(fw, fh)
        f:Center()
        f:SetTitle(title)
        f:SetDeleteOnClose(true)
        f:SetDraggable(true)
        f:SetSizable(false)
        f:MakePopup()

        if hasImg then
            local img = vgui.Create("DImage", f)
            img:SetPos(8, 30)
            img:SetSize(fw - 16, 75)
            img:SetImage(imgPath .. ".png")
            img:SetKeepAspect(true)

            local lbl = vgui.Create("DLabel", f)
            lbl:SetPos(8, 112)
            lbl:SetSize(fw - 16, fh - 120)
            lbl:SetText(body)
            lbl:SetWrap(true)
            lbl:SetAutoStretchVertical(true)
            lbl:SetFont("DermaDefault")
        else
            local lbl = vgui.Create("DLabel", f)
            lbl:SetPos(8, 30)
            lbl:SetSize(fw - 16, fh - 38)
            lbl:SetText(body)
            lbl:SetWrap(true)
            lbl:SetAutoStretchVertical(true)
            lbl:SetFont("DermaDefault")
        end
    end

    -- ── Silhouette panel ──────────────────────────────────────────────────────
    local silContainer = vgui.Create("DPanel", parent)
    silContainer:Dock(TOP)
    silContainer:SetTall(215)
    silContainer:DockMargin(0, 4, 0, 4)
    silContainer.Paint = function() end

    local silPanel = vgui.Create("DPanel", silContainer)
    silPanel:SetSize(130, 207)
    silPanel:SetMouseInputEnabled(true)
    silContainer.PerformLayout = function(self, w, h)
        silPanel:SetPos(math.floor((w - 130) / 2), 0)
    end

    silPanel.Paint = function(self, w, h)
        local profile = Caliber_Browser.ArmorEditor.profile or {}
        local zones   = type(profile.zones) == "table" and profile.zones or {}

        draw.RoundedBox(3, 0, 0, w, h, Color(20, 20, 20))
        -- Neck connector (visual only, no zone)
        draw.RoundedBox(2, 60, 39, 10, 9, Color(30, 30, 30))

        surface.SetFont("DermaDefaultBold")
        for hgKey, rect in pairs(ZONE_RECTS) do
            local z   = zones[hgKey]
            local sel = (hgKey == selectedZone)
            local col = z and DurColor(z.dur_max) or Color(46, 46, 46)
            local r   = (hgKey == "1") and 14 or 4

            draw.RoundedBox(r, rect.x, rect.y, rect.w, rect.h, col)

            if sel then
                surface.SetDrawColor(239, 159, 39, 255)
                surface.DrawOutlinedRect(rect.x - 1, rect.y - 1, rect.w + 2, rect.h + 2, 2)
            end

            if z then
                local cls_txt = "C" .. (z.class or "?")
                local tw, th  = surface.GetTextSize(cls_txt)
                local cy_off  = ZONE_WIDE[hgKey] and -5 or 0
                surface.SetTextColor(255, 255, 255, 240)
                surface.SetTextPos(rect.x + math.floor((rect.w - tw) / 2),
                                   rect.y + math.floor((rect.h - th) / 2) + cy_off)
                surface.DrawText(cls_txt)

                if ZONE_WIDE[hgKey] then
                    surface.SetFont("DermaDefault")
                    local abbr   = MAT_ABBR[z.material] or "??"
                    local aw, ah = surface.GetTextSize(abbr)
                    surface.SetTextPos(rect.x + math.floor((rect.w - aw) / 2),
                                       rect.y + math.floor((rect.h - ah) / 2) + 7)
                    surface.DrawText(abbr)
                    surface.SetFont("DermaDefaultBold")
                end
            else
                surface.SetFont("DermaDefault")
                surface.SetTextColor(85, 85, 85, 255)
                local tw, th = surface.GetTextSize("\xe2\x80\x94")  -- em dash
                surface.SetTextPos(rect.x + math.floor((rect.w - tw) / 2),
                                   rect.y + math.floor((rect.h - th) / 2))
                surface.DrawText("\xe2\x80\x94")
                surface.SetFont("DermaDefaultBold")
            end
        end
    end

    silPanel.OnMouseReleased = function(self, mcode)
        if mcode ~= MOUSE_LEFT then return end
        local mx, my = self:CursorPos()
        for hgKey, rect in pairs(ZONE_RECTS) do
            if mx >= rect.x and mx < rect.x + rect.w and
               my >= rect.y and my < rect.y + rect.h then
                selectedZone = hgKey
                if setEditor then setEditor(hgKey) end
                silPanel:InvalidateLayout(true)
                return
            end
        end
    end

    -- ── Shared zone editor panel ──────────────────────────────────────────────
    local editorPanel = vgui.Create("DPanel", parent)
    editorPanel:Dock(TOP)
    editorPanel:DockMargin(4, 0, 4, 4)
    editorPanel:SetTall(142)
    editorPanel.Paint = function() end

    local zoneTitle = vgui.Create("DLabel", editorPanel)
    zoneTitle:Dock(TOP)
    zoneTitle:SetTall(18)
    zoneTitle:DockMargin(0, 2, 0, 2)
    zoneTitle:SetText("CHEST  (zone 2)")
    zoneTitle:SetFont("DermaDefaultBold")

    local zoneCB = vgui.Create("DCheckBoxLabel", editorPanel)
    zoneCB:Dock(TOP)
    zoneCB:SetTall(20)
    zoneCB:SetText("Armored")
    zoneCB:SetValue(false)

    -- Class button row
    local clsRow = vgui.Create("DPanel", editorPanel)
    clsRow:Dock(TOP)
    clsRow:SetTall(26)
    clsRow:DockMargin(0, 4, 0, 2)
    clsRow.Paint = function() end

    local clsLabel = vgui.Create("DLabel", clsRow)
    clsLabel:Dock(LEFT)
    clsLabel:SetWide(38)
    clsLabel:SetText("Class:")
    clsLabel:SetFont("DermaDefault")

    local clsInfoBtn = vgui.Create("DButton", clsRow)
    clsInfoBtn:Dock(RIGHT)
    clsInfoBtn:SetWide(22)
    clsInfoBtn:SetText("?")
    clsInfoBtn:SetFont("DermaDefaultBold")
    clsInfoBtn:SetTooltip("Class info")

    local classBtns      = {}
    local clsBtnContainer = vgui.Create("DPanel", clsRow)
    clsBtnContainer:Dock(FILL)
    clsBtnContainer:DockMargin(2, 0, 2, 0)
    clsBtnContainer.Paint = function() end
    clsBtnContainer.PerformLayout = function(self, w, h)
        local bw = math.floor(w / 8)
        for i, btn in ipairs(classBtns) do
            btn:SetPos((i - 1) * bw, 0)
            btn:SetSize(bw - 1, h)
        end
    end
    for i = 1, 8 do
        local btn = vgui.Create("DButton", clsBtnContainer)
        btn:SetText(tostring(i))
        btn:SetFont("DermaDefault")
        classBtns[i] = btn
    end

    -- Material row
    local matRow = vgui.Create("DPanel", editorPanel)
    matRow:Dock(TOP)
    matRow:SetTall(24)
    matRow:DockMargin(0, 2, 0, 2)
    matRow.Paint = function() end

    local matLabel = vgui.Create("DLabel", matRow)
    matLabel:Dock(LEFT)
    matLabel:SetWide(52)
    matLabel:SetText("Material:")
    matLabel:SetFont("DermaDefault")

    local matInfoBtn = vgui.Create("DButton", matRow)
    matInfoBtn:Dock(RIGHT)
    matInfoBtn:SetWide(22)
    matInfoBtn:SetText("?")
    matInfoBtn:SetFont("DermaDefaultBold")
    matInfoBtn:SetTooltip("Material info")

    local matCombo = vgui.Create("DComboBox", matRow)
    matCombo:Dock(FILL)
    for _, mat in ipairs(MAT_LIST) do
        matCombo:AddChoice(MAT_DISPLAY[mat] or mat, mat, mat == ZONE_DEFAULTS.material)
    end

    -- Durability row: fila manual (DNumSlider colapsa en DScrollPanel con SetTall fijo)
    local DUR_MIN, DUR_MAX = 10, 250
    local durRow = vgui.Create("DPanel", editorPanel)
    durRow:Dock(TOP)
    durRow:SetTall(20)
    durRow:DockMargin(0, 2, 0, 0)
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
    StyleManualSlider(durSlider)

    local durUpdating = false
    local function durSetValue(v)
        v = math.Clamp(math.floor(v), DUR_MIN, DUR_MAX)
        durUpdating = true
        durSlider:SetSlideX((v - DUR_MIN) / (DUR_MAX - DUR_MIN))
        durEntry:SetText(tostring(v))
        durUpdating = false
    end
    durSetValue(ZONE_DEFAULTS.dur_max)

    local function setControlsEnabled(en)
        for _, b in ipairs(classBtns) do b:SetEnabled(en) end
        matCombo:SetEnabled(en)
        durSlider:SetEnabled(en)
        durEntry:SetEnabled(en)
        clsInfoBtn:SetEnabled(en)
        matInfoBtn:SetEnabled(en)
    end
    setControlsEnabled(false)

    -- ── setEditor: load profile data for hgKey into shared controls ───────────
    setEditor = function(hgKey)
        if not IsValid(zoneTitle) then return end
        refreshing = true
        local profile = Caliber_Browser.ArmorEditor.profile or {}
        local zones   = type(profile.zones) == "table" and profile.zones or {}
        local z       = zones[hgKey]

        zoneTitle:SetText((ZONE_LABELS[hgKey] or "zone " .. hgKey) .. "  (zone " .. hgKey .. ")")
        zoneCB:SetValue(z ~= nil)
        setControlsEnabled(z ~= nil)

        local activeCls = z and (z.class or ZONE_DEFAULTS.class) or ZONE_DEFAULTS.class
        for i, btn in ipairs(classBtns) do
            local active = (i == activeCls)
            btn:SetFont(active and "DermaDefaultBold" or "DermaDefault")
            btn:SetTextColor(active and Color(255, 255, 255) or Color(180, 180, 180))
        end

        if z then
            matCombo:SetValue(MAT_DISPLAY[z.material] or z.material
                              or MAT_DISPLAY[ZONE_DEFAULTS.material])
            durSetValue(z.dur_max or ZONE_DEFAULTS.dur_max)
        else
            matCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
            durSetValue(ZONE_DEFAULTS.dur_max)
        end
        refreshing = false
    end

    -- ── Wire class buttons ────────────────────────────────────────────────────
    for i, btn in ipairs(classBtns) do
        btn.DoClick = function()
            if refreshing then return end
            local profile = Caliber_Browser.ArmorEditor.profile
            if profile.zones and profile.zones[selectedZone] then
                profile.zones[selectedZone].class = i
                for j, b in ipairs(classBtns) do
                    b:SetFont(j == i and "DermaDefaultBold" or "DermaDefault")
                    b:SetTextColor(j == i and Color(255, 255, 255) or Color(180, 180, 180))
                end
                markDirty()
                silPanel:InvalidateLayout(true)
            end
        end
    end

    clsInfoBtn.DoClick = function()
        local profile = Caliber_Browser.ArmorEditor.profile or {}
        local zones   = type(profile.zones) == "table" and profile.zones or {}
        local z       = zones[selectedZone]
        local cls     = z and z.class or ZONE_DEFAULTS.class
        ShowInfoPopup("Class " .. cls, CLS_TRIVIA[cls] or "", nil)
    end

    matInfoBtn.DoClick = function()
        local profile = Caliber_Browser.ArmorEditor.profile or {}
        local zones   = type(profile.zones) == "table" and profile.zones or {}
        local z       = zones[selectedZone]
        local matKey  = z and z.material or ZONE_DEFAULTS.material
        local tr      = MAT_TRIVIA[matKey] or {}
        ShowInfoPopup(tr.name or matKey, tr.body or "", tr.img)
    end

    -- ── Wire zone checkbox ────────────────────────────────────────────────────
    zoneCB.OnChange = function(_, val)
        if refreshing then return end
        local profile = Caliber_Browser.ArmorEditor.profile
        profile.zones = profile.zones or {}
        if val then
            profile.zones[selectedZone] = {
                class    = ZONE_DEFAULTS.class,
                dur_max  = ZONE_DEFAULTS.dur_max,
                material = ZONE_DEFAULTS.material,
            }
            setControlsEnabled(true)
            setEditor(selectedZone)
        else
            profile.zones[selectedZone] = nil
            if not next(profile.zones) then profile.zones = nil end
            setControlsEnabled(false)
        end
        markDirty()
        silPanel:InvalidateLayout(true)
    end

    matCombo.OnSelect = function(_, _, _, data)
        if refreshing then return end
        local profile = Caliber_Browser.ArmorEditor.profile
        if profile.zones and profile.zones[selectedZone] then
            profile.zones[selectedZone].material = data
            markDirty()
            silPanel:InvalidateLayout(true)
        end
    end

    durSlider.OnValueChanged = function(_, x)
        if refreshing or durUpdating then return end
        local v = math.floor(DUR_MIN + x * (DUR_MAX - DUR_MIN))
        durUpdating = true
        durEntry:SetText(tostring(v))
        durUpdating = false
        local profile = Caliber_Browser.ArmorEditor.profile
        if profile.zones and profile.zones[selectedZone] then
            profile.zones[selectedZone].dur_max = v
            markDirty()
            silPanel:InvalidateLayout(true)
        end
    end

    durEntry.OnEnter = function(self)
        if refreshing then return end
        local v = math.Clamp(tonumber(self:GetText()) or DUR_MIN, DUR_MIN, DUR_MAX)
        durSetValue(v)
        local profile = Caliber_Browser.ArmorEditor.profile
        if profile.zones and profile.zones[selectedZone] then
            profile.zones[selectedZone].dur_max = v
            markDirty()
            silPanel:InvalidateLayout(true)
        end
    end
    durEntry.OnLostFocus = durEntry.OnEnter

    -- ── Separator ─────────────────────────────────────────────────────────────
    local sep = vgui.Create("DPanel", parent)
    sep:Dock(TOP)
    sep:SetTall(6)
    sep.Paint = function(self, w, h)
        surface.SetDrawColor(70, 70, 70)
        surface.DrawRect(0, 3, w, 1)
    end

    -- ── Fallback generic block ────────────────────────────────────────────────
    local fgPanel = vgui.Create("DPanel", parent)
    fgPanel:Dock(TOP)
    fgPanel:DockMargin(4, 0, 4, 4)
    fgPanel:SetTall(118)
    fgPanel.Paint = function() end

    local fgCB = vgui.Create("DCheckBoxLabel", fgPanel)
    fgCB:Dock(TOP)
    fgCB:SetTall(20)
    fgCB:SetText("Fallback / GENERIC  (non-humanoid NPCs or unmatched hitgroups)")
    fgCB:SetValue(false)

    local fgClsRow = vgui.Create("DPanel", fgPanel)
    fgClsRow:Dock(TOP)
    fgClsRow:SetTall(26)
    fgClsRow:DockMargin(0, 4, 0, 2)
    fgClsRow.Paint = function() end

    local fgClsLabel = vgui.Create("DLabel", fgClsRow)
    fgClsLabel:Dock(LEFT)
    fgClsLabel:SetWide(38)
    fgClsLabel:SetText("Class:")
    fgClsLabel:SetFont("DermaDefault")

    local fgClassBtns     = {}
    local fgBtnContainer  = vgui.Create("DPanel", fgClsRow)
    fgBtnContainer:Dock(FILL)
    fgBtnContainer:DockMargin(2, 0, 2, 0)
    fgBtnContainer.Paint = function() end
    fgBtnContainer.PerformLayout = function(self, w, h)
        local bw = math.floor(w / 8)
        for i, btn in ipairs(fgClassBtns) do
            btn:SetPos((i - 1) * bw, 0)
            btn:SetSize(bw - 1, h)
        end
    end
    for i = 1, 8 do
        local btn = vgui.Create("DButton", fgBtnContainer)
        btn:SetText(tostring(i))
        btn:SetFont("DermaDefault")
        fgClassBtns[i] = btn
    end

    local fgMatRow = vgui.Create("DPanel", fgPanel)
    fgMatRow:Dock(TOP)
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

    -- Durability row fallback: misma fila manual que la zona (DUR_MIN/DUR_MAX ya definidos)
    local fgDurRow = vgui.Create("DPanel", fgPanel)
    fgDurRow:Dock(TOP)
    fgDurRow:SetTall(20)
    fgDurRow:DockMargin(0, 2, 0, 0)
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
    StyleManualSlider(fgDurSlider)

    local fgDurUpdating = false
    local function fgDurSetValue(v)
        v = math.Clamp(math.floor(v), DUR_MIN, DUR_MAX)
        fgDurUpdating = true
        fgDurSlider:SetSlideX((v - DUR_MIN) / (DUR_MAX - DUR_MIN))
        fgDurEntry:SetText(tostring(v))
        fgDurUpdating = false
    end
    fgDurSetValue(ZONE_DEFAULTS.dur_max)

    local function setFGEnabled(en)
        for _, b in ipairs(fgClassBtns) do b:SetEnabled(en) end
        fgMatCombo:SetEnabled(en)
        fgDurSlider:SetEnabled(en)
        fgDurEntry:SetEnabled(en)
    end
    setFGEnabled(false)

    fgCB.OnChange = function(_, val)
        if refreshing then return end
        setFGEnabled(val)
        local profile = Caliber_Browser.ArmorEditor.profile
        if val then
            profile.fallback_generic = {
                class    = ZONE_DEFAULTS.class,
                dur_max  = ZONE_DEFAULTS.dur_max,
                material = ZONE_DEFAULTS.material,
            }
            for j, b in ipairs(fgClassBtns) do
                b:SetFont(j == ZONE_DEFAULTS.class and "DermaDefaultBold" or "DermaDefault")
                b:SetTextColor(j == ZONE_DEFAULTS.class and Color(255,255,255) or Color(180,180,180))
            end
            fgMatCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
            fgDurSetValue(ZONE_DEFAULTS.dur_max)
        else
            profile.fallback_generic = nil
        end
        markDirty()
    end

    for i, btn in ipairs(fgClassBtns) do
        btn.DoClick = function()
            if refreshing then return end
            local profile = Caliber_Browser.ArmorEditor.profile
            if profile.fallback_generic then
                profile.fallback_generic.class = i
                for j, b in ipairs(fgClassBtns) do
                    b:SetFont(j == i and "DermaDefaultBold" or "DermaDefault")
                    b:SetTextColor(j == i and Color(255,255,255) or Color(180,180,180))
                end
                markDirty()
            end
        end
    end

    fgMatCombo.OnSelect = function(_, _, _, data)
        if refreshing then return end
        local profile = Caliber_Browser.ArmorEditor.profile
        if profile.fallback_generic then
            profile.fallback_generic.material = data
            markDirty()
        end
    end

    fgDurSlider.OnValueChanged = function(_, x)
        if refreshing or fgDurUpdating then return end
        local v = math.floor(DUR_MIN + x * (DUR_MAX - DUR_MIN))
        fgDurUpdating = true
        fgDurEntry:SetText(tostring(v))
        fgDurUpdating = false
        local profile = Caliber_Browser.ArmorEditor.profile
        if profile.fallback_generic then
            profile.fallback_generic.dur_max = v
            markDirty()
        end
    end

    fgDurEntry.OnEnter = function(self)
        if refreshing then return end
        local v = math.Clamp(tonumber(self:GetText()) or DUR_MIN, DUR_MIN, DUR_MAX)
        fgDurSetValue(v)
        local profile = Caliber_Browser.ArmorEditor.profile
        if profile.fallback_generic then
            profile.fallback_generic.dur_max = v
            markDirty()
        end
    end
    fgDurEntry.OnLostFocus = fgDurEntry.OnEnter

    -- ── ArmorEditorRefresh — called by net.Receive("corpus_caliber_armor_data") and Reset All ──
    Caliber_Browser.ArmorEditorRefresh = function()
        refreshing = true
        local profile = Caliber_Browser.ArmorEditor.profile or {}
        local zones   = type(profile.zones) == "table" and profile.zones or {}
        local fg      = profile.fallback_generic

        -- Refresh shared editor for currently selected zone
        if IsValid(zoneTitle) then
            local z = zones[selectedZone]
            zoneTitle:SetText((ZONE_LABELS[selectedZone] or "zone " .. selectedZone)
                              .. "  (zone " .. selectedZone .. ")")
            zoneCB:SetValue(z ~= nil)
            setControlsEnabled(z ~= nil)

            local activeCls = z and (z.class or ZONE_DEFAULTS.class) or ZONE_DEFAULTS.class
            for i, btn in ipairs(classBtns) do
                local active = (i == activeCls)
                btn:SetFont(active and "DermaDefaultBold" or "DermaDefault")
                btn:SetTextColor(active and Color(255,255,255) or Color(180,180,180))
            end

            if z then
                matCombo:SetValue(MAT_DISPLAY[z.material] or z.material
                                  or MAT_DISPLAY[ZONE_DEFAULTS.material])
                durSetValue(z.dur_max or ZONE_DEFAULTS.dur_max)
            else
                matCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
                durSetValue(ZONE_DEFAULTS.dur_max)
            end
        end

        -- Refresh fallback_generic block
        if IsValid(fgCB) then
            fgCB:SetValue(fg ~= nil)
            setFGEnabled(fg ~= nil)

            local fgCls = fg and (fg.class or ZONE_DEFAULTS.class) or ZONE_DEFAULTS.class
            for i, b in ipairs(fgClassBtns) do
                local active = (i == fgCls)
                b:SetFont(active and "DermaDefaultBold" or "DermaDefault")
                b:SetTextColor(active and Color(255,255,255) or Color(180,180,180))
            end

            if fg then
                fgMatCombo:SetValue(MAT_DISPLAY[fg.material] or fg.material
                                    or MAT_DISPLAY[ZONE_DEFAULTS.material])
                fgDurSetValue(fg.dur_max or ZONE_DEFAULTS.dur_max)
            else
                fgMatCombo:SetValue(MAT_DISPLAY[ZONE_DEFAULTS.material])
                fgDurSetValue(ZONE_DEFAULTS.dur_max)
            end
        end

        if IsValid(silPanel) then silPanel:InvalidateLayout(true) end
        refreshing = false
    end
end

local function BuildWLTab(parent)
    local function header(text)
        local h = vgui.Create("DLabel", parent)
        h:Dock(TOP)
        h:DockMargin(4, 8, 4, 2)
        h:SetText(text)
        h:SetFont("DermaDefaultBold")
    end

    local function MakeSlider(lbl, key, min, max, dec)
        local s = vgui.Create("DNumSlider", parent)
        s:Dock(TOP)
        s:DockMargin(4, 2, 4, 2)
        s:SetText(lbl)
        s:SetMin(min) s:SetMax(max) s:SetDecimals(dec)
        s:SetDefaultValue(Caliber_Browser.Template[key])
        s:SetValue(Caliber_Browser.Template[key])
        timer.Simple(0, function() if IsValid(s) then s:SetValue(Caliber_Browser.Template[key]) end end)
        s.OnValueChanged = function(_, v) Caliber_Browser.Template[key] = v end
        Caliber_Browser.WLSliders[key] = s  -- ref para refresh in-place desde CopyFromClass
        return s
    end

    header("Limb HP Pools  (fraction of NPC base HP, 0-2)")
    MakeSlider("Head HP Frac",  "head_hp_frac",  0, 2, 2)
    MakeSlider("Arms HP Frac",  "arms_hp_frac",  0, 2, 2)
    MakeSlider("Legs HP Frac",  "legs_hp_frac",  0, 2, 2)

    header("Damage Transfer  (to NPC HP when pool empties, 0-3)")
    MakeSlider("Head Transfer", "limb_damage_transfer_head", 0, 3, 2)
    MakeSlider("Arms Transfer", "limb_damage_transfer_arms", 0, 3, 2)
    MakeSlider("Legs Transfer", "limb_damage_transfer_legs", 0, 3, 2)

    header("Damage Multipliers  (1.0 = neutral)")
    MakeSlider("Head mult",  "mult_head",  0, 5, 2)
    MakeSlider("Chest mult", "mult_chest", 0, 5, 2)
    MakeSlider("Arm mult",   "mult_arm",   0, 5, 2)
    MakeSlider("Leg mult",   "mult_leg",   0, 5, 2)
end

local function BuildGeneralTab(parent)
    local function header(text)
        local h = vgui.Create("DLabel", parent)
        h:Dock(TOP)
        h:DockMargin(4, 8, 4, 2)
        h:SetText(text)
        h:SetFont("DermaDefaultBold")
    end

    local function actionButton(label, color, fn)
        local b = vgui.Create("DButton", parent)
        b:Dock(TOP)
        b:DockMargin(4, 2, 4, 2)
        b:SetTall(24)
        b:SetText(label)
        if color then b:SetTextColor(color) end
        b.DoClick = fn
        return b
    end

    header("Actions")

    actionButton("Whitelist Selected", Color(120, 200, 120), function()
        local classes = {}
        for c in pairs(Caliber_Browser.Selected) do table.insert(classes, c) end
        if #classes == 0 then return end
        local doIt = function()
            -- Armor batch (perfil vacío = borrar armadura en esas clases)
            net.Start("corpus_caliber_save_armor_batch")
            net.WriteTable(classes)
            net.WriteTable(Caliber_Browser.ArmorEditor.profile or {})
            net.SendToServer()
            -- Limbs whitelist
            local t = Caliber_Browser.Template
            local payload = {
                head_hp_frac              = t.head_hp_frac,
                arms_hp_frac              = t.arms_hp_frac,
                legs_hp_frac              = t.legs_hp_frac,
                limb_damage_transfer_head = t.limb_damage_transfer_head,
                limb_damage_transfer_arms = t.limb_damage_transfer_arms,
                limb_damage_transfer_legs = t.limb_damage_transfer_legs,
                dmg_mult = {
                    head  = t.mult_head,  chest = t.mult_chest,
                    arm   = t.mult_arm,   leg   = t.mult_leg,
                },
            }
            -- Energy shield: solo si está habilitado en su tab. Sin habilitar,
            -- el entry se reemplaza SIN campos shield_* → whitelistear de nuevo
            -- LIMPIA el escudo de esas clases (el label del tab lo advierte)
            if t.shield_enabled then
                payload.shield_type           = t.shield_type
                payload.shield_max_hp         = t.shield_max_hp
                payload.shield_recharge_delay = t.shield_recharge_delay
                payload.shield_recharge_rate  = t.shield_recharge_rate
                payload.shield_can_regen      = t.shield_can_regen
                if type(t.shield_color) == "table" then
                    payload.shield_color = t.shield_color
                end
            end
            net.Start("corpus_caliber_modify_list")
            net.WriteString("wl_add_batch")
            net.WriteTable(payload)
            net.WriteTable(classes)
            net.SendToServer()
        end
        if #classes > 10 then
            Derma_Query("Whitelist " .. #classes .. " NPCs with current template?",
                "Caliber Browser", "Yes", doIt, "No")
        else
            doIt()
        end
    end)

    actionButton("Blacklist Selected", Color(210, 120, 120), function()
        local classes = {}
        for c in pairs(Caliber_Browser.Selected) do table.insert(classes, c) end
        if #classes == 0 then return end
        local doIt = function()
            net.Start("corpus_caliber_modify_list")
            net.WriteString("bl_add_batch")
            net.WriteTable(classes)
            net.SendToServer()
        end
        if #classes > 10 then
            Derma_Query("Blacklist " .. #classes .. " NPCs?",
                "Caliber Browser", "Yes", doIt, "No")
        else
            doIt()
        end
    end)

    actionButton("Remove Selected", nil, function()
        local classes = {}
        for c in pairs(Caliber_Browser.Selected) do table.insert(classes, c) end
        if #classes == 0 then return end
        local doIt = function()
            local toRemove = {}
            for _, class in ipairs(classes) do
                local st = Caliber_Browser.State[class]
                if st == "wl_user" or st == "bl_user" then
                    table.insert(toRemove, class)
                end
            end
            if #toRemove == 0 then return end
            net.Start("corpus_caliber_modify_list")
            net.WriteString("del_batch")
            net.WriteTable(toRemove)
            net.SendToServer()
        end
        if #classes > 10 then
            Derma_Query("Remove " .. #classes .. " NPCs from user lists?",
                "Caliber Browser", "Yes", doIt, "No")
        else
            doIt()
        end
    end)

    header("Template")

    Caliber_Browser.CopyButton = actionButton("Copy Selected", nil, function()
        local class = Caliber_Browser.LastClicked
        if not class then return end
        Caliber_Browser.CopyFromClass(class)
    end)

    actionButton("Reset All to Default", nil, function()
        Caliber_Browser.Template = {
            head_hp_frac              = 0.30,
            arms_hp_frac              = 0.20,
            legs_hp_frac              = 0.20,
            limb_damage_transfer_head = 1.50,
            limb_damage_transfer_arms = 0.80,
            limb_damage_transfer_legs = 0.60,
            mult_head = 1.0, mult_chest = 1.0, mult_arm = 1.0, mult_leg = 1.0,
            shield_enabled        = false,
            shield_type           = "spartan",
            shield_max_hp         = 70,
            shield_color          = nil,
            shield_recharge_delay = 4.0,
            shield_recharge_rate  = 15,
            shield_can_regen      = true,
        }
        Caliber_Browser.ArmorEditor.profile = {}
        Caliber_Browser.ArmorEditor.dirty   = false
        if Caliber_Browser.ArmorEditorRefresh then Caliber_Browser.ArmorEditorRefresh() end
        if IsValid(Caliber_Browser.ArmorSourceLabel) then
            Caliber_Browser.ArmorSourceLabel:SetText("Armor Template  (use Copy Selected or double-click a NPC)")
            Caliber_Browser.ArmorSourceLabel:SetTextColor(Color(130, 130, 130))
        end
        -- Reconstruir tab WL para reflejar los sliders reseteados
        if IsValid(Caliber_Browser.RightPanel) then
            Caliber_Browser.RightPanel:Clear()
            BuildRightPanel(Caliber_Browser.RightPanel)
        end
    end)

    header("Selection")

    actionButton("Select All", nil, function()
        for _, entry in ipairs(Caliber_Browser.OrderedRows) do
            if IsValid(entry.row) and entry.row:IsVisible() then
                Caliber_Browser.Selected[entry.class] = true
            end
        end
        Caliber_Browser.UpdateSelectionCount()
    end)

    actionButton("Deselect All", nil, function()
        Caliber_Browser.Selected = {}
        Caliber_Browser.LastClicked = nil
        Caliber_Browser.UpdateSelectionCount()
    end)

    actionButton("Invert Selection", nil, function()
        local newSel = {}
        for _, entry in ipairs(Caliber_Browser.OrderedRows) do
            if IsValid(entry.row) and entry.row:IsVisible() then
                if not Caliber_Browser.Selected[entry.class] then
                    newSel[entry.class] = true
                end
            end
        end
        Caliber_Browser.Selected = newSel
        Caliber_Browser.UpdateSelectionCount()
    end)

    header("Catalog")

    actionButton("Refresh from server", nil, function()
        Caliber_Browser.RequestState()
    end)

    actionButton("Scan world for extra NPCs", nil, function()
        net.Start("corpus_caliber_scan_world")
        net.SendToServer()
    end)
end

-- ── Weapons tab — curated penetration overrides + ammo fallback tuning ──────

-- Espejo cliente de CALIBER.AmmoAlias / CALIBER.AmmoFallbackDefaults (server, corpus_caliber_armor.lua).
-- Solo para mostrar qué bucket resuelve un arma sin datos EFT/curados y para el
-- botón Reset — el server sigue siendo la única autoridad real.
local CLIENT_AMMO_ALIAS = {
    Pistol = "pistol", SMG1 = "smg", AR2 = "rifle", GenericRifle = "rifle",
    ["357"] = "magnum", buckshot = "shotgun", Buckshot = "shotgun",
    SniperRound = "sniper", SniperPenetratedRound = "sniper",
}
local CLIENT_AMMO_DEFAULTS = {
    pistol  = { penPower = 20, armorDamage = 25, penChanceBase = 0.20 },
    smg     = { penPower = 28, armorDamage = 30, penChanceBase = 0.30 },
    rifle   = { penPower = 42, armorDamage = 45, penChanceBase = 0.50 },
    magnum  = { penPower = 38, armorDamage = 55, penChanceBase = 0.40 },
    shotgun = { penPower = 12, armorDamage = 20, penChanceBase = 0.10 },
    sniper  = { penPower = 60, armorDamage = 70, penChanceBase = 0.75 },
}
local AMMO_BUCKET_LABEL = {
    pistol = "Pistol", smg = "SMG", rifle = "Rifle",
    magnum = "Magnum (.357)", shotgun = "Shotgun", sniper = "Sniper",
}
local BASE_DISPLAY = {
    ["All"] = "All", arc9 = "ARC9", arc9_eft = "ARC9 EFT", tfa = "TFA", vj = "VJ", other = "Other",
}
local WPP_MIN, WPP_MAX = 1, 115
local WAD_MIN, WAD_MAX = 1, 120

-- Estiliza un DSlider manual: dibuja track + fill visibles. El skin base no los
-- muestra con contraste suficiente sobre el fondo oscuro de Caliber Configuration.
-- (declarado como forward decl arriba para que BuildArmorTab también pueda usarlo)
StyleManualSlider = function(slider)
    slider.Paint = function(self, w, h)
        local midY = math.floor(h / 2)
        surface.SetDrawColor(60, 60, 60, 255)
        surface.DrawRect(0, midY - 2, w, 4)
        surface.SetDrawColor(150, 140, 90, 255)
        surface.DrawRect(0, midY - 2, self:GetSlideX() * w, 4)
    end
end

Caliber_Browser.CuratedWeapons    = {}   -- [classname] = {penPower, armorDamage, penChanceBase}
Caliber_Browser.AmmoFallback      = {}   -- [bucket] = {...} -- live, viene del server
Caliber_Browser.WeaponsCatalog    = nil  -- construido una vez, client-side, sin net
Caliber_Browser.WeaponsTabRefresh = nil

-- Catálogo cliente desde el SWEP registry. base: "arc9" | "vj" | "tfa" | "other".
local function BuildWeaponsCatalog()
    local cat = {}
    for _, wep in ipairs(weapons.GetList()) do
        local cls = wep.ClassName
        if cls and cls ~= "" then
            local base = "other"
            if string.find(cls, "arc9_eft_", 1, true) then base = "arc9_eft"
            elseif weapons.IsBasedOn(cls, "arc9_base") then base = "arc9"
            elseif weapons.IsBasedOn(cls, "weapon_vj_base") then base = "vj"
            elseif string.find(cls, "tfa_", 1, true) then base = "tfa"
            end
            cat[cls] = {
                class = cls,
                name  = wep.PrintName or cls,
                base  = base,
                ammo  = wep.Primary and wep.Primary.Ammo or nil,
            }
        end
    end
    return cat
end

net.Receive("corpus_caliber_weapons_data", function()
    Caliber_Browser.CuratedWeapons = net.ReadTable() or {}
    Caliber_Browser.AmmoFallback   = net.ReadTable() or {}
    if Caliber_Browser.WeaponsTabRefresh then Caliber_Browser.WeaponsTabRefresh() end
end)

local function BuildWeaponsTab(parent)
    -- ── Search + base filter ─────────────────────────────────────────────────
    local filterRow = vgui.Create("DPanel", parent)
    filterRow:Dock(TOP) filterRow:SetTall(24) filterRow:DockMargin(4, 6, 4, 2)
    filterRow.Paint = function() end

    local searchBox = vgui.Create("DTextEntry", filterRow)
    searchBox:Dock(FILL)
    searchBox:SetPlaceholderText("Search by name or classname...")

    local baseFilter = "All"
    local baseCombo = vgui.Create("DComboBox", filterRow)
    baseCombo:Dock(RIGHT) baseCombo:SetWide(90)
    baseCombo:SetValue("All")
    for _, b in ipairs({"All", "arc9_eft", "arc9", "tfa", "vj", "other"}) do
        baseCombo:AddChoice(BASE_DISPLAY[b] or b, b, b == "All")
    end

    -- ── List ──────────────────────────────────────────────────────────────────
    local listScroll = vgui.Create("DScrollPanel", parent)
    listScroll:Dock(TOP) listScroll:SetTall(180) listScroll:DockMargin(4, 2, 4, 4)

    -- ── Shared editor ────────────────────────────────────────────────────────
    local editorTitle = vgui.Create("DLabel", parent)
    editorTitle:Dock(TOP) editorTitle:DockMargin(4, 4, 4, 0)
    editorTitle:SetText("Select a weapon above to edit")
    editorTitle:SetFont("DermaDefaultBold")

    local noteLabel = vgui.Create("DLabel", parent)
    noteLabel:Dock(TOP) noteLabel:DockMargin(4, 0, 4, 4)
    noteLabel:SetText("") noteLabel:SetTextColor(Color(210, 210, 210))
    noteLabel:SetWrap(true) noteLabel:SetAutoStretchVertical(true)

    local selectedClass = nil

    local function manualRow(label, wide)
        local row = vgui.Create("DPanel", parent)
        row:Dock(TOP) row:SetTall(20) row:DockMargin(4, 2, 4, 0)
        row.Paint = function() end
        local l = vgui.Create("DLabel", row)
        l:Dock(LEFT) l:SetWide(wide) l:SetText(label) l:SetFont("DermaDefault")
        local e = vgui.Create("DTextEntry", row)
        e:Dock(RIGHT) e:SetWide(40)
        local s = vgui.Create("DSlider", row)
        s:Dock(FILL)
        StyleManualSlider(s)
        return e, s
    end

    local ppEntry, ppSlider = manualRow("Pen. Power", 90)
    local adEntry, adSlider = manualRow("Armor Dmg",  90)
    local pcEntry, pcSlider = manualRow("Pen. Chance", 90)
    ppEntry:SetNumeric(true) adEntry:SetNumeric(true)

    local function ppSetValue(v) v=math.Clamp(math.floor(v),WPP_MIN,WPP_MAX) ppSlider:SetSlideX((v-WPP_MIN)/(WPP_MAX-WPP_MIN)) ppEntry:SetText(tostring(v)) end
    local function adSetValue(v) v=math.Clamp(math.floor(v),WAD_MIN,WAD_MAX) adSlider:SetSlideX((v-WAD_MIN)/(WAD_MAX-WAD_MIN)) adEntry:SetText(tostring(v)) end
    local function pcSetValue(v) v=math.Clamp(v,0,1) pcSlider:SetSlideX(v) pcEntry:SetText(string.format("%.2f", v)) end

    -- Flags de escudo (Energy Shields): curados a mano, no existen en ninguna base
    -- de armas. Viajan en la misma entrada curada (corpus_caliber_save_curated) y los lee
    -- ProcessShield aparte del tuple balístico (en armas EFT aplican igual).
    local flagRow = vgui.Create("DPanel", parent)
    flagRow:Dock(TOP) flagRow:SetTall(20) flagRow:DockMargin(4, 4, 4, 0)
    flagRow.Paint = function() end
    local plasmaCheck = vgui.Create("DCheckBoxLabel", flagRow)
    plasmaCheck:Dock(LEFT) plasmaCheck:SetWide(190)
    plasmaCheck:SetText("Plasma (extra shield drain)")
    local empCheck = vgui.Create("DCheckBoxLabel", flagRow)
    empCheck:Dock(LEFT) empCheck:DockMargin(10, 0, 0, 0) empCheck:SetWide(230)
    empCheck:SetText("EMP (shield collapse + lockout)")

    local function setEditorEnabled(en)
        ppSlider:SetEnabled(en) ppEntry:SetEnabled(en)
        adSlider:SetEnabled(en) adEntry:SetEnabled(en)
        pcSlider:SetEnabled(en) pcEntry:SetEnabled(en)
        plasmaCheck:SetEnabled(en) empCheck:SetEnabled(en)
    end
    setEditorEnabled(false)

    ppSlider.OnValueChanged = function(_, x) ppEntry:SetText(tostring(math.floor(WPP_MIN + x*(WPP_MAX-WPP_MIN)))) end
    ppEntry.OnEnter = function(self) ppSetValue(tonumber(self:GetText()) or WPP_MIN) end
    ppEntry.OnLostFocus = ppEntry.OnEnter

    adSlider.OnValueChanged = function(_, x) adEntry:SetText(tostring(math.floor(WAD_MIN + x*(WAD_MAX-WAD_MIN)))) end
    adEntry.OnEnter = function(self) adSetValue(tonumber(self:GetText()) or WAD_MIN) end
    adEntry.OnLostFocus = adEntry.OnEnter

    pcSlider.OnValueChanged = function(_, x) pcEntry:SetText(string.format("%.2f", x)) end
    pcEntry.OnEnter = function(self) pcSetValue(tonumber(self:GetText()) or 0) end
    pcEntry.OnLostFocus = pcEntry.OnEnter

    -- ── Botones ──────────────────────────────────────────────────────────────
    local btnRow = vgui.Create("DPanel", parent)
    btnRow:Dock(TOP) btnRow:SetTall(24) btnRow:DockMargin(4, 6, 4, 4)
    btnRow.Paint = function() end
    local saveBtn = vgui.Create("DButton", btnRow)
    saveBtn:Dock(LEFT) saveBtn:SetWide(90) saveBtn:SetText("Save")
    local resetBtn = vgui.Create("DButton", btnRow)
    resetBtn:Dock(LEFT) resetBtn:DockMargin(4, 0, 0, 0) resetBtn:SetWide(140)
    resetBtn:SetText("Reset to Fallback")

    -- Resuelve los valores que se mostrarían para una clase (curated ?? ammo fallback).
    -- Usado por loadWeapon (arma en edición) y por el combo "Copy values from".
    local function ResolveWeaponValues(cls, data)
        local curated = Caliber_Browser.CuratedWeapons[cls]
        if curated then return curated, true end
        local bucket = data and data.ammo and (CLIENT_AMMO_ALIAS[data.ammo] or CLIENT_AMMO_ALIAS[string.lower(data.ammo)])
        local fb = (bucket and Caliber_Browser.AmmoFallback[bucket]) or Caliber_Browser.AmmoFallback.pistol or CLIENT_AMMO_DEFAULTS.pistol
        return fb, false
    end

    local function loadWeapon(cls, data)
        selectedClass = cls
        editorTitle:SetText((data.name or cls) .. "  (" .. cls .. ")")

        local values, isCurated = ResolveWeaponValues(cls, data)
        ppSetValue(values.penPower)
        adSetValue(values.armorDamage)
        pcSetValue(values.penChanceBase)
        -- flags: solo existen en la entrada curada (nunca en el fallback)
        local cw = Caliber_Browser.CuratedWeapons[cls]
        plasmaCheck:SetChecked(cw ~= nil and cw.plasma == true)
        empCheck:SetChecked(cw ~= nil and cw.emp == true)
        setEditorEnabled(true)

        if data.base == "arc9" or data.base == "arc9_eft" then
            noteLabel:SetText("ARC9 weapon: if the equipped round carries live EFT data, EFT values win over this entry. This only applies when the round has no EFT data. Plasma/EMP flags always apply (read separately from ballistics).")
        elseif isCurated then
            noteLabel:SetText("Curated entry active.")
        else
            local bucket = data.ammo and (CLIENT_AMMO_ALIAS[data.ammo] or CLIENT_AMMO_ALIAS[string.lower(data.ammo)])
            noteLabel:SetText("No curated entry -- showing ammo fallback bucket: "
                .. (AMMO_BUCKET_LABEL[bucket] or "Pistol") .. ". Press Save to curate this weapon specifically.")
        end
    end

    saveBtn.DoClick = function()
        if not selectedClass then return end
        net.Start("corpus_caliber_save_curated")
        net.WriteString(selectedClass)
        net.WriteTable({
            penPower      = tonumber(ppEntry:GetText()) or WPP_MIN,
            armorDamage   = tonumber(adEntry:GetText()) or WAD_MIN,
            penChanceBase = tonumber(pcEntry:GetText()) or 0,
            -- flags de escudo: solo se persisten si son true (or nil = no viaja)
            plasma        = plasmaCheck:GetChecked() or nil,
            emp           = empCheck:GetChecked() or nil,
        })
        net.SendToServer()
    end

    resetBtn.DoClick = function()
        if not selectedClass then return end
        net.Start("corpus_caliber_save_curated")
        net.WriteString(selectedClass)
        net.WriteTable({})  -- vacío = borra la entrada curada (flags incluidos)
        net.SendToServer()
        plasmaCheck:SetChecked(false)
        empCheck:SetChecked(false)
    end

    -- ── Copy values from another weapon (client-side, no persiste hasta Save) ──
    local copyRow = vgui.Create("DPanel", parent)
    copyRow:Dock(TOP) copyRow:SetTall(20) copyRow:DockMargin(4, 0, 4, 4)
    copyRow.Paint = function() end
    local copyLabel = vgui.Create("DLabel", copyRow)
    copyLabel:Dock(LEFT) copyLabel:SetWide(110) copyLabel:SetText("Copy values from:")
    copyLabel:SetFont("DermaDefault")
    local copyCombo = vgui.Create("DComboBox", copyRow)
    copyCombo:Dock(FILL)
    copyCombo:SetValue("Select a weapon...")

    -- Poblado desde renderList con las clases que pasan el filtro actual (search+base).
    local function rebuildCopyCombo(visibleClasses)
        copyCombo:Clear()
        copyCombo:SetValue("Select a weapon...")
        for _, cls in ipairs(visibleClasses) do
            local data = Caliber_Browser.WeaponsCatalog[cls]
            if data then
                copyCombo:AddChoice((data.name or cls) .. " [" .. cls .. "]", cls)
            end
        end
    end

    copyCombo.OnSelect = function(_, _, _, cls)
        if not selectedClass then return end
        local data = Caliber_Browser.WeaponsCatalog[cls]
        if not data then return end
        local values = ResolveWeaponValues(cls, data)
        ppSetValue(values.penPower)
        adSetValue(values.armorDamage)
        pcSetValue(values.penChanceBase)
        -- No pisa selectedClass: los valores quedan cargados en el editor de la clase
        -- ya abierta. Save persiste en ESA clase, no en la fuente copiada.
        copyCombo:SetValue("Select a weapon...")
    end

    -- ── Render list ───────────────────────────────────────────────────────────
    local function renderList()
        listScroll:Clear()
        local search = string.lower(searchBox:GetValue() or "")
        local cat = Caliber_Browser.WeaponsCatalog or {}
        local names = {}
        for cls in pairs(cat) do table.insert(names, cls) end
        table.sort(names)
        local visible = {}

        for _, cls in ipairs(names) do
            local data = cat[cls]
            if (baseFilter == "All" or data.base == baseFilter)
               and (search == "" or string.find(string.lower(data.name), search, 1, true)
                                  or string.find(string.lower(cls), search, 1, true)) then
                table.insert(visible, cls)
                local row = vgui.Create("DButton", listScroll)
                row:Dock(TOP) row:SetTall(22) row:DockMargin(0, 1, 0, 0)
                row:SetText("")

                local curated    = Caliber_Browser.CuratedWeapons[cls]
                local badge      = curated and "Curated" or "Fallback"
                local badgeColor = curated and Color(120, 200, 120) or Color(160, 160, 160)

                row.Paint = function(self, w, h)
                    if self:IsHovered() then
                        surface.SetDrawColor(60, 60, 60, 255)
                        surface.DrawRect(0, 0, w, h)
                    end
                    surface.SetFont("DermaDefault")
                    surface.SetTextColor(220, 220, 220, 255)
                    surface.SetTextPos(4, 4)
                    surface.DrawText((data.name or cls) .. "  [" .. cls .. "]  (" .. (BASE_DISPLAY[data.base] or data.base:upper()) .. ")")
                    surface.SetTextColor(badgeColor.r, badgeColor.g, badgeColor.b, 255)
                    surface.SetTextPos(w - 60, 4)
                    surface.DrawText(badge)
                    -- badges de flags de escudo: P plasma (cian), E emp (amarillo)
                    if curated and curated.plasma then
                        surface.SetFont("DermaDefaultBold")
                        surface.SetTextColor(120, 220, 255, 255)
                        surface.SetTextPos(w - 88, 4)
                        surface.DrawText("P")
                    end
                    if curated and curated.emp then
                        surface.SetFont("DermaDefaultBold")
                        surface.SetTextColor(240, 210, 90, 255)
                        surface.SetTextPos(w - 76, 4)
                        surface.DrawText("E")
                    end
                end
                row.DoClick = function() loadWeapon(cls, data) end
            end
        end
        rebuildCopyCombo(visible)
    end

    searchBox.OnChange = renderList
    baseCombo.OnSelect = function(_, _, _, data) baseFilter = data renderList() end

    if not Caliber_Browser.WeaponsCatalog then
        Caliber_Browser.WeaponsCatalog = BuildWeaponsCatalog()
    end
    net.Start("corpus_caliber_request_weapons_data")
    net.SendToServer()
    renderList()

    -- ── Ammo Defaults ─────────────────────────────────────────────────────────
    local sep2 = vgui.Create("DPanel", parent)
    sep2:Dock(TOP) sep2:SetTall(6) sep2:DockMargin(4, 6, 4, 0)
    sep2.Paint = function(self, w, h) surface.SetDrawColor(70, 70, 70) surface.DrawRect(0, 3, w, 1) end

    local ammoHeader = vgui.Create("DLabel", parent)
    ammoHeader:Dock(TOP) ammoHeader:DockMargin(4, 4, 4, 2)
    ammoHeader:SetText("Ammo Defaults  (fallback buckets for uncurated non-EFT weapons)")
    ammoHeader:SetFont("DermaDefaultBold")

    local bucketRows = {}

    local function makeBucketRow(bucket)
        local box = vgui.Create("DPanel", parent)
        box:Dock(TOP) box:SetTall(66) box:DockMargin(4, 2, 4, 2)
        box.Paint = function(self, w, h) surface.SetDrawColor(35, 35, 35, 255) surface.DrawRect(0, 0, w, h) end

        local lbl = vgui.Create("DLabel", box)
        lbl:Dock(TOP) lbl:SetTall(16) lbl:DockMargin(4, 2, 4, 0)
        lbl:SetText(AMMO_BUCKET_LABEL[bucket] or bucket)
        lbl:SetFont("DermaDefaultBold")

        local function bucketField(label)
            local r = vgui.Create("DPanel", box)
            r:Dock(TOP) r:SetTall(16) r:DockMargin(4, 1, 4, 0)
            r.Paint = function() end
            local l = vgui.Create("DLabel", r)
            l:Dock(LEFT) l:SetWide(30) l:SetText(label) l:SetFont("DermaDefault")
            local e = vgui.Create("DTextEntry", r)
            e:Dock(RIGHT) e:SetWide(40)
            local s = vgui.Create("DSlider", r)
            s:Dock(FILL)
            StyleManualSlider(s)
            return e, s
        end

        local ppE, ppS = bucketField("Pen")
        local adE, adS = bucketField("Arm")
        local pcE, pcS = bucketField("Chn")
        ppE:SetNumeric(true) adE:SetNumeric(true)

        local function setPP(v) v=math.Clamp(math.floor(v),WPP_MIN,WPP_MAX) ppS:SetSlideX((v-WPP_MIN)/(WPP_MAX-WPP_MIN)) ppE:SetText(tostring(v)) end
        local function setAD(v) v=math.Clamp(math.floor(v),WAD_MIN,WAD_MAX) adS:SetSlideX((v-WAD_MIN)/(WAD_MAX-WAD_MIN)) adE:SetText(tostring(v)) end
        local function setPC(v) v=math.Clamp(v,0,1) pcS:SetSlideX(v) pcE:SetText(string.format("%.2f", v)) end

        ppS.OnValueChanged = function(_, x) ppE:SetText(tostring(math.floor(WPP_MIN + x*(WPP_MAX-WPP_MIN)))) end
        ppE.OnEnter = function(self) setPP(tonumber(self:GetText()) or WPP_MIN) end
        ppE.OnLostFocus = ppE.OnEnter

        adS.OnValueChanged = function(_, x) adE:SetText(tostring(math.floor(WAD_MIN + x*(WAD_MAX-WAD_MIN)))) end
        adE.OnEnter = function(self) setAD(tonumber(self:GetText()) or WAD_MIN) end
        adE.OnLostFocus = adE.OnEnter

        pcS.OnValueChanged = function(_, x) pcE:SetText(string.format("%.2f", x)) end
        pcE.OnEnter = function(self) setPC(tonumber(self:GetText()) or 0) end
        pcE.OnLostFocus = pcE.OnEnter

        bucketRows[bucket] = { ppE=ppE, adE=adE, pcE=pcE, setPP=setPP, setAD=setAD, setPC=setPC }
    end

    for _, bucket in ipairs({"pistol","smg","rifle","magnum","shotgun","sniper"}) do
        makeBucketRow(bucket)
    end

    local ammoBtnRow = vgui.Create("DPanel", parent)
    ammoBtnRow:Dock(TOP) ammoBtnRow:SetTall(24) ammoBtnRow:DockMargin(4, 4, 4, 4)
    ammoBtnRow.Paint = function() end
    local saveAmmoBtn = vgui.Create("DButton", ammoBtnRow)
    saveAmmoBtn:Dock(LEFT) saveAmmoBtn:SetWide(140) saveAmmoBtn:SetText("Save Ammo Defaults")
    local resetAmmoBtn = vgui.Create("DButton", ammoBtnRow)
    resetAmmoBtn:Dock(LEFT) resetAmmoBtn:DockMargin(4, 0, 0, 0) resetAmmoBtn:SetWide(140)
    resetAmmoBtn:SetText("Reset All to Default")

    saveAmmoBtn.DoClick = function()
        local payload = {}
        for bucket, r in pairs(bucketRows) do
            payload[bucket] = {
                penPower      = tonumber(r.ppE:GetText()) or WPP_MIN,
                armorDamage   = tonumber(r.adE:GetText()) or WAD_MIN,
                penChanceBase = tonumber(r.pcE:GetText()) or 0,
            }
        end
        net.Start("corpus_caliber_save_ammo_fallback")
        net.WriteTable(payload)
        net.SendToServer()
    end

    resetAmmoBtn.DoClick = function()
        for bucket, r in pairs(bucketRows) do
            local def = CLIENT_AMMO_DEFAULTS[bucket]
            r.setPP(def.penPower) r.setAD(def.armorDamage) r.setPC(def.penChanceBase)
        end
    end

    Caliber_Browser.WeaponsTabRefresh = function()
        renderList()
        if selectedClass and Caliber_Browser.WeaponsCatalog[selectedClass] then
            loadWeapon(selectedClass, Caliber_Browser.WeaponsCatalog[selectedClass])
        end
        for bucket, r in pairs(bucketRows) do
            local live = Caliber_Browser.AmmoFallback[bucket] or CLIENT_AMMO_DEFAULTS[bucket]
            r.setPP(live.penPower) r.setAD(live.armorDamage) r.setPC(live.penChanceBase)
        end
    end
end

-- ── Scavenger tab — overrides de peso de armas para el scavenger de NPCs ─────

-- Espejo cliente de CALIBER.ScavengerWeightOverrides (server, corpus_caliber_scavenger.lua).
-- El server es la única autoridad; esto solo refleja el último eco recibido.
Caliber_Browser.ScavWeights    = {}    -- [classname] = peso
Caliber_Browser.ScavTabRefresh = nil

-- Réplica cliente de la fórmula de peso automático del server (solo estimación
-- para mostrar en el editor; los SWEP de server pueden diferir del registry local).
local SCAV_SLOT_WEIGHTS = {[0]=1, [1]=5, [2]=8, [3]=12, [4]=15}
local function EstimateAutoWeight(cls)
    local swep = weapons.GetStored(cls)
    if not swep then return nil end
    local dmg   = tonumber(swep.Primary and swep.Primary.Damage)   or 0
    local delay = tonumber(swep.Primary and swep.Primary.Delay)    or 1
    local clip  = tonumber(swep.Primary and swep.Primary.ClipSize) or 1
    local w
    if dmg <= 0 then
        local slot = tonumber(swep.Slot) or -1
        w = SCAV_SLOT_WEIGHTS[slot] or (slot >= 5 and 10 or 3)
    else
        w = dmg * (1 / math.max(delay, 0.05)) * math.sqrt(math.max(clip, 1)) / 10
    end
    return math.Clamp(w, 0.1, 100)
end

net.Receive("corpus_caliber_scav_weights_data", function()
    Caliber_Browser.ScavWeights = net.ReadTable() or {}
    if Caliber_Browser.ScavTabRefresh then Caliber_Browser.ScavTabRefresh() end
end)

local SW_SLIDER_MAX = 100   -- los pesos auto nunca superan 100; el texto acepta hasta 1000
local SW_MAX        = 1000  -- paridad con el clamp del server (CALIBER.SetWeaponWeight)

local function BuildScavengerTab(parent)
    local header = vgui.Create("DLabel", parent)
    header:Dock(TOP) header:DockMargin(4, 6, 4, 2)
    header:SetText("NPC scavenger weapon weights. Higher weight = more desirable. Weapons without an override use the auto formula (DPS-based, or a flat per-slot value when the SWEP exposes no damage). Override 0 = NPCs never pick that weapon up.")
    header:SetWrap(true) header:SetAutoStretchVertical(true)
    header:SetTextColor(Color(210, 210, 210))

    -- ── Search + filtro de overrides ─────────────────────────────────────────
    local filterRow = vgui.Create("DPanel", parent)
    filterRow:Dock(TOP) filterRow:SetTall(24) filterRow:DockMargin(4, 4, 4, 2)
    filterRow.Paint = function() end

    local searchBox = vgui.Create("DTextEntry", filterRow)
    searchBox:Dock(FILL)
    searchBox:SetPlaceholderText("Search by name or classname...")

    local showMode = "All"
    local showCombo = vgui.Create("DComboBox", filterRow)
    showCombo:Dock(RIGHT) showCombo:SetWide(110)
    showCombo:SetValue("All")
    showCombo:AddChoice("All", "All", true)
    showCombo:AddChoice("Overridden only", "Overridden")

    -- ── List ──────────────────────────────────────────────────────────────────
    local listScroll = vgui.Create("DScrollPanel", parent)
    listScroll:Dock(TOP) listScroll:SetTall(180) listScroll:DockMargin(4, 2, 4, 4)

    -- ── Editor ────────────────────────────────────────────────────────────────
    local editorTitle = vgui.Create("DLabel", parent)
    editorTitle:Dock(TOP) editorTitle:DockMargin(4, 4, 4, 0)
    editorTitle:SetText("Select a weapon above to edit")
    editorTitle:SetFont("DermaDefaultBold")

    local infoLabel = vgui.Create("DLabel", parent)
    infoLabel:Dock(TOP) infoLabel:DockMargin(4, 0, 4, 4)
    infoLabel:SetText("") infoLabel:SetTextColor(Color(210, 210, 210))
    infoLabel:SetWrap(true) infoLabel:SetAutoStretchVertical(true)

    local selectedClass = nil

    local wRow = vgui.Create("DPanel", parent)
    wRow:Dock(TOP) wRow:SetTall(20) wRow:DockMargin(4, 2, 4, 0)
    wRow.Paint = function() end
    local wLabel = vgui.Create("DLabel", wRow)
    wLabel:Dock(LEFT) wLabel:SetWide(90) wLabel:SetText("Weight") wLabel:SetFont("DermaDefault")
    local wEntry = vgui.Create("DTextEntry", wRow)
    wEntry:Dock(RIGHT) wEntry:SetWide(50)
    wEntry:SetNumeric(true)
    local wSlider = vgui.Create("DSlider", wRow)
    wSlider:Dock(FILL)
    StyleManualSlider(wSlider)

    local function wSetValue(v)
        v = math.Clamp(tonumber(v) or 0, 0, SW_MAX)
        wSlider:SetSlideX(math.Clamp(v, 0, SW_SLIDER_MAX) / SW_SLIDER_MAX)
        wEntry:SetText(string.format("%.1f", v))
    end
    wSlider.OnValueChanged = function(_, x) wEntry:SetText(string.format("%.1f", x * SW_SLIDER_MAX)) end
    wEntry.OnEnter = function(self) wSetValue(tonumber(self:GetText()) or 0) end
    wEntry.OnLostFocus = wEntry.OnEnter

    local function setEditorEnabled(en)
        wSlider:SetEnabled(en) wEntry:SetEnabled(en)
    end
    setEditorEnabled(false)

    local function loadClass(cls)
        selectedClass = cls
        local data = Caliber_Browser.WeaponsCatalog and Caliber_Browser.WeaponsCatalog[cls]
        editorTitle:SetText(((data and data.name) or cls) .. "  (" .. cls .. ")")

        local override = Caliber_Browser.ScavWeights[cls]
        local auto     = EstimateAutoWeight(cls)
        local autoTxt  = auto and string.format("%.1f", auto) or "unknown (class not in client registry)"
        wSetValue(override or auto or 1)
        setEditorEnabled(true)

        if override then
            infoLabel:SetText(string.format("Override active: %.1f.  Estimated auto weight: %s (server is the authority).", override, autoTxt))
        else
            infoLabel:SetText("No override -- estimated auto weight: " .. autoTxt .. " (server is the authority). Press Save Override to pin a value.")
        end
    end

    -- ── Entrada manual de classname (clases server-only fuera del catálogo) ──
    local loadRow = vgui.Create("DPanel", parent)
    loadRow:Dock(TOP) loadRow:SetTall(22) loadRow:DockMargin(4, 4, 4, 0)
    loadRow.Paint = function() end
    local classEntry = vgui.Create("DTextEntry", loadRow)
    classEntry:Dock(FILL)
    classEntry:SetPlaceholderText("Or type a classname not listed above...")
    local loadBtn = vgui.Create("DButton", loadRow)
    loadBtn:Dock(RIGHT) loadBtn:DockMargin(4, 0, 0, 0) loadBtn:SetWide(80)
    loadBtn:SetText("Load class")
    loadBtn.DoClick = function()
        local cls = string.Trim(classEntry:GetValue() or "")
        if cls == "" then return end
        loadClass(cls)
    end

    -- ── Botones ──────────────────────────────────────────────────────────────
    local btnRow = vgui.Create("DPanel", parent)
    btnRow:Dock(TOP) btnRow:SetTall(24) btnRow:DockMargin(4, 6, 4, 4)
    btnRow.Paint = function() end
    local saveBtn = vgui.Create("DButton", btnRow)
    saveBtn:Dock(LEFT) saveBtn:SetWide(110) saveBtn:SetText("Save Override")
    local removeBtn = vgui.Create("DButton", btnRow)
    removeBtn:Dock(LEFT) removeBtn:DockMargin(4, 0, 0, 0) removeBtn:SetWide(120)
    removeBtn:SetText("Remove Override")

    -- Borrado por flag explícito (no valor mágico): peso 0 es legítimo
    saveBtn.DoClick = function()
        if not selectedClass then return end
        net.Start("corpus_caliber_save_scav_weight")
        net.WriteString(selectedClass)
        net.WriteBool(false)
        net.WriteFloat(math.Clamp(tonumber(wEntry:GetText()) or 1, 0, SW_MAX))
        net.SendToServer()
    end
    removeBtn.DoClick = function()
        if not selectedClass then return end
        net.Start("corpus_caliber_save_scav_weight")
        net.WriteString(selectedClass)
        net.WriteBool(true)
        net.WriteFloat(0)
        net.SendToServer()
    end

    -- ── Render list ───────────────────────────────────────────────────────────
    local function renderList()
        listScroll:Clear()
        local search = string.lower(searchBox:GetValue() or "")
        local cat = Caliber_Browser.WeaponsCatalog or {}

        -- Une catálogo cliente + clases con override (pueden ser server-only)
        local names, seen = {}, {}
        for cls in pairs(cat) do seen[cls] = true table.insert(names, cls) end
        for cls in pairs(Caliber_Browser.ScavWeights) do
            if not seen[cls] then table.insert(names, cls) end
        end
        table.sort(names)

        for _, cls in ipairs(names) do
            local data     = cat[cls]
            local name     = (data and data.name) or cls
            local override = Caliber_Browser.ScavWeights[cls]
            if (showMode == "All" or override ~= nil)
               and (search == "" or string.find(string.lower(name), search, 1, true)
                                  or string.find(string.lower(cls), search, 1, true)) then
                local row = vgui.Create("DButton", listScroll)
                row:Dock(TOP) row:SetTall(22) row:DockMargin(0, 1, 0, 0)
                row:SetText("")

                local badge      = override and string.format("W=%.1f", override) or "Auto"
                local badgeColor = override and Color(120, 200, 120) or Color(160, 160, 160)
                local baseTxt    = data and ("  (" .. (BASE_DISPLAY[data.base] or data.base:upper()) .. ")") or ""

                row.Paint = function(self, w, h)
                    if self:IsHovered() then
                        surface.SetDrawColor(60, 60, 60, 255)
                        surface.DrawRect(0, 0, w, h)
                    end
                    surface.SetFont("DermaDefault")
                    surface.SetTextColor(220, 220, 220, 255)
                    surface.SetTextPos(4, 4)
                    surface.DrawText(name .. "  [" .. cls .. "]" .. baseTxt)
                    surface.SetTextColor(badgeColor.r, badgeColor.g, badgeColor.b, 255)
                    surface.SetTextPos(w - 70, 4)
                    surface.DrawText(badge)
                end
                row.DoClick = function() loadClass(cls) end
            end
        end
    end

    searchBox.OnChange = renderList
    showCombo.OnSelect = function(_, _, _, data) showMode = data renderList() end

    Caliber_Browser.ScavTabRefresh = function()
        renderList()
        if selectedClass then loadClass(selectedClass) end  -- rehidrata con el eco del server
    end

    if not Caliber_Browser.WeaponsCatalog then
        Caliber_Browser.WeaponsCatalog = BuildWeaponsCatalog()
    end
    net.Start("corpus_caliber_request_scav_weights")
    net.SendToServer()
    renderList()
end

-- ── Energy Shield tab — config per-NPC del escudo (viaja en el whitelist entry) ──

-- Espejo cliente de los defaults de CALIBER.ShieldTypes (server, corpus_caliber_shields.lua),
-- solo para el combo/reset del tab — el server sanea y es la única autoridad.
local CLIENT_SHIELD_DEFAULTS = {
    spartan = { max_hp = 70, recharge_delay = 4.0, recharge_rate = 15, can_regen = true },
    elite   = { max_hp = 70, recharge_delay = 4.0, recharge_rate = 15, can_regen = true },
    hev     = { max_hp = 50, recharge_delay = 6.0, recharge_rate = 10, can_regen = true },
}
local SHD_HP_MIN,    SHD_HP_MAX    = 1, 5000
local SHD_DELAY_MIN, SHD_DELAY_MAX = 0, 60
local SHD_RATE_MIN,  SHD_RATE_MAX  = 0.1, 1000

local function BuildShieldTab(parent)
    local info = vgui.Create("DLabel", parent)
    info:Dock(TOP) info:DockMargin(4, 6, 4, 2)
    info:SetText("Per-NPC energy shield (global pool in front of the armor). Applied with "
        .. "\"Whitelist Selected\" (General tab). NOTE: if the checkbox below is off, "
        .. "whitelisting again CLEARS the shield of those classes.")
    info:SetWrap(true) info:SetAutoStretchVertical(true)
    info:SetTextColor(Color(210, 210, 210))  -- mismo gris legible que el header del tab Scavenger

    local enableCheck = vgui.Create("DCheckBoxLabel", parent)
    enableCheck:Dock(TOP) enableCheck:DockMargin(4, 4, 4, 2)
    enableCheck:SetText("Enable Energy Shield on whitelist")
    enableCheck.OnChange = function(_, val) Caliber_Browser.Template.shield_enabled = val end

    -- Tipo: keys del registry visual (Caliber_ShieldFX.Types, corpus_caliber_shields_cl.lua).
    -- El orden entre ese archivo y este en el manifest no importa: se lee al construir
    -- el tab, nunca al cargar el archivo. Sin él, degrada a la lista mínima (nunca
    -- error al abrir el browser).
    local typeRow = vgui.Create("DPanel", parent)
    typeRow:Dock(TOP) typeRow:SetTall(22) typeRow:DockMargin(4, 2, 4, 0)
    typeRow.Paint = function() end
    local typeLabel = vgui.Create("DLabel", typeRow)
    typeLabel:Dock(LEFT) typeLabel:SetWide(110) typeLabel:SetText("Shield type")
    typeLabel:SetFont("DermaDefault")
    local typeCombo = vgui.Create("DComboBox", typeRow)
    typeCombo:Dock(FILL)
    -- Nombre bonito para mostrar; la key interna (data del choice) no cambia —
    -- es el contrato con CALIBER.ShieldTypes/Sanitize
    local SHIELD_TYPE_LABEL = { spartan = "Spartan", elite = "Elite Sangheili", hev = "HEV" }
    local function typeLabel(k)
        local d = Caliber_ShieldFX and Caliber_ShieldFX.Types and Caliber_ShieldFX.Types[k]
        return (d and d.label) or SHIELD_TYPE_LABEL[k] or k
    end
    local typeKeys = {}
    if Caliber_ShieldFX and Caliber_ShieldFX.Types then
        for k in pairs(Caliber_ShieldFX.Types) do table.insert(typeKeys, k) end
        table.sort(typeKeys)
    else
        typeKeys = { "elite", "hev", "spartan" }
    end
    for _, k in ipairs(typeKeys) do
        typeCombo:AddChoice(typeLabel(k), k, k == Caliber_Browser.Template.shield_type)
    end
    typeCombo.OnSelect = function(_, _, _, key)
        Caliber_Browser.Template.shield_type = key
    end

    -- Filas manuales (patrón manualRow de la tab Weapons — nunca DNumSlider en scroll)
    local function manualRow(label)
        local row = vgui.Create("DPanel", parent)
        row:Dock(TOP) row:SetTall(20) row:DockMargin(4, 2, 4, 0)
        row.Paint = function() end
        local l = vgui.Create("DLabel", row)
        l:Dock(LEFT) l:SetWide(110) l:SetText(label) l:SetFont("DermaDefault")
        local e = vgui.Create("DTextEntry", row)
        e:Dock(RIGHT) e:SetWide(50) e:SetNumeric(true)
        local s = vgui.Create("DSlider", row)
        s:Dock(FILL)
        StyleManualSlider(s)
        return e, s
    end

    local hpEntry, hpSlider       = manualRow("Shield HP")
    local delayEntry, delaySlider = manualRow("Regen delay (s)")
    local rateEntry, rateSlider   = manualRow("Regen rate (HP/s)")

    -- Guard de reentrada (patrón durUpdating del tab Armor): SetSlideX dispara
    -- OnValueChanged → sin el guard, setter y handler se llaman en bucle infinito
    local shdUpdating = false

    local function hpSet(v)
        v = math.Clamp(math.floor(tonumber(v) or SHD_HP_MIN), SHD_HP_MIN, SHD_HP_MAX)
        Caliber_Browser.Template.shield_max_hp = v
        shdUpdating = true
        hpSlider:SetSlideX((v - SHD_HP_MIN) / (SHD_HP_MAX - SHD_HP_MIN))
        shdUpdating = false
        hpEntry:SetText(tostring(v))
    end
    local function delaySet(v)
        v = math.Round(math.Clamp(tonumber(v) or SHD_DELAY_MIN, SHD_DELAY_MIN, SHD_DELAY_MAX) * 10) / 10
        Caliber_Browser.Template.shield_recharge_delay = v
        shdUpdating = true
        delaySlider:SetSlideX((v - SHD_DELAY_MIN) / (SHD_DELAY_MAX - SHD_DELAY_MIN))
        shdUpdating = false
        delayEntry:SetText(string.format("%.1f", v))
    end
    local function rateSet(v)
        v = math.Round(math.Clamp(tonumber(v) or SHD_RATE_MIN, SHD_RATE_MIN, SHD_RATE_MAX) * 10) / 10
        Caliber_Browser.Template.shield_recharge_rate = v
        shdUpdating = true
        rateSlider:SetSlideX((v - SHD_RATE_MIN) / (SHD_RATE_MAX - SHD_RATE_MIN))
        shdUpdating = false
        rateEntry:SetText(string.format("%.1f", v))
    end

    hpSlider.OnValueChanged = function(_, x)
        if shdUpdating then return end
        hpSet(SHD_HP_MIN + x * (SHD_HP_MAX - SHD_HP_MIN))
    end
    hpEntry.OnEnter = function(self) hpSet(self:GetText()) end
    hpEntry.OnLostFocus = hpEntry.OnEnter
    delaySlider.OnValueChanged = function(_, x)
        if shdUpdating then return end
        delaySet(SHD_DELAY_MIN + x * (SHD_DELAY_MAX - SHD_DELAY_MIN))
    end
    delayEntry.OnEnter = function(self) delaySet(self:GetText()) end
    delayEntry.OnLostFocus = delayEntry.OnEnter
    rateSlider.OnValueChanged = function(_, x)
        if shdUpdating then return end
        rateSet(SHD_RATE_MIN + x * (SHD_RATE_MAX - SHD_RATE_MIN))
    end
    rateEntry.OnEnter = function(self) rateSet(self:GetText()) end
    rateEntry.OnLostFocus = rateEntry.OnEnter

    local regenCheck = vgui.Create("DCheckBoxLabel", parent)
    regenCheck:Dock(TOP) regenCheck:DockMargin(4, 4, 4, 2)
    regenCheck:SetText("Can regenerate (off = drained shield stays down)")
    regenCheck.OnChange = function(_, val) Caliber_Browser.Template.shield_can_regen = val end

    -- Color: default del tipo (checkbox) u override con DColorMixer (primer
    -- precedente de mixer en el addon)
    local colorDefaultCheck = vgui.Create("DCheckBoxLabel", parent)
    colorDefaultCheck:Dock(TOP) colorDefaultCheck:DockMargin(4, 6, 4, 2)
    colorDefaultCheck:SetText("Use type default color")
    local mixer = vgui.Create("DColorMixer", parent)
    mixer:Dock(TOP) mixer:SetTall(120) mixer:DockMargin(4, 2, 4, 2)
    mixer:SetPalette(false)
    mixer:SetAlphaBar(false)
    mixer:SetWangs(true)
    mixer.ValueChanged = function(_, col)
        if colorDefaultCheck:GetChecked() then return end
        -- descartar alpha: el data model persiste {r,g,b}
        Caliber_Browser.Template.shield_color = { r = col.r, g = col.g, b = col.b }
    end
    colorDefaultCheck.OnChange = function(_, val)
        if val then
            Caliber_Browser.Template.shield_color = nil
        else
            local c = mixer:GetColor()
            Caliber_Browser.Template.shield_color = { r = c.r, g = c.g, b = c.b }
        end
    end

    local resetBtn = vgui.Create("DButton", parent)
    resetBtn:Dock(TOP) resetBtn:DockMargin(4, 6, 4, 4) resetBtn:SetTall(24)
    resetBtn:SetText("Reset Shield Template (type defaults)")

    -- Refresh in-place desde el Template (lo llama CopyFromClass, patrón WLSliders)
    local function refreshFromTemplate()
        local t = Caliber_Browser.Template
        enableCheck:SetValue(t.shield_enabled == true)
        typeCombo:SetValue(typeLabel(t.shield_type or "spartan"))
        hpSet(t.shield_max_hp)
        delaySet(t.shield_recharge_delay)
        rateSet(t.shield_recharge_rate)
        regenCheck:SetValue(t.shield_can_regen ~= false)
        colorDefaultCheck:SetValue(t.shield_color == nil)
        if type(t.shield_color) == "table" then
            mixer:SetColor(Color(t.shield_color.r or 255, t.shield_color.g or 255, t.shield_color.b or 255))
        end
    end
    Caliber_Browser.ShieldTabRefresh = refreshFromTemplate

    resetBtn.DoClick = function()
        local t = Caliber_Browser.Template
        local d = CLIENT_SHIELD_DEFAULTS[t.shield_type] or CLIENT_SHIELD_DEFAULTS.spartan
        t.shield_max_hp         = d.max_hp
        t.shield_recharge_delay = d.recharge_delay
        t.shield_recharge_rate  = d.recharge_rate
        t.shield_can_regen      = d.can_regen
        t.shield_color          = nil
        refreshFromTemplate()
    end

    refreshFromTemplate()
end

function BuildRightPanel(parent)
    local sheet = vgui.Create("DPropertySheet", parent)
    sheet:Dock(FILL)
    sheet:DockMargin(0, 0, 0, 0)

    local armorScroll   = vgui.Create("DScrollPanel")
    local wlScroll      = vgui.Create("DScrollPanel")
    local weaponsScroll = vgui.Create("DScrollPanel")
    local shieldScroll  = vgui.Create("DScrollPanel")
    local scavScroll    = vgui.Create("DScrollPanel")
    local generalScroll = vgui.Create("DScrollPanel")

    sheet:AddSheet("Armor",         armorScroll,   nil, false, false)
    sheet:AddSheet("Limbs / WL",    wlScroll,      nil, false, false)
    sheet:AddSheet("Weapons",       weaponsScroll, nil, false, false)
    sheet:AddSheet("Energy Shield", shieldScroll,  nil, false, false)
    sheet:AddSheet("Scavenger",     scavScroll,    nil, false, false)
    sheet:AddSheet("General",       generalScroll, nil, false, false)

    BuildArmorTab(armorScroll)
    BuildWLTab(wlScroll)
    BuildWeaponsTab(weaponsScroll)
    BuildShieldTab(shieldScroll)
    BuildScavengerTab(scavScroll)
    BuildGeneralTab(generalScroll)
end

function Caliber_Browser.Open()
    if not LocalPlayer():IsAdmin() then
        notification.AddLegacy("Caliber Browser: admin only", NOTIFY_ERROR, 4)
        return
    end

    if IsValid(Caliber_Browser.Frame) then
        Caliber_Browser.Frame:MakePopup()
        return
    end

    local f = vgui.Create("DFrame")
    local w = math.max(CV_W:GetInt(), 600)
    local h = math.max(CV_H:GetInt(), 400)
    f:SetSize(w, h)
    local sx, sy = CV_X:GetInt(), CV_Y:GetInt()
    if sx < 0 or sy < 0 or sx > ScrW() - 100 or sy > ScrH() - 100 then
        f:Center()
    else
        f:SetPos(sx, sy)
    end
    f:SetTitle("Caliber Configuration")
    f:SetSizable(true)
    f:MakePopup()
    Caliber_Browser.Frame = f

    -- Barra superior: info + búsqueda + contador de selección
    local topBar = vgui.Create("DPanel", f)
    topBar:Dock(TOP)
    topBar:DockMargin(8, 4, 8, 2)
    topBar:SetTall(24)
    topBar.Paint = function() end

    local header = vgui.Create("DLabel", topBar)
    header:Dock(LEFT)
    header:SetWide(260)
    header:SetText("Building catalog...")
    Caliber_Browser.Header = header

    local selLabel = vgui.Create("DLabel", topBar)
    selLabel:Dock(RIGHT)
    selLabel:SetWide(120)
    selLabel:SetContentAlignment(6)
    selLabel:SetText("0 selected")
    Caliber_Browser.SelLabel = selLabel

    local searchBox = vgui.Create("DTextEntry", topBar)
    searchBox:Dock(FILL)
    searchBox:DockMargin(8, 2, 8, 2)
    searchBox:SetPlaceholderText("Search by name or classname...")
    searchBox.OnChange = function(self)
        Caliber_Browser.Filter.search = self:GetValue() or ""
        ApplyFilter()
    end

    -- Segunda barra: filtros de categoría + estado
    local filterBar = vgui.Create("DPanel", f)
    filterBar:Dock(TOP)
    filterBar:DockMargin(8, 2, 8, 2)
    filterBar:SetTall(24)
    filterBar.Paint = function() end

    -- Filtro por base de NPCs (VJ/DRG/ZBase detectados por DetectBase al
    -- construir el catálogo; HL2 = stock VALVe; GMOD = resto de addons)
    local baseCombo = vgui.Create("DComboBox", filterBar)
    baseCombo:Dock(LEFT)
    baseCombo:SetWide(110)
    baseCombo:DockMargin(0, 0, 6, 0)
    baseCombo:SetValue("Base: All")
    local BASE_CHOICES = {
        {"Base: All", "ALL"}, {"HL2", "HL2"}, {"GMod", "GMOD"},
        {"VJ", "VJ"}, {"DrG", "DRG"}, {"ZBase", "ZBASE"},
    }
    for i, choice in ipairs(BASE_CHOICES) do
        baseCombo:AddChoice(choice[1], choice[2], i == 1)
    end
    baseCombo.OnSelect = function(_, _, _, data)
        Caliber_Browser.Filter.base = data
        -- La categoría activa puede no existir en la nueva base: resetear
        Caliber_Browser.Filter.category = "All"
        Caliber_Browser.RepopulateCategories()
        ApplyFilter()
    end
    Caliber_Browser.BaseCombo = baseCombo

    local catCombo = vgui.Create("DComboBox", filterBar)
    catCombo:Dock(LEFT)
    catCombo:SetWide(180)
    catCombo:SetValue("All categories")
    catCombo:AddChoice("All", "All", true)
    catCombo.OnSelect = function(_, _, _, data)
        Caliber_Browser.Filter.category = data
        ApplyFilter()
    end
    Caliber_Browser.CatCombo = catCombo

    local stateOrder = {
        {"wl_user", "WL"}, {"wl_hard", "WL-H"},
        {"bl_user", "BL"}, {"bl_hard", "BL-H"},
        {"vj_pattern", "VJ"}, {"vj_auto", "VJa"},
        {"unknown", "?"}, {"none", "-"},
    }
    for _, pair in ipairs(stateOrder) do
        local cb = vgui.Create("DCheckBoxLabel", filterBar)
        cb:Dock(LEFT)
        cb:DockMargin(6, 4, 0, 0)
        cb:SetText(pair[2])
        cb:SetValue(true)
        cb:SizeToContents()
        cb.OnChange = function(_, val)
            Caliber_Browser.Filter.states[pair[1]] = val
            ApplyFilter()
        end
    end

    local divider = vgui.Create("DHorizontalDivider", f)
    divider:Dock(FILL)
    divider:DockMargin(8, 4, 8, 8)
    divider:SetDividerWidth(4)
    divider:SetLeftMin(400)
    divider:SetRightMin(240)

    -- Contenedor izquierdo: header de columnas fijo + scroll
    local leftContainer = vgui.Create("DPanel", divider)
    leftContainer.Paint = function() end
    divider:SetLeft(leftContainer)

    local colHeader = vgui.Create("DPanel", leftContainer)
    colHeader:Dock(TOP)
    colHeader:SetTall(22)
    colHeader.Paint = function(self, w, h)
        surface.SetDrawColor(55, 55, 55, 255)
        surface.DrawRect(0, 0, w, h)
        surface.SetDrawColor(80, 80, 80, 255)
        surface.DrawLine(0, h - 1, w, h - 1)
        surface.SetFont("DermaDefaultBold")
        surface.SetTextColor(200, 200, 200, 255)
        local cols = {
            { x = 32,  label = "Name" },
            { x = 210, label = "Classname" },
            { x = 390, label = "St" },
            { x = 425, label = "Arm" },
            { x = 465, label = "H/C/A/L" },
            { x = 555, label = "Shd" },
        }
        for _, c in ipairs(cols) do
            surface.SetTextPos(c.x, 4)
            surface.DrawText(c.label)
        end
    end

    local scroll = vgui.Create("DScrollPanel", leftContainer)
    scroll:Dock(FILL)
    Caliber_Browser.Scroll = scroll

    local right = vgui.Create("DPanel", divider)
    right.Paint = function() end
    divider:SetRight(right)
    Caliber_Browser.RightPanel = right

    -- Proporción 70/30 (o la guardada) tras el primer layout del DFrame
    timer.Simple(0, function()
        if IsValid(divider) and IsValid(f) then
            local ratio = math.Clamp(CV_DIV:GetFloat(), 0.4, 0.85)
            local totalW = f:GetWide() - 16
            divider:SetLeftWidth(math.floor(totalW * ratio))
        end
    end)

    BuildRightPanel(right)

    -- Construir catálogo cliente
    Caliber_Browser.Catalog = BuildCatalog()
    local total = table.Count(Caliber_Browser.Catalog)
    header:SetText("Catalog: " .. total .. " NPCs  |  Requesting state from server...")

    -- Poblar dropdown de categorías (base-aware)
    Caliber_Browser.RepopulateCategories()

    -- Primer render con estados vacíos, luego request al server
    RenderCatalog(scroll)
    -- Si el stool ya tenía listas cacheadas, las usamos de inmediato
    if CALIBER and CALIBER.ClientLists then
        Caliber_Browser.Whitelist = CALIBER.ClientLists.whitelist or {}
        Caliber_Browser.Blacklist = CALIBER.ClientLists.blacklist or {}
        dprint("Open: usando ClientLists cacheadas | wl=", table.Count(Caliber_Browser.Whitelist))
    end
    Caliber_Browser.RequestState()
    net.Start("corpus_caliber_request_lists")
    net.SendToServer()

    f.OnRemove = function()
        local px, py = f:GetPos()
        local pw, ph = f:GetSize()
        RunConsoleCommand("caliber_browser_x", tostring(px))
        RunConsoleCommand("caliber_browser_y", tostring(py))
        RunConsoleCommand("caliber_browser_w", tostring(pw))
        RunConsoleCommand("caliber_browser_h", tostring(ph))
        if IsValid(divider) then
            local ratio = divider:GetLeftWidth() / math.max(pw - 16, 1)
            RunConsoleCommand("caliber_browser_div_ratio", tostring(ratio))
        end
        Caliber_Browser.Frame = nil
        Caliber_Browser.Scroll = nil
        Caliber_Browser.Rows = nil
        Caliber_Browser.RowsBuilt = false
        Caliber_Browser.Selected = {}
        Caliber_Browser.LastClicked = nil
        Caliber_Browser.OrderedRows = {}
        Caliber_Browser.Categories = {}
        Caliber_Browser.Filter.search = ""
        Caliber_Browser.Filter.category = "All"
        Caliber_Browser.Filter.base = "ALL"
        Caliber_Browser.Filter.states = {
            wl_user = true, wl_hard = true,
            bl_user = true, bl_hard = true,
            vj_pattern = true, vj_auto = true,
            unknown = true, none = true,
        }
        Caliber_Browser._debugged = {}
        Caliber_Browser.Armored = {}
        Caliber_Browser.ArmorEditor = { classname = nil, profile = {}, dirty = false }
        Caliber_Browser.ArmorEditorRefresh = nil
        Caliber_Browser.WLSliders = {}
    end
end

function Caliber_Browser.UpdateCopyButton()
    if not IsValid(Caliber_Browser.CopyButton) then return end
    local count = 0
    local single
    for c, _ in pairs(Caliber_Browser.Selected) do
        count = count + 1
        single = c
        if count > 1 then break end
    end
    local enabled = count == 1 and Caliber_Browser.State[single] == "wl_user"
    dprint("UpdateCopyButton | count=", count, "| single=", single,
        "| state=", single and Caliber_Browser.State[single], "| enabled=", enabled)
    Caliber_Browser.CopyButton:SetEnabled(enabled)
    Caliber_Browser.CopyButton:SetTooltip(
        enabled and nil or "Requires exactly 1 selection with user whitelist override"
    )
end

function Caliber_Browser.UpdateSelectionCount()
    if not IsValid(Caliber_Browser.SelLabel) then return end
    local n = 0
    for _ in pairs(Caliber_Browser.Selected) do n = n + 1 end
    Caliber_Browser.SelLabel:SetText(n .. " selected")
    Caliber_Browser.UpdateCopyButton()
    if IsValid(Caliber_Browser.Scroll) then
        Caliber_Browser.Scroll:InvalidateLayout()
    end
end

net.Receive("corpus_caliber_scan_world_result", function()
    local classes = net.ReadTable() or {}
    local added = 0
    local vjList  = list.Get("VJBASE_SPAWNABLE_NPC")
    local drgList = list.Get("DrGBaseNextbots")
    for _, class in ipairs(classes) do
        if not Caliber_Browser.Catalog[class] then
            Caliber_Browser.Catalog[class] = {
                class     = class,
                name      = class,
                category  = "World-only (unregistered)",
                model     = nil,
                icon_path = nil,
                base      = DetectBase(class, {}, vjList, drgList),
            }
            added = added + 1
        end
    end
    notification.AddLegacy("Scan world: " .. added .. " new NPCs added to catalog", NOTIFY_GENERIC, 4)
    if added > 0 and IsValid(Caliber_Browser.Frame) then
        Caliber_Browser.RowsBuilt = false
        RenderCatalog(Caliber_Browser.Scroll)
        -- Repoblar el dropdown de categorías (base-aware, sin duplicados)
        Caliber_Browser.RepopulateCategories()
        Caliber_Browser.RequestState()
    end
end)

-- Comando de consola para abrir, util para pruebas antes de agregar el bot�n
concommand.Add("caliber_browser",    function() Caliber_Browser.Open() end)  -- alias de compatibilidad
concommand.Add("caliber_config_ui",  function() Caliber_Browser.Open() end)

concommand.Add("caliber_browser_debug_reset", function()
    Caliber_Browser._debugged = {}
    Corpus.Log("caliber", "[Caliber_Browser] debug cache cleared, next paint will re-print")
end)

--- Comando de consola para debug: muestra en consola los campos de list.Get("NPC")[classname]
concommand.Add("caliber_browser_dump", function(_, _, args)
    local class = args[1]
    if not class then
        Corpus.Log("caliber", "uso: caliber_browser_dump <classname>")
        return
    end
    local npcs = list.Get("NPC")
    local data = npcs[class]
    if not data then
        Corpus.Log("caliber", "No existe en list.Get('NPC'): " .. class)
        return
    end
    Corpus.Log("caliber", "=== Campos de " .. class .. " ===")
    for k, v in pairs(data) do
        Corpus.Log("caliber", string.format("  %s = %s (%s)", tostring(k), tostring(v), type(v)))
    end
end)

--- Comando de consola para debug: muestra en consola las rutas de icono candidatas y si existen o no
concommand.Add("caliber_browser_findicon", function(_, _, args)
    local class = args[1]
    if not class then Corpus.Log("caliber", "uso: caliber_browser_findicon <classname>") return end
    local candidates = {
        "materials/vgui/entities/" .. class .. ".vmt",
        "materials/vgui/entities/" .. class .. ".png",
        "materials/entities/" .. class .. ".vmt",
        "materials/entities/" .. class .. ".png",
    }
    for _, path in ipairs(candidates) do
        local exists = file.Exists(path, "GAME")
        Corpus.Log("caliber", string.format("  %s => %s", path, exists and "FOUND" or "missing"))
    end
end)