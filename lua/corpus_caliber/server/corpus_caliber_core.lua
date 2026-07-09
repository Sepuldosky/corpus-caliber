-- corpus_caliber_core.lua — núcleo: pipeline de daño, config, whitelist, net, hooks (server)
-- Migrado desde ADS 2.0 (ads_core.lua). Namespace vía tabla única registrada (Caliber_Architecture.md §3).
local CALIBER = Corpus.GetModule("caliber")

local S_MIN  = CreateConVar("caliber_min_arm",       "0",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local S_MAX  = CreateConVar("caliber_max_arm",       "100", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local P_STR  = CreateConVar("caliber_ply_arm",       "100", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local R_MIN  = CreateConVar("caliber_red_min",       "15",  FCVAR_REPLICATED + FCVAR_ARCHIVE)
local R_MAX  = CreateConVar("caliber_red_max",       "80",  FCVAR_REPLICATED + FCVAR_ARCHIVE)
local BLAST  = CreateConVar("caliber_blast_mult",    "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local CRUSH  = CreateConVar("caliber_crush_mult",    "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local HELMET = CreateConVar("caliber_helmet_mult",   "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local SND_EN = CreateConVar("caliber_sound_enabled", "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local GSB_EN = CreateConVar("caliber_gunshotblocked_enabled", "1", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local HS_EN  = CreateConVar("caliber_headshot_sound_enabled", "1", FCVAR_REPLICATED + FCVAR_ARCHIVE)
-- Block FX: feedback visual cuando la armadura BLOQUEA (factorPenleft == 0)
local BLK_NB  = CreateConVar("caliber_block_noblood_enabled", "1", FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Suprime la sangre (engine / VJ / Visceral) del hit bloqueado por armadura")
local BLK_SPK = CreateConVar("caliber_block_spark_enabled",   "1", FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Chispa metalica en el punto de impacto bloqueado")
local BLK_DCL = CreateConVar("caliber_block_decal_enabled",   "1", FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Decal de impacto metalico encima del gunshot al bloquear")
local EN_NPC = CreateConVar("caliber_enabled_npc",   "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local EN_PLY = CreateConVar("caliber_enabled_ply",   "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local LM_H   = CreateConVar("caliber_limb_mult_head","1.0", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local LM_C   = CreateConVar("caliber_limb_mult_chest","1.0",FCVAR_REPLICATED + FCVAR_ARCHIVE)
local LM_A   = CreateConVar("caliber_limb_mult_arm", "1.0", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local LM_L   = CreateConVar("caliber_limb_mult_leg", "1.0", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local ENG_COMP = CreateConVar("caliber_engine_hitgroup_compensation", "1", FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Cancel Source engine native hitgroup scaling (0.25x limbs, 2.0x head) so Caliber damage matches HP loss")
CreateConVar("caliber_vj_autodetect",                "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local DBG        = CreateConVar("caliber_debug",        "0", FCVAR_ARCHIVE,
    "0=off  1=compact (one line/hit)  2=verbose (block/hit + events)  3=full pipeline (detour DET + stash race + no_stash alerts)")
local DBG_FILTER = CreateConVar("caliber_debug_filter", "", FCVAR_ARCHIVE,
    "Filter trace to this NPC classname. Empty = all.")

-- EntIndex of a picked NPC (caliber_debug_pick sets this). 0 = off.
local _dbgPickIdx = 0

-- level: minimum caliber_debug tier required to print (1 or 2).
local function dprint(level, ...)
    if DBG:GetInt() < level then return end
    Corpus.Log("caliber", "[Caliber]", ...)
end

-- Returns true when 'npc' passes the active filter (pick or classname).
-- Auto-clears the pick index if the picked entity is gone.
local function _dbgPass(npc)
    if not IsValid(npc) then return false end
    if _dbgPickIdx ~= 0 then
        local picked = Entity(_dbgPickIdx)
        if not IsValid(picked) then _dbgPickIdx = 0 end  -- auto-clear stale pick
        if IsValid(picked) then return npc == picked end
    end
    local f = DBG_FILTER:GetString()
    -- Matchea classname o key de spawnmenu (caliber_debug_filter <key> funciona
    -- para NPCs de addon que spawnean con clase genérica)
    return f == "" or npc:GetClass() == f or npc.NPCName == f
end

-- caliber_debug_pick: aim at an NPC and run to pin the trace filter to it.
-- Admin-only. Run again on empty space, or set caliber_debug_filter "", to release.
concommand.Add("caliber_debug_pick", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then
        ply:PrintMessage(HUD_PRINTCONSOLE, "[Caliber] caliber_debug_pick requires admin.")
        return
    end
    local tr = util.TraceLine({
        start  = IsValid(ply) and ply:EyePos()                    or Vector(0,0,0),
        endpos = IsValid(ply) and ply:EyePos() + ply:GetAimVector() * 2048 or Vector(0,0,0),
        filter = IsValid(ply) and ply or nil,
    })
    local ent = tr.Entity
    if IsValid(ent) and ent:IsNPC() then
        _dbgPickIdx = ent:EntIndex()
        local msg = "[Caliber] debug pick -> " .. ent:GetClass() .. " (ent #" .. _dbgPickIdx .. ")"
        Corpus.Log("caliber", msg)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
    else
        _dbgPickIdx = 0
        local msg = "[Caliber] debug pick cleared"
        Corpus.Log("caliber", msg)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
    end
end)

-- ── caliber_test_vj_inject — valida punto de inyección PreDamage de VJ ──────────
-- Admin-only. Apunta a un NPC VJ y corre el comando.
-- El próximo daño que reciba ese NPC se fuerza a 999 vía CustomOnTakeDamage_BeforeDamage.
-- Loguea el valor que llegó al hook (post-engine) y el que se inyectó.
-- El parche se elimina solo después del primer hit.
concommand.Add("caliber_test_vj_inject", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then
        ply:PrintMessage(HUD_PRINTCONSOLE, "[Caliber TEST] requires admin.")
        return
    end
    local tr = util.TraceLine({
        start  = IsValid(ply) and ply:EyePos()                         or Vector(0,0,0),
        endpos = IsValid(ply) and ply:EyePos() + ply:GetAimVector() * 2048 or Vector(0,0,0),
        filter = IsValid(ply) and ply or nil,
    })
    local ent = tr.Entity
    if not IsValid(ent) or not ent:IsNPC() or not ent.IsVJBaseSNPC then
        local msg = "[Caliber TEST] caliber_test_vj_inject: aim at a VJ NPC."
        Corpus.Log("caliber", msg)
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end
        return
    end

    local msg = "[Caliber TEST] inject armed -> " .. ent:GetClass() .. " (ent #" .. ent:EntIndex() .. ")"
    Corpus.Log("caliber", msg)
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) end

    -- Parchear CustomOnTakeDamage_BeforeDamage en la instancia (no en el prototipo)
    local prev = ent.CustomOnTakeDamage_BeforeDamage
    ent.CustomOnTakeDamage_BeforeDamage = function(self, dmginfo, hitgroup)
        local before = dmginfo:GetDamage()
        local forced = tonumber(args and args[1]) or 50
        dmginfo:SetDamage(forced)
        Corpus.Log("caliber", string.format(
            "[Caliber TEST] PreDamage inject: hg=%d  engine_delivered=%.2f  forced=%g  frame=%d",
            hitgroup, before, forced, FrameNumber()))
        -- Restaurar después del primer hit
        self.CustomOnTakeDamage_BeforeDamage = prev
        if prev then return prev(self, dmginfo, hitgroup) end
    end
end)
-- ─────────────────────────────────────────────────────────────────────────────

-- caliber_dump_vj_scale — dumpea campos de damage scale en un NPC VJ apuntado.
-- Busca campos conocidos de VJ Base + sweep numérico en rango [0.05, 0.75].
-- Admin-only.
concommand.Add("caliber_dump_vj_scale", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then
        ply:PrintMessage(HUD_PRINTCONSOLE, "[Caliber DUMP] requires admin.")
        return
    end
    local tr = util.TraceLine({
        start  = IsValid(ply) and ply:EyePos()                         or Vector(0,0,0),
        endpos = IsValid(ply) and ply:EyePos() + ply:GetAimVector() * 2048 or Vector(0,0,0),
        filter = IsValid(ply) and ply or nil,
    })
    local ent = tr.Entity
    if not IsValid(ent) or not ent:IsNPC() then
        Corpus.Log("caliber", "[Caliber DUMP] aim at an NPC.")
        if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[Caliber DUMP] aim at an NPC.") end
        return
    end

    Corpus.Log("caliber", string.format("[Caliber DUMP] === %s (ent #%d)  HP=%.1f ===",
        ent:GetClass(), ent:EntIndex(), ent:Health()))
    Corpus.Log("caliber", string.format("  IsVJBaseSNPC = %s", tostring(ent.IsVJBaseSNPC)))

    -- Campos conocidos de VJ Base y GMod nativos relacionados a damage scale
    local knownFields = {
        "BulletDamageScale", "VJ_DamageMultiplier", "VJC_AllDamageMultiplier",
        "AllDamageMultiplier", "BulletDamageMultiplier", "DamageMultiplier",
        "VJ_NPC_DmgMul", "VJ_NPC_BulletDmgMul", "VJ_AddDamageMul",
        "VJ_DmgMul_Bullet", "VJ_DmgMul_AllDamage",
    }
    Corpus.Log("caliber", "  [known fields]")
    local anyKnown = false
    local etblKnown = ent:GetTable()
    for _, k in ipairs(knownFields) do
        local v = etblKnown[k]
        if v ~= nil then
            Corpus.Log("caliber", string.format("    ent.%s = %s", k, tostring(v)))
            anyKnown = true
        end
    end
    if not anyKnown then Corpus.Log("caliber", "    (ninguno presente)") end

    -- Método nativo GMod NPC
    if ent.GetBulletDamageScale then
        Corpus.Log("caliber", string.format("  GetBulletDamageScale() = %s", tostring(ent:GetBulletDamageScale())))
    end

    -- Sweep: todos los campos numéricos en rango sospechoso [0.05, 0.75]
    -- Las entidades son userdata; sus campos Lua viven en ent:GetTable().
    Corpus.Log("caliber", "  [numeric sweep 0.05-0.75]")
    local found = 0
    local etbl = ent:GetTable()
    for k, v in pairs(etbl) do
        if type(v) == "number" and v >= 0.05 and v <= 0.75 then
            Corpus.Log("caliber", string.format("    ent.%s = %g", tostring(k), v))
            found = found + 1
        end
    end
    if found == 0 then Corpus.Log("caliber", "    (ninguno)") end
end)

-- ─────────────────────────────────────────────────────────────────────────────

CALIBER.HARDCODED_WHITELIST = {npc_combine_s=true,npc_metropolice=true,npc_citizen=true,npc_alyx=true,npc_barney=true}
CALIBER.HARDCODED_BLACKLIST = {npc_vj_cpriguarh=true}
CALIBER.VJ_CLASSNAME_PATTERNS = {"vj_hsold","vj_hs_","vj_combine","vj_metro","vj_metropolice","vj_cswat","vj_csold","vj_milit"}
CALIBER.VJ_ARMORED_CLASSES = {CLASS_COMBINE=true,CLASS_MILITARY=true,CLASS_METROPOLICE=true,CLASS_RESISTANCE=true,CLASS_UNITED_STATES=true,CLASS_POLICE=true,CLASS_SWAT=true,CLASS_SOLDIER=true}
CALIBER.UserWhitelist = {}
CALIBER.UserBlacklist = {}
CALIBER.ResolvedVJClass = {}

-- Source engine native hitgroup multipliers for NPCs (skill.cfg defaults).
-- Used to cancel engine scaling so Caliber-calculated damage matches HP loss.
-- Some NPCs (VJ Base with custom resistances) may further modify damage in
-- their own OnTakeDamage; this compensation does not cover that case.
CALIBER.ENGINE_HG_MULT = {
    [HITGROUP_HEAD]     = 2.0,
    [HITGROUP_CHEST]    = 1.0,
    [HITGROUP_STOMACH]  = 1.0,
    [HITGROUP_GENERIC]  = 1.0,
    [HITGROUP_LEFTARM]  = 0.25,
    [HITGROUP_RIGHTARM] = 0.25,
    [HITGROUP_LEFTLEG]  = 0.25,
    [HITGROUP_RIGHTLEG] = 0.25,
    [HITGROUP_GEAR]     = 1.0,
}

-- Persistencia vía primitiva Corpus.Data (Caliber_Architecture.md §6): ruta
-- data/corpus/caliber/config.json. Clean-slate: sin importador del JSON viejo de ADS (ads_config.json).
function CALIBER.SaveConfig()
    Corpus.Data.Save("caliber", "config", {
        whitelist       = CALIBER.UserWhitelist,
        blacklist       = CALIBER.UserBlacklist,
        armor           = CALIBER.ArmorProfiles or {},
        curated_weapons = CALIBER.CuratedWeapons or {},
        ammo_fallback   = (CALIBER.GetAmmoFallbackOverrides and CALIBER.GetAmmoFallbackOverrides()) or {},
    })
end

function CALIBER.LoadConfig()
    CALIBER.UserWhitelist={} CALIBER.UserBlacklist={}
    -- Corpus.Data.Load devuelve nil si no existe (primer arranque) o si el JSON
    -- está corrupto; ambos casos → reescribir defaults (self-heal, clean-slate).
    local tbl = Corpus.Data.Load("caliber", "config")
    if type(tbl)~="table" then CALIBER.SaveConfig() return end
    if type(tbl.whitelist)=="table" then
        for c,d in pairs(tbl.whitelist) do if type(d)=="table" then CALIBER.UserWhitelist[c]=d end end
    end
    if type(tbl.blacklist)=="table" then
        for c,v in pairs(tbl.blacklist) do if v then CALIBER.UserBlacklist[c]=true end end
    end
    if CALIBER.LoadArmorData then CALIBER.LoadArmorData(tbl) end
end

function CALIBER.IsArmored(ent)
    if not IsValid(ent) then return false end
    if ent:IsPlayer() then return EN_PLY:GetBool() end
    if not ent:IsNPC() then return false end
    if not EN_NPC:GetBool() then return false end
    -- Identidad: key de spawnmenu (si tiene config) > classname del motor
    local key=CALIBER.GetConfigKey(ent)
    local c=ent:GetClass()
    if CALIBER.UserBlacklist[key] then return false end
    if CALIBER.UserWhitelist[key] then return true end
    if key~=c then
        if CALIBER.UserBlacklist[c] then return false end
        if CALIBER.UserWhitelist[c] then return true end
    end
    if CALIBER.HARDCODED_BLACKLIST[c] then return false end
    if CALIBER.HARDCODED_WHITELIST[c] then return true end
    for _,p in ipairs(CALIBER.VJ_CLASSNAME_PATTERNS) do
        if string.find(c,p,1,true) then return true end
    end
    if GetConVar("caliber_vj_autodetect"):GetBool() and ent.IsVJBaseSNPC then
        local v=ent.VJ_NPC_Class
        if type(v)=="table" then
            for _,cc in ipairs(v) do if CALIBER.VJ_ARMORED_CLASSES[cc] then return true end end
        elseif type(v)=="string" and CALIBER.VJ_ARMORED_CLASSES[v] then return true end
    end
    return false
end

function CALIBER.GetArmorReason(ent)
    if not IsValid(ent) then return "Invalid" end
    if ent:IsPlayer() then return EN_PLY:GetBool() and "Player" or "Player disabled" end
    if not ent:IsNPC() then return "Not NPC" end
    if not EN_NPC:GetBool() then return "NPC system disabled" end
    -- Espejo del chequeo en capas de IsArmored; si decide la key de
    -- spawnmenu (≠ classname), el reason la delata
    local key=CALIBER.GetConfigKey(ent)
    local c=ent:GetClass()
    if key~=c then
        if CALIBER.UserBlacklist[key] then return "Blacklisted (user: "..key..")" end
        if CALIBER.UserWhitelist[key] then return "Whitelisted (user: "..key..")" end
    end
    if CALIBER.UserBlacklist[c] then return "Blacklisted (user)" end
    if CALIBER.UserWhitelist[c] then return "Whitelisted (user)" end
    if CALIBER.HARDCODED_BLACKLIST[c] then return "Hardcoded blacklist" end
    if CALIBER.HARDCODED_WHITELIST[c] then return "Hardcoded whitelist" end
    for _,p in ipairs(CALIBER.VJ_CLASSNAME_PATTERNS) do
        if string.find(c,p,1,true) then return "VJ pattern ("..p..")" end
    end
    if GetConVar("caliber_vj_autodetect"):GetBool() and ent.IsVJBaseSNPC then
        local v=ent.VJ_NPC_Class
        if type(v)=="table" then
            for _,cc in ipairs(v) do if CALIBER.VJ_ARMORED_CLASSES[cc] then return "VJ auto ("..cc..")" end end
        elseif type(v)=="string" and CALIBER.VJ_ARMORED_CLASSES[v] then return "VJ auto ("..v..")" end
    end
    return "Not armored"
end

-- Resuelve el estado de un classname sin necesitar instancia viva.
-- Devuelve: "wl_user", "bl_user", "wl_hard", "bl_hard", "vj_pattern",
--          "vj_auto", "unknown" (candidato VJ no resuelto) o "none".
function CALIBER.GetClassStatus(classname)
    if not classname or classname == "" then return "none" end
    if CALIBER.UserBlacklist[classname]   then return "bl_user" end
    if CALIBER.UserWhitelist[classname]   then return "wl_user" end
    if CALIBER.HARDCODED_BLACKLIST[classname] then return "bl_hard" end
    if CALIBER.HARDCODED_WHITELIST[classname] then return "wl_hard" end
    for _, p in ipairs(CALIBER.VJ_CLASSNAME_PATTERNS) do
        if string.find(classname, p, 1, true) then return "vj_pattern" end
    end
    if GetConVar("caliber_vj_autodetect"):GetBool() then
        local cached = CALIBER.ResolvedVJClass[classname]
        if cached == true then return "vj_auto" end
        if cached == false then return "none" end
        -- nil = nunca se ha visto una instancia de este classname
        if string.find(classname, "vj_", 1, true) or string.find(classname, "npc_vj_", 1, true) then
            return "unknown"
        end
    end
    return "none"
end

function CALIBER.GetOverride(class)
    local o=CALIBER.UserWhitelist[class]
    if type(o)=="table" and next(o)~=nil then return o end
    return nil
end

-- ── Identidad por spawnmenu ──────────────────────────────────────────────────
-- El sandbox taggea la entidad con la key del spawnmenu (ent.NPCName =
-- commands.lua:557, preservada por el duplicator) y ZBase hace lo propio. Si
-- esa key tiene config de usuario (whitelist/blacklist/perfil de armadura),
-- manda sobre el classname del motor — cubre addons de playermodel-NPC que
-- spawnean como npc_citizen/npc_combine_s genéricos. NPCs spawneados por
-- código no traen NPCName → classname (comportamiento idéntico al previo).
-- Los entries NUNCA se mezclan: la key específica reemplaza al genérico.
function CALIBER.GetConfigKey(ent)
    if not IsValid(ent) then return "" end
    local c = ent:GetClass()
    local n = ent.NPCName
    if isstring(n) and n ~= "" and n ~= c then
        if CALIBER.UserWhitelist[n] ~= nil or CALIBER.UserBlacklist[n]
           or (CALIBER.ArmorProfiles and CALIBER.ArmorProfiles[n] ~= nil) then
            return n
        end
    end
    return c
end

-- Override efectivo para una ENTIDAD: entry de la key específica si existe;
-- si no, entry del classname (sin mezclar campos entre ambos).
function CALIBER.GetOverrideForEnt(ent)
    if not IsValid(ent) then return nil end
    local key = CALIBER.GetConfigKey(ent)
    local o = CALIBER.GetOverride(key)
    if o then return o end
    local c = ent:GetClass()
    if key ~= c then return CALIBER.GetOverride(c) end
    return nil
end

-- Blacklist de usuario efectiva por entidad. Precedencia: key específica >
-- classname; una key whitelisteada explícitamente anula el blacklist genérico
-- de su clase.
function CALIBER.IsUserBlacklisted(ent)
    if not IsValid(ent) then return false end
    local key = CALIBER.GetConfigKey(ent)
    if CALIBER.UserBlacklist[key] then return true end
    local c = ent:GetClass()
    if key ~= c then
        if CALIBER.UserWhitelist[key] ~= nil then return false end
        return CALIBER.UserBlacklist[c] == true
    end
    return false
end

-- Consulta mult de zona: override > convar global > 1.0
local function GetZoneMult(override, key, convar)
    if override and override.dmg_mult and override.dmg_mult[key] ~= nil then
        return tonumber(override.dmg_mult[key]) or 1.0
    end
    return convar:GetFloat()
end


local function Sanitize(data)
    if type(data)~="table" then return {} end
    local c={}
    -- Limb HP fraction overrides (0-2 range, 2dp; >1 allowed for reinforced limbs)
    if tonumber(data.head_hp_frac) then c.head_hp_frac=math.Round(math.Clamp(tonumber(data.head_hp_frac),0,2)*100)/100 end
    if tonumber(data.arms_hp_frac) then c.arms_hp_frac=math.Round(math.Clamp(tonumber(data.arms_hp_frac),0,2)*100)/100 end
    if tonumber(data.legs_hp_frac) then c.legs_hp_frac=math.Round(math.Clamp(tonumber(data.legs_hp_frac),0,2)*100)/100 end
    -- limb damage transfer per zone (0-3 range; head can exceed 1.0 to ensure pools drain fast enough)
    if tonumber(data.limb_damage_transfer_head) then c.limb_damage_transfer_head=math.Round(math.Clamp(tonumber(data.limb_damage_transfer_head),0,3)*100)/100 end
    if tonumber(data.limb_damage_transfer_arms) then c.limb_damage_transfer_arms=math.Round(math.Clamp(tonumber(data.limb_damage_transfer_arms),0,3)*100)/100 end
    if tonumber(data.limb_damage_transfer_legs) then c.limb_damage_transfer_legs=math.Round(math.Clamp(tonumber(data.limb_damage_transfer_legs),0,3)*100)/100 end
    if type(data.dmg_mult)=="table" then
        local m={}
        for _,k in ipairs({"head","chest","arm","leg"}) do
            local v=tonumber(data.dmg_mult[k])
            if v then m[k]=math.Round(math.Clamp(v,0,10)*100)/100 end
        end
        -- Solo guardar si al menos un mult no es 1.0
        local anyNonUnit=false
        for _,v in pairs(m) do if v~=1.0 then anyNonUnit=true break end end
        if anyNonUnit then c.dmg_mult=m end
    end
    -- Energy shield (corpus_caliber_shields.lua): gate maestro = shield_type válido contra el
    -- registry. Sin tipo válido se descartan TODOS los campos shield_* (sin escudo).
    -- Los campos opcionales caen a los defaults del tipo en InitShield.
    if type(data.shield_type)=="string" and CALIBER.ShieldTypes and CALIBER.ShieldTypes[data.shield_type] then
        c.shield_type=data.shield_type
        if tonumber(data.shield_max_hp) then
            c.shield_max_hp=math.floor(math.Clamp(tonumber(data.shield_max_hp),1,5000))
        end
        if type(data.shield_color)=="table" then
            local r,g,b=tonumber(data.shield_color.r),tonumber(data.shield_color.g),tonumber(data.shield_color.b)
            if r and g and b then
                c.shield_color={
                    r=math.floor(math.Clamp(r,0,255)),
                    g=math.floor(math.Clamp(g,0,255)),
                    b=math.floor(math.Clamp(b,0,255)),
                }
            end
        end
        if tonumber(data.shield_recharge_delay) then
            c.shield_recharge_delay=math.Round(math.Clamp(tonumber(data.shield_recharge_delay),0,60)*10)/10
        end
        if tonumber(data.shield_recharge_rate) then
            c.shield_recharge_rate=math.Round(math.Clamp(tonumber(data.shield_recharge_rate),0.1,1000)*10)/10
        end
        -- false es valor legítimo: solo se persiste si el cliente lo mandó
        if data.shield_can_regen~=nil then c.shield_can_regen=data.shield_can_regen==true end
    end
    return c
end

-- Valida y clampa un perfil de armadura zonal antes de persistir.
-- Retorna tabla limpia, o nil si no hay zonas ni fallback válidos (= borrar perfil).
local function SanitizeArmor(profile)
    if type(profile) ~= "table" then return nil end
    local out = {}

    -- Zonas por hitgroup (keys "1".."7")
    if type(profile.zones) == "table" then
        local zones = {}
        for hg = 1, 7 do
            local key = tostring(hg)
            local z = profile.zones[key]
            if type(z) == "table" then
                local cls = math.floor(math.Clamp(tonumber(z.class)   or 3,   1, 8))
                local dur = math.floor(math.Clamp(tonumber(z.dur_max) or 80,  1, 200))
                local mat = (type(z.material) == "string" and CALIBER.Materials and CALIBER.Materials[z.material])
                            and z.material or "aramid"
                zones[key] = { class = cls, dur_max = dur, material = mat }
            end
        end
        if next(zones) then out.zones = zones end
    end

    -- Fallback para hitgroup GENERIC y zonas sin placa
    if type(profile.fallback_generic) == "table" then
        local fg = profile.fallback_generic
        local cls = math.floor(math.Clamp(tonumber(fg.class)   or 3,   1, 8))
        local dur = math.floor(math.Clamp(tonumber(fg.dur_max) or 80,  1, 200))
        local mat = (type(fg.material) == "string" and CALIBER.Materials and CALIBER.Materials[fg.material])
                    and fg.material or "aramid"
        out.fallback_generic = { class = cls, dur_max = dur, material = mat }
    end

    -- Metadato opaco de UI (no tiene efecto en runtime)
    if type(profile.coverage_profile) == "string" then
        out.coverage_profile = string.sub(profile.coverage_profile, 1, 64)
    end

    -- Perfil sin zonas ni fallback = nil → el handler borrará el perfil de la clase
    if not out.zones and not out.fallback_generic then return nil end
    return out
end

-- Variantes internas sin SaveConfig/broadcast, para operaciones batch
local function _WlAddNoSave(classname, data)
    if not classname or classname=="" then return end
    CALIBER.UserBlacklist[classname]=nil
    CALIBER.UserWhitelist[classname]=Sanitize(data)
end
local function _WlDelNoSave(classname)
    CALIBER.UserWhitelist[classname]=nil
end
local function _BlAddNoSave(classname)
    if not classname or classname=="" or CALIBER.UserBlacklist[classname] then return end
    CALIBER.UserWhitelist[classname]=nil
    CALIBER.UserBlacklist[classname]=true
end
local function _BlDelNoSave(classname)
    CALIBER.UserBlacklist[classname]=nil
end

function CALIBER.AddToWhitelist(classname,data)
    if not classname or classname=="" then return false end
    _WlAddNoSave(classname,data)
    CALIBER.SaveConfig() return true
end
function CALIBER.RemoveFromWhitelist(c)
    if not c or not CALIBER.UserWhitelist[c] then return false end
    _WlDelNoSave(c) CALIBER.SaveConfig() return true
end
function CALIBER.AddToBlacklist(c)
    if not c or c=="" or CALIBER.UserBlacklist[c] then return false end
    _BlAddNoSave(c)
    CALIBER.SaveConfig() return true
end
function CALIBER.RemoveFromBlacklist(c)
    if not c or not CALIBER.UserBlacklist[c] then return false end
    _BlDelNoSave(c) CALIBER.SaveConfig() return true
end
function CALIBER.ClearWhitelist() CALIBER.UserWhitelist={} CALIBER.SaveConfig() end
function CALIBER.ClearBlacklist() CALIBER.UserBlacklist={} CALIBER.SaveConfig() end

function CALIBER.InspectNPC(ent)
    if not IsValid(ent) then return nil end
    local i={classname=ent:GetClass(),is_vj=ent.IsVJBaseSNPC==true,vj_class=nil,
             armor=(ent:IsPlayer() and ent:Armor() or 0),is_armored=CALIBER.IsArmored(ent),reason=CALIBER.GetArmorReason(ent),
             override=CALIBER.GetOverrideForEnt(ent),
             config_key=CALIBER.GetConfigKey(ent),
             is_whitelisted=CALIBER.UserWhitelist[CALIBER.GetConfigKey(ent)]~=nil
                            or CALIBER.UserWhitelist[ent:GetClass()]~=nil}
    if i.is_vj then
        local v=ent.VJ_NPC_Class
        if type(v)=="table" then i.vj_class=table.concat(v,", ")
        elseif type(v)=="string" then i.vj_class=v end
    end
    -- Armor slots: NWvars pobladas por corpus_caliber_armor.lua en InitArmorNWvars/ApplyArmorDirect
    if ent:GetNWBool("Caliber_Armor_Init", false) then
        local slots = {}
        for hg = 0, 7 do
            local cls = ent:GetNWInt("Caliber_Armor_Class_" .. hg, 0)
            if cls > 0 then
                slots[tostring(hg)] = {
                    class    = cls,
                    dur      = ent:GetNWInt("Caliber_Armor_Dur_"    .. hg, 0),
                    dur_max  = ent:GetNWInt("Caliber_Armor_MaxDur_" .. hg, 0),
                    material = ent:GetNWString("Caliber_Armor_Mat_" .. hg, ""),
                }
            end
        end
        i.armor_slots   = slots
        i.armor_init    = true
        i.tool_override = ent.Caliber_ToolArmorOverride == true
    end
    -- Limb HP pools (populated by corpus_caliber_limbs.lua on spawn)
    if ent.Caliber_HP_HeadMax then
        local function lr(cur,max) return (max and max>0) and math.Clamp(cur/max,0,1) or 0 end
        i.limbs={
            head  ={hp=ent.Caliber_HP_Head, max=ent.Caliber_HP_HeadMax, ratio=lr(ent.Caliber_HP_Head, ent.Caliber_HP_HeadMax)},
            arm_l ={hp=ent.Caliber_HP_ArmL, max=ent.Caliber_HP_ArmLMax, ratio=lr(ent.Caliber_HP_ArmL, ent.Caliber_HP_ArmLMax)},
            arm_r ={hp=ent.Caliber_HP_ArmR, max=ent.Caliber_HP_ArmRMax, ratio=lr(ent.Caliber_HP_ArmR, ent.Caliber_HP_ArmRMax)},
            leg_l ={hp=ent.Caliber_HP_LegL, max=ent.Caliber_HP_LegLMax, ratio=lr(ent.Caliber_HP_LegL, ent.Caliber_HP_LegLMax)},
            leg_r ={hp=ent.Caliber_HP_LegR, max=ent.Caliber_HP_LegRMax, ratio=lr(ent.Caliber_HP_LegR, ent.Caliber_HP_LegRMax)},
        }
    end
    -- Energy shield state (populated by corpus_caliber_shields.lua when the whitelist entry has shield_type)
    if ent.Caliber_Shield then
        local s = ent.Caliber_Shield
        i.shield = {
            type           = s.type,
            hp             = math.Round(s.hp, 1),
            max            = s.max,
            state          = ({ "UP", "DOWN", "CHARGING" })[s.state] or "?",
            can_regen      = s.canRegen,
            recharge_delay = s.rechargeDelay,
            recharge_rate  = s.rechargeRate,
            regen_in       = math.Round(math.max(0, s.regenAt - CurTime()), 1),
            lockout_in     = math.Round(math.max(0, (s.lockoutUntil or 0) - CurTime()), 1),
        }
    end
    -- Scavenger state (populated by corpus_caliber_scavenger.lua; field exists even when false)
    if ent.Caliber_CanScavenge ~= nil then
        i.scavenger = {
            can_scavenge       = ent.Caliber_CanScavenge,
            cooldown_remaining = math.max(0, (ent.Caliber_NextScavengerCheck or 0) - CurTime()),
            target_weapon      = IsValid(ent.Caliber_ScavengerTargetWeapon)
                                     and ent.Caliber_ScavengerTargetWeapon:GetClass() or nil,
        }
        local cur = ent:GetActiveWeapon()
        if IsValid(cur) then
            i.scavenger.current_weapon = cur:GetClass()
            if CALIBER.GetWeaponWeight then
                i.scavenger.current_weapon_weight = CALIBER.GetWeaponWeight(cur)
            end
        end
    end
    return i
end

-- BLOCKABLE: DMG_CRUSH(1), DMG_BULLET(2), DMG_SLASH(4), DMG_BLAST(64),
-- DMG_CLUB(128), DMG_BUCKSHOT(33554432), DMG_SNIPER(1073741824)
-- Nota: el comentario original era incorrecto — 16=DMG_VEHICLE, 1048576=DMG_PHYSGUN,
-- ninguno de los dos debe bloquearse. DMG_SLASH=4 y DMG_BUCKSHOT=33554432 son los reales.
local BLOCKABLE = bit.bor(
    1,           -- DMG_CRUSH
    2,           -- DMG_BULLET
    4,           -- DMG_SLASH
    64,          -- DMG_BLAST
    128,         -- DMG_CLUB
    33554432,    -- DMG_BUCKSHOT
    1073741824   -- DMG_SNIPER
)

hook.Add("OnEntityCreated","Caliber_NPC_Init",function(e)
    timer.Simple(0.2,function()
        if not IsValid(e) or e:IsPlayer() or not e:IsNPC() then return end
        -- Poblar cache VJ si aplica, antes de IsArmored (así el browser se entera)
        if e.IsVJBaseSNPC and CALIBER.ResolvedVJClass[e:GetClass()] == nil then
            local v = e.VJ_NPC_Class
            local matched = false
            if type(v) == "table" then
                for _, cc in ipairs(v) do
                    if CALIBER.VJ_ARMORED_CLASSES[cc] then matched = true break end
                end
            elseif type(v) == "string" and CALIBER.VJ_ARMORED_CLASSES[v] then
                matched = true
            end
            CALIBER.ResolvedVJClass[e:GetClass()] = matched
            dprint(2, "vj cache resolved",e:GetClass(),"=",tostring(matched))
        end
        if CALIBER.InitArmorNWvars then CALIBER.InitArmorNWvars(e) end
    end)
end)



-- Fase 2: multiplicador de zona (solo NPCs, aplica aunque no haya armor)
local function ApplyDamageMultiplier(victim,hitgroup,dmginfo)
    if not victim:IsNPC() then return end
    if dmginfo:GetDamage()<=0 then return end
    local dt=dmginfo:GetDamageType()
    if bit.band(dt,BLOCKABLE)==0 then return end
    -- Explosiones y crush ignoran esta fase (ya gobernadas por blast_mult/crush_mult)
    if bit.band(dt,64)~=0 then return end
    if bit.band(dt,1)~=0  then return end

    local override=CALIBER.GetOverrideForEnt(victim)
    local mult
    if hitgroup==HITGROUP_HEAD then
        mult=GetZoneMult(override,"head",LM_H)
    elseif hitgroup==HITGROUP_CHEST or hitgroup==HITGROUP_STOMACH or hitgroup==HITGROUP_GENERIC then
        mult=GetZoneMult(override,"chest",LM_C)
    elseif hitgroup==HITGROUP_LEFTARM or hitgroup==HITGROUP_RIGHTARM then
        mult=GetZoneMult(override,"arm",LM_A)
    elseif hitgroup==HITGROUP_LEFTLEG or hitgroup==HITGROUP_RIGHTLEG then
        mult=GetZoneMult(override,"leg",LM_L)
    else
        return
    end
    if mult==1.0 then return end
    local d=dmginfo:GetDamage()
    dmginfo:SetDamage(d*mult)
end

-- Sonidos custom del addon (carpeta sound/ads/). Se referencian relativos a sound/.
local SND_BLOCKED  = { "ads/GunshotBlocked.wav", "ads/GunshotBlocked2.wav" }
local SND_HS_HARD  = "ads/HeadshotHard.wav"    -- casco detiene la bala
local SND_HS_LIGHT = "ads/HeadshotLight.wav"   -- bala penetra el casco
-- precache: evita que el primer disparo suene mudo
for _, s in ipairs(SND_BLOCKED) do util.PrecacheSound(s) end
util.PrecacheSound(SND_HS_HARD)
util.PrecacheSound(SND_HS_LIGHT)

-- Feedback sonoro de armadura. Se llama siempre que se resolvió armadura sobre el NPC.
--   hg       : hitgroup impactado
--   material : string del material de la placa (clave de CALIBER.Materials)
--   blocked  : true si la placa detuvo la bala; false si penetró
--   dur      : durabilidad de la placa (modula el volumen del clang metálico)
local function PlayArmorSounds(npc, hg, material, blocked, dur)
    -- Cabeza con armadura: el ding de headshot REEMPLAZA todo lo demás
    -- (Hard = casco aguanta, Light = casco penetrado). Suena aunque el material
    -- sea blando: la cabeza es la excepción a "blandas en silencio".
    if hg == HITGROUP_HEAD and HS_EN:GetBool() then
        npc:EmitSound(blocked and SND_HS_HARD or SND_HS_LIGHT, 75, math.random(96,104), 1)
        return
    end

    -- Resto del cuerpo: solo suena al BLOQUEAR
    if not blocked then return end

    -- Placas blandas (aramida/fluido no-newtoniano) = silencio: no clanguean
    local mat = CALIBER.Materials[material]
    if not (mat and mat.hard) then return end

    -- gunshotblocked: la bala fue detenida por la armadura
    if GSB_EN:GetBool() then
        npc:EmitSound(SND_BLOCKED[math.random(1, #SND_BLOCKED)], 75, math.random(95,110), 1)
    end
    -- clang metálico: solo materiales duros; volumen según durabilidad restante
    if SND_EN:GetBool() then
        local vol = math.Clamp((dur or 100)/100, 0.4, 1)
        npc:EmitSound("physics/metal/metal_solid_impact_bullet"..math.random(1,4)..".wav", 75, math.random(90,110), vol)
    end
end


-- ── Block FX: feedback visual de impacto BLOQUEADO ──────────────────────────
-- Se llama DENTRO de ScaleNPCDamage (corre dentro de CAI_BaseNPC::TraceAttack,
-- ANTES de que el engine lea BloodColor() y llame SpawnBlood/TraceBleed) → poner
-- DONT_BLEED acá suprime la sangre de ESTE hit. No se puede restaurar en el
-- mismo hook (la sangre se decide después de retornar): restore en timer.Simple(0).
-- hitPos/hitNormal: trace real del detour ARC9 (path stash); nil en paths inline
-- → fallback a dmginfo. La normal apunta HACIA AFUERA de la superficie.
-- bloodOnly: true = solo supresión de sangre (rama 1), sin chispa ni decal —
-- lo usa el escudo (el hit absorbido tiene su propio flash de energía, la
-- chispa metálica y el ricochet no corresponden). Los call sites de armadura
-- pasan nil y conservan el comportamiento completo.
function CALIBER.ApplyBlockedHitFX(npc, di, hg, hitPos, hitNormal, bloodOnly)
    -- token per-hit: lo consumen el detour de Visceral y el hook de ragdoll
    npc.Caliber_BlockedHitToken = FrameNumber()

    -- posición / normal del impacto
    local pos = hitPos or di:GetDamagePosition()
    local nrm = hitNormal
    if not nrm then
        local f = di:GetDamageForce()
        -- la fuerza apunta HACIA la superficie → invertir
        nrm = f:LengthSqr() > 0 and -f:GetNormalized() or vector_up
    end
    -- daños exóticos pueden traer posición cero: degradar al centro del NPC
    if pos:IsZero() then pos = npc:WorldSpaceCenter() end

    -- 1) supresión de sangre de este hit (engine + sangre propia de VJ)
    if BLK_NB:GetBool() and npc.Caliber_BlockFXStash == nil then  -- guard anti-doble-stash
        local stash = { bloodColor = npc:GetBloodColor() }
        if npc.IsVJBaseSNPC then
            -- VJ spawnea su PROPIA sangre en OnTakeDamage (DoBleed), gateada por
            -- self.Bleeds y SIN consultar GetBloodColor → DONT_BLEED no le basta.
            -- OnTakeDamage de VJ corre después de este hook y antes del timer(0).
            stash.vjHad    = true
            stash.vjBleeds = npc.Bleeds  -- puede ser false de fábrica (vj_npc_blood 0)
            npc.Bleeds     = false
        end
        npc.Caliber_BlockFXStash = stash
        npc:SetBloodColor(DONT_BLEED)
        timer.Simple(0, function()
            if not IsValid(npc) then return end
            local s = npc.Caliber_BlockFXStash
            if not s then return end  -- ClearBlockedHitFX ya restauró (ráfaga mixta)
            npc:SetBloodColor(s.bloodColor)
            if s.vjHad then npc.Bleeds = s.vjBleeds end
            npc.Caliber_BlockFXStash = nil
        end)
    end

    -- 2) chispa metálica en el punto de impacto
    if not bloodOnly and BLK_SPK:GetBool() then
        local ed = EffectData()
        ed:SetOrigin(pos)
        ed:SetNormal(nrm)
        ed:SetMagnitude(1)
        ed:SetScale(1)
        util.Effect("MetalSpark", ed)
    end

    -- 3) decal metálico ENCIMA del gunshot de flesh (util.Decal es networked y
    --    llega al cliente DESPUÉS del impact effect → pinta encima). Si no cubre,
    --    degradación aceptada: queda el de flesh.
    -- OJO: el 4º arg de util.Decal es el FILTRO del trace (entidades a ignorar),
    -- no el objetivo — pasar el npc ahí impedía pintar sobre él.
    if not bloodOnly and BLK_DCL:GetBool() then
        util.Decal("Caliber_Ricochet", pos + nrm * 4, pos - nrm * 4)
    end

    if DBG:GetInt() >= 2 and _dbgPass(npc) then
        dprint(2, string.format("blockfx apply  %s hg=%d  src=%s%s%s",
            npc:GetClass(), hg, hitPos and "trace" or "dmginfo",
            (npc.IsVJBaseSNPC and "  vj_bleeds_off" or ""),
            (bloodOnly and "  blood_only" or "")))
    end
end

-- Rama PENETRADA: restaurar YA (mismo frame — el perdigón que penetra debe
-- sangrar) y limpiar el token para que el detour Visceral (que corre después,
-- con el daño agregado) no suprima la sangre de una ráfaga mixta.
function CALIBER.ClearBlockedHitFX(npc)
    npc.Caliber_BlockedHitToken = nil
    local s = npc.Caliber_BlockFXStash
    if s then
        npc:SetBloodColor(s.bloodColor)
        if s.vjHad then npc.Bleeds = s.vjBleeds end
        npc.Caliber_BlockFXStash = nil  -- el timer pendiente ve nil → no-op
        if DBG:GetInt() >= 2 and _dbgPass(npc) then
            dprint(2, "blockfx clear (pen tras bloqueo, mismo tick)  " .. npc:GetClass())
        end
    end
end


-- Hitgroup index -> readable name, used by debug trace
local _HG_NAME = {
    [HITGROUP_HEAD]     = "head",    [HITGROUP_CHEST]   = "chest",
    [HITGROUP_STOMACH]  = "stomach", [HITGROUP_GENERIC] = "generic",
    [HITGROUP_LEFTARM]  = "arm_l",   [HITGROUP_RIGHTARM]= "arm_r",
    [HITGROUP_LEFTLEG]  = "leg_l",   [HITGROUP_RIGHTLEG]= "leg_r",
}

hook.Add("ScaleNPCDamage","Caliber_Core_NPC",function(npc,hg,di)
    -- ── debug: trace variables (populated per-phase below) ──────────────────
    local dbgOn   = DBG:GetInt() >= 1
    local dbgFull = DBG:GetInt() >= 2
    local dbgThis = dbgOn and _dbgPass(npc)
    local dmg_in  = di:GetDamage()

    local armorPath  = "disabled"   -- stash / stash_MISS / no_stash / inline / no_zone / non_blockable / not_armored
    local armorSrc   = "-"          -- eft / arc9 / tfa / fallback
    local armorPen   = nil          -- true=penetrated, false=blocked, nil=no armor
    local armorClass = 0
    local armorDurBef= 0
    local armorDurAft= 0
    local armorPenPow    = 0
    local stashFrameDelta = -1   -- tier 3: frames entre deposit y consume; -1 = no aplica
    -- ────────────────────────────────────────────────────────────────────────

    -- ── ESCUDO: pre-filtro global delante de la armadura (corpus_caliber_shields.lua) ──
    -- No-overflow (§4 del diseño): la absorción total consume el hit COMPLETO y
    -- corta el hook — la armadura no gasta durabilidad y ProcessLimbHit no corre
    -- (cero debuffs con escudo arriba). Guarded: corpus_caliber_shields.lua carga después
    -- vía el manifest (corpus_caliber_init.lua, §4) — el guard también cubre instalación
    -- parcial (subsistema deshabilitado o archivo ausente).
    local shieldNote = nil
    if CALIBER.ProcessShield then
        local absorbed, sTrace = CALIBER.ProcessShield(npc, hg, di)
        if absorbed then
            -- supresión de sangre del hit absorbido (sin chispa/decal de armadura:
            -- el escudo tiene su propio flash de energía)
            CALIBER.ApplyBlockedHitFX(npc, di, hg, nil, nil, true)
            -- defensivo: descartar stash ARC9 fresco — la placa NO participa en un
            -- hit absorbido (el detour normalmente ya no deposita, ver SHIELD-STOP)
            npc.Caliber_ArmorStash = nil
            if dbgThis then
                local hgStr = _HG_NAME[hg] or tostring(hg)
                local plasmaStr = sTrace.plasma and " plasma" or ""
                if dbgFull then
                    Corpus.Log("caliber", string.format("[Caliber HIT] ── %s  hg=%d(%s) ──────────────────",
                        npc:GetClass(), hg, hgStr))
                    Corpus.Log("caliber", string.format("  [shield] reason=%-8s drain=%.1f%s  pool=%.1f->%.1f  in=%.1f->0  (hit consumido: sin armadura/limbs)",
                        sTrace.reason, sTrace.drain or 0, plasmaStr, sTrace.hpBefore, sTrace.hpAfter, dmg_in))
                else
                    Corpus.Log("caliber", string.format("[Caliber] %s hg=%d(%s) SHIELD %s drain=%.1f%s pool=%.1f->%.1f  in=%.1f->0",
                        npc:GetClass(), hg, hgStr, sTrace.reason, sTrace.drain or 0, plasmaStr,
                        sTrace.hpBefore, sTrace.hpAfter, dmg_in))
                end
            end
            return
        end
        -- bypass/down: el hit sigue el pipeline normal; anotar para la traza
        shieldNote = sTrace and sTrace.reason or nil
    end

    -- Pre-filtro de armadura 2.0. ARC9: consume el stash depositado por el detour
    -- de AfterShotFunction. VJ/HL2/TFA: resolve inline como antes.
    if CALIBER.GetZone and CALIBER.ResolveArmor and CALIBER.ExtractBulletData then
        local atk = di:GetAttacker()
        local wep = (IsValid(atk) and atk.GetActiveWeapon) and atk:GetActiveWeapon() or nil
        local isARC9 = IsValid(wep) and wep.GetProcessedValue ~= nil
        if isARC9 then
            local stash = npc.Caliber_ArmorStash
            if stash and (FrameNumber() - stash.frame) <= 1 then
                local d = di:GetDamage()
                if d > 0 then
                    di:SetDamage(d * stash.factor)
                    if stash.durKey ~= nil and stash.durKey ~= "" then
                        npc:SetNWInt("Caliber_Armor_Dur_" .. stash.durKey, stash.newDur)
                    end
                    PlayArmorSounds(npc, hg, stash.material, not stash.penetra, stash.newDur)
                    if stash.penetra then
                        CALIBER.ClearBlockedHitFX(npc)
                    else
                        CALIBER.ApplyBlockedHitFX(npc, di, hg, stash.hitPos, stash.hitNormal)
                    end
                end
                -- debug: read enriched stash fields deposited by the ARC9 detour
                armorPath   = "stash"
                armorSrc    = stash.src        or "arc9"
                armorPen    = stash.penetra
                armorClass  = stash.armorClass or 0
                armorDurBef = stash.durBefore  or 0
                armorDurAft = stash.newDur      or 0
                armorPenPow    = stash.penPower    or 0
                stashFrameDelta = FrameNumber() - stash.frame
                npc.Caliber_ArmorStash = nil
            else
                -- Defensivo: el detour de AfterShotFunction no depositó stash (p.ej.
                -- NPC disparando ARC9 vía NPC_PrimaryAttack, o timing de frame perdido).
                -- Resolver inline en vez de dejar pasar la bala sin filtrar por armadura.
                local zona = CALIBER.GetZone(npc, hg)
                if zona and bit.band(di:GetDamageType(), BLOCKABLE) ~= 0 then
                    local tuple = CALIBER.ExtractBulletData(wep, di)
                    local res   = CALIBER.ResolveArmor(zona, tuple, hg)
                    di:SetDamage(res.fleshDmg)
                    npc:SetNWInt("Caliber_Armor_Dur_" .. zona.durKey, res.newDur)
                    PlayArmorSounds(npc, hg, zona.material, res.factorPenleft == 0, zona.durActual)
                    if res.factorPenleft == 0 then
                        CALIBER.ApplyBlockedHitFX(npc, di, hg, nil, nil)  -- sin trace: cae a dmginfo
                    else
                        CALIBER.ClearBlockedHitFX(npc)
                    end
                    armorPath   = "inline_arc9"
                    armorSrc    = tuple.source  or "-"
                    armorPen    = (res.factorPenleft > 0)
                    armorClass  = zona.clase
                    armorDurBef = zona.durActual
                    armorDurAft = res.newDur    or zona.durActual
                    armorPenPow = tuple.penPower or 0
                else
                    armorPath = stash and "stash_MISS" or "no_stash"
                end
                -- Tier 3: segmento ARC9 llegó a SND sin pasar por el detour
                if DBG:GetInt() >= 3 and _dbgPass(npc) then
                    Corpus.Log("caliber", string.format(
                        "[Caliber DET] !! NO_STASH  f=%d  %s  hg=%d(%s)  raw=%.2f  path=%s  (segmento ARC9 sin detour)",
                        FrameNumber(), npc:GetClass(), hg, (_HG_NAME[hg] or tostring(hg)), dmg_in, armorPath))
                end
            end
        else
            local zona = CALIBER.GetZone(npc, hg)
            if zona and bit.band(di:GetDamageType(), BLOCKABLE) ~= 0 then
                local tuple = CALIBER.ExtractBulletData(wep, di)
                local res   = CALIBER.ResolveArmor(zona, tuple, hg)
                di:SetDamage(res.fleshDmg)
                npc:SetNWInt("Caliber_Armor_Dur_" .. zona.durKey, res.newDur)
                PlayArmorSounds(npc, hg, zona.material, res.factorPenleft == 0, zona.durActual)
                if res.factorPenleft == 0 then
                    CALIBER.ApplyBlockedHitFX(npc, di, hg, nil, nil)  -- sin trace: cae a dmginfo
                else
                    CALIBER.ClearBlockedHitFX(npc)
                end
                -- debug: inline resolve
                armorPath   = "inline"
                armorSrc    = tuple.source  or "-"
                armorPen    = (res.factorPenleft > 0)
                armorClass  = zona.clase
                armorDurBef = zona.durActual
                armorDurAft = res.newDur    or zona.durActual
                armorPenPow = tuple.penPower or 0
            elseif not zona then
                armorPath = (CALIBER.IsArmored and CALIBER.IsArmored(npc)) and "no_zone" or "not_armored"
            else
                armorPath = "non_blockable"
            end
        end
    end
    ApplyDamageMultiplier(npc,hg,di)
    -- Limb HP subsystem (corpus_caliber_limbs.lua); guarded so missing file is harmless
    npc.Caliber_LastLimbHit = nil  -- clear stash before call so stale data never leaks
    if CALIBER.ProcessLimbHit then CALIBER.ProcessLimbHit(npc,hg,di) end
    -- Engine hitgroup compensation: ALWAYS LAST. Cancels Source's native
    -- post-hook scaling (0.25x limbs, 2.0x head) so the HP loss matches the
    -- damage value Caliber already computed. Skip when mult is 1.0 (no-op zones)
    -- or when damage is non-positive after armor/mults.
    local dmg_pre_comp = di:GetDamage()
    local compEM = 1.0
    if ENG_COMP:GetBool() then
        local d = di:GetDamage()
        if d > 0 then
            local em = CALIBER.ENGINE_HG_MULT[hg]
            if em and em ~= 1.0 then
                di:SetDamage(d / em)
                compEM = em
            end
        end
    end
    local dmg_final = di:GetDamage()

    -- ── debug trace emit ────────────────────────────────────────────────────
    if dbgThis then
        local hgStr  = _HG_NAME[hg] or tostring(hg)
        local penStr = armorPen == true and "PEN" or armorPen == false and "BLK" or "---"
        local lb     = npc.Caliber_LastLimbHit
        if dbgFull then
            -- Tier 2: verbose block
            Corpus.Log("caliber", string.format("[Caliber HIT] ── %s  hg=%d(%s) ──────────────────",
                npc:GetClass(), hg, hgStr))
            if shieldNote then
                Corpus.Log("caliber", string.format("  [shield] reason=%-8s (hit pasa entero al pipeline)", shieldNote))
            end
            Corpus.Log("caliber", string.format("  [armor]  path=%-12s src=%-8s pen=%-3s  cls=%d  penPow=%.0f  dur=%.0f->%.0f  in=%.1f->%.1f",
                armorPath, armorSrc, penStr, armorClass, armorPenPow,
                armorDurBef, armorDurAft, dmg_in, dmg_pre_comp))
            if lb then
                Corpus.Log("caliber", string.format("  [limb]   zone=%-6s  dmgPool=%.1f  pool=%.1f->%.1f/%.1f",
                    lb.zone, lb.dmgPool, lb.before, lb.after, lb.poolMax))
            else
                Corpus.Log("caliber", "  [limb]   no pool (chest/stomach/generic or limbs disabled)")
            end
            if compEM ~= 1.0 then
                Corpus.Log("caliber", string.format("  [engcomp] em=%.2f  %.1f -> %.1f", compEM, dmg_pre_comp, dmg_final))
            else
                Corpus.Log("caliber", "  [engcomp] skip (em=1.0)")
            end
            Corpus.Log("caliber", string.format("  [FINAL]  %.1f", dmg_final))
        else
            -- Tier 1: compact single line
            local limbStr = lb and (lb.zone .. string.format(" %.1f->%.1f", lb.before, lb.after)) or "-"
            local compStr = compEM ~= 1.0 and string.format(" eng/%.2f", compEM) or ""
            local shdStr  = shieldNote and (" shd=" .. shieldNote) or ""
            Corpus.Log("caliber", string.format("[Caliber] %s hg=%d(%s) src=%-8s path=%-12s %s cls=%d penPow=%.0f  in=%.1f->%.1f  limb=[%s]%s%s",
                npc:GetClass(), hg, hgStr, armorSrc, armorPath,
                penStr, armorClass, armorPenPow,
                dmg_in, dmg_final, limbStr, compStr, shdStr))
        end
    end
    -- Tier 3: SND pipeline summary — completa el par DET+SND del full pipeline trace
    if DBG:GetInt() >= 3 and _dbgPass(npc) then
        local hgN    = _HG_NAME[hg] or tostring(hg)
        local ageStr = stashFrameDelta >= 0 and (stashFrameDelta .. "fr") or "-"
        Corpus.Log("caliber", string.format(
            "[Caliber SND] f=%d  %s  hg=%d(%s)  path=%-12s  age=%s  in=%.1f  final=%.1f",
            FrameNumber(), npc:GetClass(), hg, hgN,
            armorPath, ageStr, dmg_in, dmg_final))
    end
end)

CALIBER.LoadConfig()
dprint(1, string.format("config loaded: wl=%d bl=%d",table.Count(CALIBER.UserWhitelist),table.Count(CALIBER.UserBlacklist)))

-- Net namespacing vía primitiva Corpus.Net.Register (Caliber_Architecture.md §6):
-- registra "corpus_caliber_<msg>"; AddNetworkString solo en server (idempotente).
-- Los net.Start/net.Receive de abajo usan ya el nombre completo que devuelve.
for _, msg in ipairs({
    "request_lists", "send_lists", "modify_list", "inspect_result", "admin_action",
    "request_catalog_state", "catalog_state", "scan_world", "scan_world_result",
    "request_armor", "armor_data", "save_armor", "save_armor_batch",
    "tool_apply", "tool_copy", "tool_copy_result",
    "request_weapons_data", "weapons_data", "save_curated", "save_ammo_fallback",
    "request_scav_weights", "scav_weights_data", "save_scav_weight", "shield_fx",
}) do
    Corpus.Net.Register("caliber", msg)
end

local function GetAdmins()
    local t = {}
    for _, p in ipairs(player.GetAll()) do
        if IsValid(p) and p:IsAdmin() then t[#t+1] = p end
    end
    return t
end

local function SerializeLists()
    local json = util.TableToJSON({whitelist=CALIBER.UserWhitelist,blacklist=CALIBER.UserBlacklist})
    return util.Compress(json)
end

local function SendListsTo(ply)
    if not IsValid(ply) then return end
    local data = SerializeLists()
    net.Start("corpus_caliber_send_lists")
    net.WriteUInt(#data, 32)
    net.WriteData(data, #data)
    net.Send(ply)
end

local function BroadcastListsToAdmins()
    -- Debounce: coalesce múltiples llamadas en 0.1s en un solo envío
    timer.Create("caliber_broadcast_debounce", 0.1, 1, function()
        local admins = GetAdmins()
        if #admins == 0 then return end
        local data = SerializeLists()
        net.Start("corpus_caliber_send_lists")
        net.WriteUInt(#data, 32)
        net.WriteData(data, #data)
        net.Send(admins)
    end)
end

CALIBER.SendListsTo = SendListsTo
CALIBER.BroadcastListsToAdmins = BroadcastListsToAdmins

net.Receive("corpus_caliber_request_lists",function(_,ply) if IsValid(ply) then SendListsTo(ply) end end)

net.Receive("corpus_caliber_modify_list",function(_,ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local action=net.ReadString()

    -- Los cambios de whitelist pueden dar/quitar escudo a NPCs vivos de la clase
    -- (corpus_caliber_shields.lua carga después vía el manifest: guard). bl_add también aplica: quita el
    -- entry de whitelist (_BlAddNoSave) → InitShield remueve el escudo.
    local function RefreshShield(class)
        if CALIBER.RefreshShieldsForClass then CALIBER.RefreshShieldsForClass(class) end
    end

    -- Acciones individuales (toolgun, compatibilidad hacia atrás)
    if action=="wl_add" then
        local classname=net.ReadString()
        local data=net.ReadTable()
        CALIBER.AddToWhitelist(classname,data)
        RefreshShield(classname)
    elseif action=="wl_del" then
        local classname=net.ReadString()
        CALIBER.RemoveFromWhitelist(classname)
        RefreshShield(classname)
    elseif action=="bl_add" then
        local classname=net.ReadString()
        CALIBER.AddToBlacklist(classname)
        RefreshShield(classname)
    elseif action=="bl_del" then
        CALIBER.RemoveFromBlacklist(net.ReadString())

    -- Acciones batch (browser masivo): una sola SaveConfig + broadcast al final
    elseif action=="wl_add_batch" then
        local payload=net.ReadTable()
        local classes=net.ReadTable()
        for _,class in ipairs(classes) do _WlAddNoSave(class,payload) end
        CALIBER.SaveConfig()
        for _,class in ipairs(classes) do RefreshShield(class) end
    elseif action=="bl_add_batch" then
        local classes=net.ReadTable()
        for _,class in ipairs(classes) do _BlAddNoSave(class) end
        CALIBER.SaveConfig()
        for _,class in ipairs(classes) do RefreshShield(class) end
    elseif action=="del_batch" then
        local classes=net.ReadTable()
        for _,class in ipairs(classes) do _WlDelNoSave(class) _BlDelNoSave(class) end
        CALIBER.SaveConfig()
        for _,class in ipairs(classes) do RefreshShield(class) end
    end

    BroadcastListsToAdmins()
end)

net.Receive("corpus_caliber_admin_action",function(_,ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local action=net.ReadString()
    if action=="clear_wl" then CALIBER.ClearWhitelist()
    elseif action=="clear_bl" then CALIBER.ClearBlacklist()
    elseif action=="reload" then CALIBER.LoadConfig()
    elseif action=="save" then CALIBER.SaveConfig() end
    -- reload/clear_wl pueden cambiar la config de escudo de cualquier clase
    if (action=="reload" or action=="clear_wl") and CALIBER.RefreshAllShields then
        CALIBER.RefreshAllShields()
    end
    BroadcastListsToAdmins()
end)

net.Receive("corpus_caliber_request_catalog_state", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local classnames = net.ReadTable()
    if type(classnames) ~= "table" then return end

    -- Filtrar a un orden limpio (el cliente solo manda strings, pero por las dudas).
    local list = {}
    for _, class in ipairs(classnames) do
        if type(class) == "string" and class ~= "" then
            list[#list + 1] = class
        end
    end

    -- Respuesta como array paralelo al orden recibido: NO se repiten los classnames
    -- ni las keys de tabla. net.WriteTable los repetía por entrada -> overflow.
    net.Start("corpus_caliber_catalog_state")
    net.WriteUInt(#list, 16)
    for _, class in ipairs(list) do
        net.WriteString(CALIBER.GetClassStatus(class))
        net.WriteBool(CALIBER.ArmorProfiles[class] ~= nil)
    end
    net.Send(ply)
end)

net.Receive("corpus_caliber_scan_world", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local seen = {}
    for _, e in ipairs(ents.GetAll()) do
        if IsValid(e) and e:IsNPC() then
            seen[e:GetClass()] = true
        end
    end
    local out = {}
    for class, _ in pairs(seen) do table.insert(out, class) end
    net.Start("corpus_caliber_scan_world_result")
    net.WriteTable(out)
    net.Send(ply)
end)

net.Receive("corpus_caliber_request_armor", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local classname = net.ReadString()
    if not classname or classname == "" then return end

    -- Fuente preferida: el perfil de clase guardado (autoridad canónica).
    local profile = CALIBER.ArmorProfiles[classname]
    local src     = "profile"
    -- Fallback: sin perfil de clase, copiar la armadura REAL de una instancia viva
    -- blindada (aplicada por toolgun, init previa, o perfil no persistido). Así el copy
    -- del browser refleja lo que el NPC tiene puesto, sin exigir un whitelist previo.
    if (not profile or not next(profile)) and CALIBER.ReadArmorNWvars then
        -- FindByClass no encuentra keys de spawnmenu: recorrer matcheando
        -- classname O NPCName (NPCs de addon con clase genérica)
        for _, e in ipairs(ents.GetAll()) do
            if IsValid(e) and e:IsNPC()
               and (e:GetClass() == classname or e.NPCName == classname)
               and e:GetNWBool("Caliber_Armor_Init", false) then
                local live = CALIBER.ReadArmorNWvars(e)
                if next(live) then profile = live src = "live" break end
            end
        end
    end
    profile = profile or {}

    dprint(2, "armor request", classname, "source="..src,
        "zones="..(type(profile.zones)=="table" and table.Count(profile.zones) or 0))

    net.Start("corpus_caliber_armor_data")
    net.WriteString(classname)
    net.WriteTable(profile)
    net.Send(ply)
end)

net.Receive("corpus_caliber_save_armor", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local classname = net.ReadString()
    local raw       = net.ReadTable()
    if not classname or classname == "" then return end

    local clean = SanitizeArmor(raw)
    CALIBER.ArmorProfiles[classname] = clean  -- nil borra el perfil de la clase
    CALIBER.SaveConfig()

    -- Re-init NWvars en instancias vivas de esa clase (o de esa key de spawnmenu)
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:IsNPC()
           and (ent:GetClass() == classname or ent.NPCName == classname) then
            CALIBER.InitArmorNWvars(ent)
        end
    end

    -- ACK: devolver perfil sanitizado para que el editor refresque
    net.Start("corpus_caliber_armor_data")
    net.WriteString(classname)
    net.WriteTable(CALIBER.ArmorProfiles[classname] or {})
    net.Send(ply)
end)

-- Aplica el mismo perfil de armadura a un lote de clases en un solo SaveConfig.
-- Profile vacío ({}) -> SanitizeArmor devuelve nil -> borra armadura en todas las clases.
net.Receive("corpus_caliber_save_armor_batch", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local classes = net.ReadTable()
    local raw     = net.ReadTable()
    if type(classes) ~= "table" or #classes == 0 then return end

    local clean = SanitizeArmor(raw)   -- nil si perfil vacío (borra armadura)
    for _, classname in ipairs(classes) do
        if type(classname) == "string" and classname ~= "" then
            CALIBER.ArmorProfiles[classname] = clean
        end
    end
    CALIBER.SaveConfig()

    -- Re-init NWvars en instancias vivas de las clases (o keys) modificadas
    local classSet = {}
    for _, classname in ipairs(classes) do classSet[classname] = true end
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:IsNPC()
           and (classSet[ent:GetClass()] or (isstring(ent.NPCName) and classSet[ent.NPCName])) then
            CALIBER.InitArmorNWvars(ent)
        end
    end
end)

-- ── Debug toolgun: aplicar armadura/limbs per-entity (efímero, sin JSON) ────
net.Receive("corpus_caliber_tool_apply", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local ent     = net.ReadEntity()
    local doArmor = net.ReadBool()
    local doLimbs = net.ReadBool()
    local profile = net.ReadTable()
    local hf      = net.ReadFloat()
    local af      = net.ReadFloat()
    local lf      = net.ReadFloat()
    if not IsValid(ent) or not ent:IsNPC() then return end
    if doArmor then
        if CALIBER.ApplyArmorDirect then CALIBER.ApplyArmorDirect(ent, profile) end
        ent.Caliber_ToolArmorOverride = true
    end
    if doLimbs then
        if CALIBER.ResizeLimbPools then CALIBER.ResizeLimbPools(ent, hf, af, lf) end
    end
    local armorStr = doArmor and "armor applied" or "armor skipped"
    local limbStr  = doLimbs and "limbs resized" or "limbs skipped"
    ply:SendLua(string.format(
        "notification.AddLegacy('Caliber: NPC updated (%s, %s)', NOTIFY_GENERIC, 4) surface.PlaySound('buttons/button14.wav')",
        armorStr, limbStr))
end)

-- ── Debug toolgun: leer armadura+limbs de un NPC vivo y devolver al cliente ──
net.Receive("corpus_caliber_tool_copy", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local ent = net.ReadEntity()
    if not IsValid(ent) or not ent:IsNPC() then return end
    -- Leer NWvars de armadura viva (helper puro en corpus_caliber_armor.lua)
    local profile = CALIBER.ReadArmorNWvars and CALIBER.ReadArmorNWvars(ent) or {}
    -- Reconstruir fracs de limbs desde Caliber_SpawnHP
    local hf, af, lf = 0.5, 0.5, 0.5
    local spawnHP = ent.Caliber_SpawnHP
    if spawnHP and spawnHP > 0 and ent.Caliber_HP_HeadMax then
        hf = math.Round(ent.Caliber_HP_HeadMax / spawnHP, 2)
        af = math.Round(ent.Caliber_HP_ArmLMax / spawnHP, 2)
        lf = math.Round(ent.Caliber_HP_LegLMax / spawnHP, 2)
    end
    net.Start("corpus_caliber_tool_copy_result")
    net.WriteTable(profile)
    net.WriteFloat(hf)
    net.WriteFloat(af)
    net.WriteFloat(lf)
    net.Send(ply)
end)

-- ── Weapons tab (Caliber Configuration) — curated weapon penetration + ammo fallback ──

local function SendWeaponsDataTo(ply)
    if not IsValid(ply) then return end
    net.Start("corpus_caliber_weapons_data")
    net.WriteTable(CALIBER.CuratedWeapons or {})
    net.WriteTable(CALIBER.AmmoFallback or {})
    net.Send(ply)
end

net.Receive("corpus_caliber_request_weapons_data", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    SendWeaponsDataTo(ply)
end)

net.Receive("corpus_caliber_save_curated", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local classname = net.ReadString()
    local raw       = net.ReadTable()
    if not classname or classname == "" then return end

    local clean = CALIBER.SanitizeCuratedWeapon and CALIBER.SanitizeCuratedWeapon(raw) or nil
    CALIBER.CuratedWeapons[classname] = clean  -- nil borra la entrada
    CALIBER.SaveConfig()
    SendWeaponsDataTo(ply)
end)

net.Receive("corpus_caliber_save_ammo_fallback", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local raw = net.ReadTable()

    if CALIBER.SanitizeAmmoFallback then
        CALIBER.AmmoFallback = CALIBER.SanitizeAmmoFallback(raw)
    end
    CALIBER.SaveConfig()
    SendWeaponsDataTo(ply)
end)

-- ARC9 compatibility: disable arc9_mod_bodydamagecancel because it inflates
-- limb damage to NPCs ~32x and conflicts with Caliber zonal damage handling.
-- Detection is generic via the global ARC9 table, so it works regardless of
-- which Workshop upload of ARC9 the server uses.
CreateConVar("caliber_arc9_compat", "1", FCVAR_ARCHIVE,
    "Auto-disable arc9_mod_bodydamagecancel when ARC9 is detected (recommended)")

hook.Add("InitPostEntity", "Caliber_ARC9_Compat", function()
    if not GetConVar("caliber_arc9_compat"):GetBool() then return end
    if not istable(ARC9) then return end

    -- Shim 1: disable bodydamagecancel (inflates limb damage ~32x vs NPCs)
    local cv = GetConVar("arc9_mod_bodydamagecancel")
    if not cv then
        Corpus.Log("caliber", "[Caliber] ARC9 detected but arc9_mod_bodydamagecancel cvar not found, skipping compat shim")
        return
    end
    if cv:GetInt() ~= 0 then
        cv:SetInt(0)
        Corpus.Log("caliber", "[Caliber] ARC9 detected: forced arc9_mod_bodydamagecancel to 0 (limb damage compat)")
    end

    -- Shim 2: detour AfterShotFunction to roll armor pre-call and stash the
    -- result on the entity. ScaleNPCDamage consumes the stash (see above).
    -- We cannot hook post-line-846 (no official hook exists), and the
    -- Hook_BulletImpact observational hook is overwritten by line 846 anyway.
    local baseSwep = weapons.GetStored("arc9_base")
    if not baseSwep then
        Corpus.Log("caliber", "[Caliber] arc9_base not found, armor detour skipped")
        return
    end
    local origASF = baseSwep.AfterShotFunction
    if not origASF then
        Corpus.Log("caliber", "[Caliber] arc9_base.AfterShotFunction not found, armor detour skipped")
        return
    end

    baseSwep.AfterShotFunction = function(self, tr, dmg, range, penleft, alreadypenned, secondary)
        local ent = tr and tr.Entity
        if IsValid(ent) and ent:IsNPC()
            and CALIBER.GetZone and CALIBER.ExtractBulletData and CALIBER.ResolveArmor
            and CALIBER.IsArmored and CALIBER.IsArmored(ent)
        then
            -- Escudo arriba: el round se detiene en el escudo (no-overflow §4).
            -- NO resolver armadura ni depositar stash — la placa no participa.
            -- El drain real lo hace ProcessShield en ScaleNPCDamage (una sola
            -- autoridad); acá solo se predice para cortar penleft. Entre detour
            -- y hook nada regenera (la regen es Think) → la predicción coincide.
            if CALIBER.ShieldWillAbsorb and CALIBER.ShieldWillAbsorb(ent, dmg) then
                if DBG:GetInt() >= 3 and _dbgPass(ent) then
                    Corpus.Log("caliber", string.format(
                        "[Caliber DET] SHIELD-STOP f=%d  %s  hg=%d(%s)  penleft->0  (sin stash)",
                        FrameNumber(), ent:GetClass(), tr.HitGroup,
                        (_HG_NAME[tr.HitGroup] or tostring(tr.HitGroup))))
                end
                return origASF(self, tr, dmg, range, 0, alreadypenned, secondary)
            end
            local zona = CALIBER.GetZone(ent, tr.HitGroup)
            if zona and bit.band(dmg:GetDamageType(), BLOCKABLE) ~= 0 then
                local tuple = CALIBER.ExtractBulletData(self, dmg)
                tuple.damage = 1.0  -- normalize: res.fleshDmg becomes a pure factor
                local res = CALIBER.ResolveArmor(zona, tuple, tr.HitGroup)
                -- Tier 3: clasificar sobreescritura de stash antes de depositar (race detection)
                local _sv = "NEW"
                if DBG:GetInt() >= 3 and _dbgPass(ent) then
                    local prev = ent.Caliber_ArmorStash
                    if prev then
                        _sv = (FrameNumber() - prev.frame == 0) and "OVERWRITE!" or "replace-stale"
                    end
                end
                ent.Caliber_ArmorStash = {
                    factor     = res.fleshDmg,
                    newDur     = res.newDur,
                    durKey     = zona.durKey,
                    material   = zona.material,   -- lo consume PlayArmorSounds (clang por material)
                    frame      = FrameNumber(),
                    -- Block FX: trace real del impacto (los paths inline no lo tienen)
                    hitPos     = tr.HitPos,
                    hitNormal  = tr.HitNormal,    -- apunta HACIA AFUERA de la superficie
                    -- debug fields (consumed by ScaleNPCDamage trace only)
                    penetra    = (res.factorPenleft > 0),
                    armorClass = zona.clase,
                    durBefore  = zona.durActual,
                    penPower   = tuple.penPower,
                    src        = tuple.source,
                }
                -- Tier 3: log DET (deposito en detour)
                if DBG:GetInt() >= 3 and _dbgPass(ent) then
                    local hgN    = _HG_NAME[tr.HitGroup] or tostring(tr.HitGroup)
                    local penIn  = type(penleft) == "number" and string.format("%.2f", penleft) or tostring(penleft)
                    local penRes = res.factorPenleft == 0 and "STOP" or string.format("PEN(%.2f)", res.factorPenleft)
                    Corpus.Log("caliber", string.format(
                        "[Caliber DET] f=%d  %s  hg=%d(%s)  alreadypen=%-5s  sec=%-5s  penleft=%s->%s  raw=%.2f",
                        FrameNumber(), ent:GetClass(), tr.HitGroup, hgN,
                        tostring(alreadypenned), tostring(secondary), penIn, penRes, dmg:GetDamage()))
                    Corpus.Log("caliber", string.format(
                        "          zona=cls%d/%s  factor=%.4f  penPow=%.0f  src=%s  stash=%s",
                        zona.clase, tostring(zona.durKey), res.fleshDmg,
                        tuple.penPower or 0, tuple.source or "-", _sv))
                end
                if res.factorPenleft == 0 then
                    penleft = 0  -- round stopped by plate; Penetrate exits at penleft<=0 guard
                end
            end
        end
        return origASF(self, tr, dmg, range, penleft, alreadypenned, secondary)
    end

    Corpus.Log("caliber", "[Caliber] ARC9 AfterShotFunction armor detour installed")
end)


-- ── Compat "Visceral Dynamic Blood base" (repack de zippy/NGBR animated blood) ──
-- Integración SIN dependencia: si el addon no está montado, este bloque es no-op.
-- Su hook EntityTakeDamage delega en métodos de metatable per-hit → detour con
-- early-return cuando el hit fue BLOQUEADO por Caliber (token fresco, ≤1 frame).
-- Imprescindible además del DONT_BLEED: su gate hasRedBlood() bypasea el blood
-- color en NPCs VJ (IsVJBaseSNPC + BloodColor=="Red" / CustomBlood_Decal).
-- NO tocar su hook EntityFireBullets (retorna true y se re-lanza a sí mismo con
-- una flag interna; interferir rompe su captura de HitPos).
hook.Add("InitPostEntity", "Caliber_AnimBlood_Compat", function()
    if ANIMATED_SPLATTER_EFFECT == nil then return end  -- addon ausente → no-op

    local ENTMETA = FindMetaTable("Entity")
    local n = 0
    for _, name in ipairs({ "RealisticBlood_BulletDamage",
                            "RealisticBlood_OtherDamage",
                            "RealisticBlood_PhysDamage" }) do
        local orig = ENTMETA[name]
        if orig then
            ENTMETA[name] = function(self, ...)
                local tok = self.Caliber_BlockedHitToken
                if tok and BLK_NB:GetBool() and (FrameNumber() - tok) <= 1 then
                    if DBG:GetInt() >= 2 and _dbgPass(self) then
                        dprint(2, "blockfx visceral-suppress " .. name .. "  " .. self:GetClass())
                    end
                    return  -- hit bloqueado por armadura: sin FX de sangre visceral
                end
                return orig(self, ...)
            end
            n = n + 1
        end
    end

    -- Visceral RE-ejecuta el último daño sobre el ragdoll de muerte
    -- (CreateEntityRagdoll_RealisticBlood + RealisticBlood_LastDMGINFO). Si el
    -- hit letal fue bloqueado, propagar el token al rag para gatear también ahí.
    hook.Add("CreateEntityRagdoll", "Caliber_AnimBlood_RagdollToken", function(own, rag)
        local tok = own.Caliber_BlockedHitToken
        if tok and (FrameNumber() - tok) <= 1 and IsValid(rag) then
            rag.Caliber_BlockedHitToken = tok
        end
    end)

    Corpus.Log("caliber", "[Caliber] Visceral/Animated Blood detectado: supresion por bloqueo instalada (" .. n .. " metodos)")
end)
