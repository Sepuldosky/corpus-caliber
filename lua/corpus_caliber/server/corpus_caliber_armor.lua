-- corpus_caliber_armor.lua — extractor y resolver de armadura (server)
-- Migrado desde ADS 2.0 (ads_armor.lua). Funciones puras: sin hooks, sin NWvars, sin call sites.
local CALIBER = Corpus.GetModule("caliber")

-- §10 -- Material definitions
-- coefDestruc : plate wear multiplier per hit (higher = degrades faster)
-- blunt       : fraction of blocked damage that leaks as blunt trauma
-- hard        : true = placa rígida/metálica (emite clang metálico al impactar);
--               false = placa blanda/textil o fluido (no clanguea) -- lo lee el
--               feedback sonoro en caliber_core, no la matemática del resolver
CALIBER.Materials = {
    aramid             = { coefDestruc = 0.25, blunt = 0.30, hard = false },
    titanium           = { coefDestruc = 0.50, blunt = 0.20, hard = true  },
    ceramic            = { coefDestruc = 0.85, blunt = 0.15, hard = true  },
    poly_ceramic       = { coefDestruc = 0.10, blunt = 0.05, hard = true  },
    nano_titanium      = { coefDestruc = 0.35, blunt = 0.00, hard = true  },
    electrified_aramid = { coefDestruc = 0.25, blunt = 0.30, hard = false },
    m_stf              = { coefDestruc = 0.15, blunt = 0.45, hard = false },
    uranium_matrix     = { coefDestruc = 0.75, blunt = 0.10, hard = true  },
}

-- §4 -- Ammo type fallback table (~6 EFT-equivalent granularity buckets)
-- Used when the weapon carries no EFT round data and no curated entry exists.
-- AmmoFallbackDefaults is immutable (never mutated at runtime) so buckets can always
-- be reset. AmmoFallback is the live/working copy the extractor actually reads;
-- LoadArmorData() rebuilds it from defaults + JSON overrides on every (re)load.
CALIBER.AmmoFallbackDefaults = {
    pistol  = { penPower = 20, armorDamage = 25, penChanceBase = 0.20 },
    smg     = { penPower = 28, armorDamage = 30, penChanceBase = 0.30 },
    rifle   = { penPower = 42, armorDamage = 45, penChanceBase = 0.50 },
    magnum  = { penPower = 38, armorDamage = 55, penChanceBase = 0.40 },
    shotgun = { penPower = 12, armorDamage = 20, penChanceBase = 0.10 },
    sniper  = { penPower = 60, armorDamage = 70, penChanceBase = 0.75 },
}
CALIBER.AmmoFallback = table.Copy(CALIBER.AmmoFallbackDefaults)

-- §4 -- Ammo type string normalization: GMod ammo names -> AmmoFallback bucket keys.
-- SniperRound (VJ) and SniperPenetratedRound (TFA) both map to "sniper".
CALIBER.AmmoAlias = {
    Pistol                = "pistol",
    SMG1                  = "smg",
    AR2                   = "rifle",
    GenericRifle          = "rifle",
    ["357"]               = "magnum",
    buckshot              = "shotgun",
    Buckshot              = "shotgun",   -- capitalization varies between sources
    SniperRound           = "sniper",
    SniperPenetratedRound = "sniper",
}

-- ── Ammo fallback validation (Weapons tab, Caliber Configuration) ───────────────

-- Clamps a partial bucket override; missing fields fall back to `base`'s values.
local function ClampAmmoBucket(raw, base)
    if type(raw) ~= "table" then return nil end
    return {
        penPower      = math.Clamp(tonumber(raw.penPower)      or base.penPower,    1, 115),
        armorDamage   = math.Clamp(tonumber(raw.armorDamage)   or base.armorDamage, 1, 120),
        penChanceBase = math.Round(math.Clamp(tonumber(raw.penChanceBase) or base.penChanceBase, 0, 1) * 100) / 100,
    }
end

-- Sanitiza los 6 buckets enviados por el tab Weapons. Ignora keys desconocidas;
-- cada bucket conocido siempre está presente en el resultado (usa su default si
-- el cliente no lo mandó o mandó basura). La usa corpus_caliber_save_ammo_fallback antes de
-- reemplazar CALIBER.AmmoFallback por completo.
function CALIBER.SanitizeAmmoFallback(raw)
    local out = {}
    for bucket, def in pairs(CALIBER.AmmoFallbackDefaults) do
        local r = type(raw) == "table" and raw[bucket] or nil
        out[bucket] = ClampAmmoBucket(r, def) or table.Copy(def)
    end
    return out
end

-- Solo los buckets que difieren de AmmoFallbackDefaults, para persistir en JSON
-- lo mínimo (buckets no tocados no se escriben a disco).
function CALIBER.GetAmmoFallbackOverrides()
    local out = {}
    for bucket, def in pairs(CALIBER.AmmoFallbackDefaults) do
        local cur = CALIBER.AmmoFallback[bucket]
        if cur and (cur.penPower ~= def.penPower
                 or cur.armorDamage ~= def.armorDamage
                 or cur.penChanceBase ~= def.penChanceBase) then
            out[bucket] = { penPower = cur.penPower, armorDamage = cur.armorDamage, penChanceBase = cur.penChanceBase }
        end
    end
    return out
end

-- Valida una entrada curada individual (Weapons tab). nil = borrar entrada (el
-- arma vuelve a EFT-en-vivo/fallback según la jerarquía normal del extractor).
function CALIBER.SanitizeCuratedWeapon(raw)
    if type(raw) ~= "table" then return nil end
    local pp, ad, pc = tonumber(raw.penPower), tonumber(raw.armorDamage), tonumber(raw.penChanceBase)
    if not (pp and ad and pc) then return nil end
    local out = {
        penPower      = math.Clamp(pp, 1, 115),
        armorDamage   = math.Clamp(ad, 1, 120),
        penChanceBase = math.Round(math.Clamp(pc, 0, 1) * 100) / 100,
    }
    -- Flags de escudo (plasma/emp): manuales, no existen en ninguna base de armas.
    -- Solo se persisten si son true. Los lee ProcessShield directo de
    -- CALIBER.CuratedWeapons — independiente del tuple balístico, así una entrada
    -- con flags no altera la jerarquía del extractor (EFT sigue ganando).
    if raw.plasma == true then out.plasma = true end
    if raw.emp == true then out.emp = true end
    return out
end

-- Curated non-EFT weapon table; populated by the JSON loader in Block 2.
CALIBER.CuratedWeapons = CALIBER.CuratedWeapons or {}

-- ── ConVars ──────────────────────────────────────────────────────────────────

local PEN_OVER = CreateConVar("caliber_pen_over_adj",       "0.5",  FCVAR_ARCHIVE,
    "Penetration chance bonus per unit of penPower/armorClass ratio above 1.0")
local DUR_ADJ  = CreateConVar("caliber_dur_adj",             "0.25", FCVAR_ARCHIVE,
    "Penetration chance bonus gained as plate durability decreases toward 0")
local DETERMIN = CreateConVar("caliber_armor_deterministic", "0",    FCVAR_ARCHIVE,
    "1 = deterministic pen roll (penChance>=0.5 penetrates); 0 = probabilistic (EFT default)")

-- ── CALIBER.ExtractBulletData ────────────────────────────────────────────────────

-- Normalizes weapon and bullet info into a unified EFT-style tuple (§5).
-- Three branches, best-data-first: EFT round -> curated table -> ammo fallback.
-- wep     : the SWEP that fired (may be invalid for world/env damage)
-- dmginfo : CTakeDamageInfo userdata -- do NOT inject fields into it
-- Returns { damage, penPower, armorDamage, penChanceBase, source }
function CALIBER.ExtractBulletData(wep, dmginfo)
    local baseDmg = dmginfo:GetDamage()

    -- Branch 1: EFT round via ARC9 Darsu (HasAmmoooooooo attachment stat present)
    if IsValid(wep) and wep.GetProcessedValue and wep:GetProcessedValue("HasAmmoooooooo", true) then
        return {
            damage        = baseDmg,
            penPower      = wep:GetProcessedValue("Penetration",           true) or 20,
            armorDamage   = (wep:GetProcessedValue("ArmorPiercing",        true) or 0.25) * 100,
            penChanceBase = wep:GetProcessedValue("EFTPenetrationChance",  true) or 0.20,
            source        = "eft",
        }
    end

    -- Branch 2: curated weapon table (server-curated by admin) -- cualquier
    -- classname válido, sin requerir ARC9. Cubre VJ/TFA/ARC9-sin-EFT por igual.
    if IsValid(wep) then
        local curated = CALIBER.CuratedWeapons[wep:GetClass()]
        if curated then
            return {
                damage        = baseDmg,
                penPower      = curated.penPower,
                armorDamage   = curated.armorDamage,
                penChanceBase = curated.penChanceBase,
                source        = "curated",
            }
        end
    end

    -- Branch 3: ammo type fallback (VJ Base, HL2 vanilla, uncurated TFA/ARC9)
    local ammoName = game.GetAmmoName(dmginfo:GetAmmoType()) or ""
    local bucket   = CALIBER.AmmoAlias[ammoName]
               or CALIBER.AmmoAlias[string.lower(ammoName)]
    local fallback = (bucket and CALIBER.AmmoFallback[bucket]) or CALIBER.AmmoFallback["pistol"]

    local src = (IsValid(wep) and string.find(wep:GetClass(), "tfa_", 1, true))
                and "tfa" or "fallback"

    return {
        damage        = baseDmg,
        penPower      = fallback.penPower,
        armorDamage   = fallback.armorDamage,
        penChanceBase = fallback.penChanceBase,
        source        = src,
    }
end

-- ── CALIBER.ResolveArmor ─────────────────────────────────────────────────────────

-- Pure armor penetration resolver. Implements §11 steps 0-3 exactly.
-- zona     = { clase, durActual, durMax, material }  (call site reads from NWvars)
-- tuple    = result of CALIBER.ExtractBulletData
-- hitgroup = HITGROUP_* constant of the impacted zone
--
-- Returns { fleshDmg, newDur, factorPenleft }
--   fleshDmg      (doc: dañoCarne)    -- damage forwarded to caliber_limbs / native HP
--   newDur        (doc: nuevaDur)     -- updated plate durability; call site writes NWvar
--   factorPenleft (doc: factorPenleft)-- energy fraction for ARC9 penleft (0 = bullet stopped)
function CALIBER.ResolveArmor(zona, tuple, hitgroup)
    -- Paso 0: hitgroup not covered by this NPC's armor profile -> full passthrough
    -- Damage-type gate (DMG_BULLET etc.) is handled upstream in caliber_core before calling here
    if not zona then
        return { fleshDmg = tuple.damage, newDur = nil, factorPenleft = 1 }
    end

    local mat = CALIBER.Materials[zona.material] or CALIBER.Materials["aramid"]

    -- Paso 1: penetration probability
    -- Anchor: ratio==1 && durFactor==1 -> penChance == penChanceBase (real EFT value)
    local durFactor      = zona.durMax > 0 and (zona.durActual / zona.durMax) or 0
    local armorEffective = math.max(1, zona.clase * 10)
    local ratio          = tuple.penPower / armorEffective

    local penChance = tuple.penChanceBase
                    + PEN_OVER:GetFloat() * (ratio - 1)
                    + DUR_ADJ:GetFloat()  * (1 - durFactor)
    penChance = math.Clamp(penChance, 0, 1)

    -- Paso 2: penetration roll
    local penetra
    if DETERMIN:GetBool() then
        penetra = (penChance >= 0.5)
    else
        penetra = (math.random() <= penChance)
    end

    local fleshDmg, newDur, factorPenleft

    if not penetra then
        -- Paso 3a: BLOCKED
        -- Blunt factor is reduced by armor class; hardcoded floor of 5% (no profile can go below)
        local bluntFactor = math.max(0.05, mat.blunt * (1 - (zona.clase - 1) * 0.1))
        fleshDmg      = tuple.damage * bluntFactor
        factorPenleft = 0

        -- Blocking damages plate more than penetrating; wear scales with degradation
        local deltaD = tuple.armorDamage * mat.coefDestruc * (1.2 - durFactor)
        newDur       = math.max(0, zona.durActual - deltaD)
    else
        -- Paso 3b: PENETRATED
        local resistRatio     = math.Clamp(armorEffective / tuple.penPower, 0, 1)
        local penDamageFactor = math.max(0.4, 1 - resistRatio * 0.5)

        fleshDmg      = tuple.damage * penDamageFactor
        factorPenleft = penDamageFactor

        -- Penetrating halves armor wear vs blocking (EFT fidelity)
        local deltaD = tuple.armorDamage * mat.coefDestruc * (1.2 - durFactor) * 0.5
        newDur       = math.max(0, zona.durActual - deltaD)
    end

    return { fleshDmg = fleshDmg, newDur = newDur, factorPenleft = factorPenleft }
end

-- ── Armor profiles + curated weapons (Block 2) ──────────────────────────────

-- Perfiles de armadura por classname de NPC. Los puebla CALIBER.LoadArmorData desde
-- la clave "armor" de la config (Corpus.Data.Load("caliber","config")). Se guardan
-- verbatim (espejo del JSON):
--   profile = { zones = { ["1"]={class,dur_max,material}, ... },
--               fallback_generic = { class,dur_max,material },  -- opcional
--               coverage_profile = "head_torso" }               -- metadata UI, opaca aquí
CALIBER.ArmorProfiles = CALIBER.ArmorProfiles or {}

-- Puebla CALIBER.ArmorProfiles y CALIBER.CuratedWeapons desde una tabla de config parseada.
-- La llama LoadConfig de caliber_core tras leer/parsear el JSON (caliber_core es el único
-- dueño del archivo). Reemplaza ambas tablas por completo en cada llamada.
function CALIBER.LoadArmorData(parsed)
    CALIBER.ArmorProfiles  = {}
    CALIBER.CuratedWeapons = {}
    CALIBER.AmmoFallback   = table.Copy(CALIBER.AmmoFallbackDefaults)  -- reset antes de aplicar overrides
    if type(parsed) ~= "table" then return end

    if type(parsed.armor) == "table" then
        for class, profile in pairs(parsed.armor) do
            if type(class) == "string" and type(profile) == "table" then
                -- Normalizar claves de zonas a string ("1".."7"): util.JSONToTable
                -- convierte claves numéricas de objeto JSON en números de Lua, y el
                -- contrato del data model (§8) es clave string. El browser indexa
                -- zones["1"].."7"] — con claves numéricas el primer doble-clic tras
                -- cargar del disco copiaba vacío (recién funcionaba tras re-guardar,
                -- porque SanitizeArmor re-normaliza). El runtime nunca lo notó:
                -- InitArmorNWvars/ApplyArmorDirect hacen tonumber(k) tolerante.
                if type(profile.zones) == "table" then
                    local zones = {}
                    for k, z in pairs(profile.zones) do
                        zones[tostring(k)] = z
                    end
                    profile.zones = zones
                end
                CALIBER.ArmorProfiles[class] = profile   -- resto verbatim; se valida al usar (Init/GetZone)
            end
        end
    end

    if type(parsed.curated_weapons) == "table" then
        for class, w in pairs(parsed.curated_weapons) do
            -- Exige los tres campos numéricos que lee el extractor; guarda la entrada
            -- verbatim (preserva "note") para que SaveConfig la round-trippee intacta.
            if type(class) == "string" and type(w) == "table"
               and tonumber(w.penPower) and tonumber(w.armorDamage) and tonumber(w.penChanceBase) then
                CALIBER.CuratedWeapons[class] = w
            end
        end
    end

    if type(parsed.ammo_fallback) == "table" then
        for bucket, override in pairs(parsed.ammo_fallback) do
            local def = CALIBER.AmmoFallbackDefaults[bucket]
            if def and type(override) == "table" then
                local clean = ClampAmmoBucket(override, def)
                if clean then CALIBER.AmmoFallback[bucket] = clean end
            end
        end
    end
end

-- Escribe las NWvars de armadura por zona al spawn de un NPC, desde su perfil de
-- clase. No-op si la clase no tiene perfil. fallback_generic ocupa el slot GENERIC
-- (0), que GetZone usa para cualquier hit sin zona específica.
function CALIBER.InitArmorNWvars(ent)
    if not IsValid(ent) then return end

    -- Limpiar slots previos (0=GENERIC, 1-7 hitgroups) antes de repoblar.
    -- Sin esto, re-init sobre un NPC vivo no refleja ediciones ni borrados de perfil:
    -- las NWvars viejas quedan y GetZone las sigue leyendo hasta el respawn.
    for hg = 0, 7 do
        ent:SetNWInt("Caliber_Armor_Class_"  .. hg, 0)
        ent:SetNWInt("Caliber_Armor_Dur_"    .. hg, 0)
        ent:SetNWInt("Caliber_Armor_MaxDur_" .. hg, 0)
        ent:SetNWString("Caliber_Armor_Mat_" .. hg, "")
    end

    -- Identidad: key de spawnmenu (si tiene config) > classname. El perfil de la
    -- key manda; si esa key no tiene perfil de armadura, cae al del classname
    -- (los perfiles se reemplazan, nunca se mezclan). GetConfigKey es lectura
    -- pura (tablas + campo de entidad) — la pureza de este archivo se mantiene.
    local key     = (CALIBER.GetConfigKey and CALIBER.GetConfigKey(ent)) or ent:GetClass()
    local profile = CALIBER.ArmorProfiles[key]
    if not profile and key ~= ent:GetClass() then
        profile = CALIBER.ArmorProfiles[ent:GetClass()]
    end
    if not profile then
        ent:SetNWBool("Caliber_Armor_Init", false)
        return
    end

    if type(profile.zones) == "table" then
        for k, z in pairs(profile.zones) do
            local hg = tonumber(k)
            if hg and type(z) == "table" and tonumber(z.class) and tonumber(z.dur_max) then
                ent:SetNWInt("Caliber_Armor_Class_"  .. hg, z.class)
                ent:SetNWInt("Caliber_Armor_Dur_"    .. hg, z.dur_max)   -- durActual arranca en max
                ent:SetNWInt("Caliber_Armor_MaxDur_" .. hg, z.dur_max)
                ent:SetNWString("Caliber_Armor_Mat_" .. hg, z.material or "aramid")
            end
        end
    end

    -- fallback_generic -> slot 0, solo si no se escribió una zona "0" explícita arriba
    local fg = profile.fallback_generic
    if type(fg) == "table" and tonumber(fg.class) and tonumber(fg.dur_max)
       and ent:GetNWInt("Caliber_Armor_Class_0", 0) == 0 then
        ent:SetNWInt("Caliber_Armor_Class_0",  fg.class)
        ent:SetNWInt("Caliber_Armor_Dur_0",    fg.dur_max)
        ent:SetNWInt("Caliber_Armor_MaxDur_0", fg.dur_max)
        ent:SetNWString("Caliber_Armor_Mat_0", fg.material or "aramid")
    end

    ent:SetNWBool("Caliber_Armor_Init", true)

    if GetConVar("caliber_debug") and GetConVar("caliber_debug"):GetInt() >= 2 then
        Corpus.Log("caliber", "[Caliber] armor init " .. ent:GetClass())
    end
end

-- Lee el estado vivo de armadura de un hitgroup desde NWvars y arma el tuple zona
-- que consume el resolver. Devuelve nil cuando el hitgroup no tiene placa (-> Paso 0
-- passthrough). 'durKey' le dice al call site en qué slot NWvar reescribir la
-- durabilidad (el hg impactado, o 0 cuando se resolvió vía fallback).
function CALIBER.GetZone(ent, hg)
    if not IsValid(ent) or not ent:GetNWBool("Caliber_Armor_Init", false) then return nil end

    local cls = ent:GetNWInt("Caliber_Armor_Class_" .. hg, 0)
    if cls > 0 then
        return {
            clase     = cls,
            durActual = ent:GetNWInt("Caliber_Armor_Dur_"    .. hg, 0),
            durMax    = ent:GetNWInt("Caliber_Armor_MaxDur_" .. hg, 0),
            material  = ent:GetNWString("Caliber_Armor_Mat_" .. hg, "aramid"),
            durKey    = hg,
        }
    end

    -- Hitgroup sin cobertura: cae a la placa GENERIC (0) si existe
    if hg ~= 0 then
        local gcls = ent:GetNWInt("Caliber_Armor_Class_0", 0)
        if gcls > 0 then
            return {
                clase     = gcls,
                durActual = ent:GetNWInt("Caliber_Armor_Dur_0",    0),
                durMax    = ent:GetNWInt("Caliber_Armor_MaxDur_0", 0),
                material  = ent:GetNWString("Caliber_Armor_Mat_0", "aramid"),
                durKey    = 0,
            }
        end
    end

    -- Opción C: hit HITGROUP_GENERIC (0) sin slot FG → fallback a chest (2) luego stomach (3).
    -- Cubre NPCs humanoides cuyos modelos colapsan el torso a HITGROUP_GENERIC en vez de
    -- reportar chest/stomach. El durKey apunta al slot real para que la durabilidad
    -- descuente de la placa correcta y no de un slot 0 fantasma.
    -- No afecta NPCs no humanoides (Hunter, etc.): esos usan FG explícito que ya ganó arriba.
    if hg == 0 then
        for _, fallSlot in ipairs({ 2, 3 }) do
            local fcls = ent:GetNWInt("Caliber_Armor_Class_" .. fallSlot, 0)
            if fcls > 0 then
                return {
                    clase     = fcls,
                    durActual = ent:GetNWInt("Caliber_Armor_Dur_"    .. fallSlot, 0),
                    durMax    = ent:GetNWInt("Caliber_Armor_MaxDur_" .. fallSlot, 0),
                    material  = ent:GetNWString("Caliber_Armor_Mat_" .. fallSlot, "aramid"),
                    durKey    = fallSlot,
                }
            end
        end
    end

    return nil
end

-- Lee la armadura VIVA de una entidad desde sus NWvars y la arma como tabla de perfil
-- (mismo formato que CALIBER.ArmorProfiles / InitArmorNWvars: zones por hg string con
-- class/dur_max/material + fallback_generic). Función pura: solo lee NWvars del ent
-- dado (igual que GetZone), sin side-effects. Usa MaxDur (no la durabilidad actual)
-- para que el perfil copiado arranque con las placas llenas. Devuelve {} si el ent no
-- tiene armadura inicializada. Inversa de ApplyArmorDirect; la consumen el copy del
-- toolgun (corpus_caliber_tool_copy) y el fallback de corpus_caliber_request_armor.
function CALIBER.ReadArmorNWvars(ent)
    local profile = {}
    if not IsValid(ent) or not ent:GetNWBool("Caliber_Armor_Init", false) then return profile end

    local zones = {}
    for hg = 1, 7 do
        local cls = ent:GetNWInt("Caliber_Armor_Class_" .. hg, 0)
        if cls > 0 then
            zones[tostring(hg)] = {
                class    = cls,
                dur_max  = ent:GetNWInt("Caliber_Armor_MaxDur_" .. hg, 0),
                material = ent:GetNWString("Caliber_Armor_Mat_" .. hg, "aramid"),
            }
        end
    end
    if next(zones) then profile.zones = zones end

    local gcls = ent:GetNWInt("Caliber_Armor_Class_0", 0)
    if gcls > 0 then
        profile.fallback_generic = {
            class    = gcls,
            dur_max  = ent:GetNWInt("Caliber_Armor_MaxDur_0", 0),
            material = ent:GetNWString("Caliber_Armor_Mat_0", "aramid"),
        }
    end

    return profile
end

-- Aplica un perfil de armadura directamente a las NWvars de la entidad sin consultar
-- ArmorProfiles (que es config por clase). Usado por el toolgun debug para armadura
-- per-entity efímera. Formato de profile idéntico a InitArmorNWvars.
function CALIBER.ApplyArmorDirect(ent, profile)
    if not IsValid(ent) then return end
    -- Limpiar todos los slots primero (igual que InitArmorNWvars)
    for hg = 0, 7 do
        ent:SetNWInt("Caliber_Armor_Class_"  .. hg, 0)
        ent:SetNWInt("Caliber_Armor_Dur_"    .. hg, 0)
        ent:SetNWInt("Caliber_Armor_MaxDur_" .. hg, 0)
        ent:SetNWString("Caliber_Armor_Mat_" .. hg, "")
    end
    if type(profile) ~= "table" or not next(profile) then
        ent:SetNWBool("Caliber_Armor_Init", false)
        return
    end
    if type(profile.zones) == "table" then
        for k, z in pairs(profile.zones) do
            local hg = tonumber(k)
            if hg and type(z) == "table" and tonumber(z.class) and tonumber(z.dur_max) then
                ent:SetNWInt("Caliber_Armor_Class_"  .. hg, z.class)
                ent:SetNWInt("Caliber_Armor_Dur_"    .. hg, z.dur_max)
                ent:SetNWInt("Caliber_Armor_MaxDur_" .. hg, z.dur_max)
                ent:SetNWString("Caliber_Armor_Mat_" .. hg, z.material or "aramid")
            end
        end
    end
    local fg = profile.fallback_generic
    if type(fg) == "table" and tonumber(fg.class) and tonumber(fg.dur_max)
       and ent:GetNWInt("Caliber_Armor_Class_0", 0) == 0 then
        ent:SetNWInt("Caliber_Armor_Class_0",  fg.class)
        ent:SetNWInt("Caliber_Armor_Dur_0",    fg.dur_max)
        ent:SetNWInt("Caliber_Armor_MaxDur_0", fg.dur_max)
        ent:SetNWString("Caliber_Armor_Mat_0", fg.material or "aramid")
    end
    ent:SetNWBool("Caliber_Armor_Init", true)
    dprint(2, "[Caliber] ApplyArmorDirect", ent:GetClass())
end

-- ── Auto-test (uncomment in server console to verify math) ───────────────────
--[[
do
    RunConsoleCommand("caliber_armor_deterministic", "1")

    -- Case 1: weak pistol vs fresh class-4 titanium plate -> must BLOCK
    -- ratio = 20/40 = 0.5  =>  penChance = 0.20 + 0.5*(0.5-1) + 0 = -0.05 -> 0.00
    -- bluntFactor = max(0.05, 0.20*(1-0.3)) = 0.14  =>  fleshDmg = 30*0.14 = 4.20
    -- deltaD = 25*0.50*(1.2-1.0) = 2.50              =>  newDur = 80-2.50 = 77.50
    local z1 = { clase=4, durActual=80, durMax=80,  material="titanium" }
    local t1 = { damage=30, penPower=20, armorDamage=25, penChanceBase=0.20 }
    local r1 = CALIBER.ResolveArmor(z1, t1, HITGROUP_CHEST)
    Corpus.Log("caliber", string.format("[Caliber TEST] weak vs fresh   fleshDmg=%.2f newDur=%.2f penleft=%.2f  (expect 4.20 77.50 0.00)",
        r1.fleshDmg, r1.newDur, r1.factorPenleft))

    -- Case 2: AP sniper vs nearly-destroyed class-3 ceramic -> must PENETRATE
    -- ratio = 60/30 = 2.0  =>  penChance = 0.75 + 0.5*1 + 0.25*0.9 = 1.475 -> 1.00
    -- resistRatio = 0.5  =>  penDamageFactor = max(0.4, 0.75) = 0.75  =>  fleshDmg = 60*0.75 = 45.00
    -- deltaD = 70*0.85*(1.2-0.1)*0.5 = 32.73                          =>  newDur = max(0,10-32.73) = 0.00
    local z2 = { clase=3, durActual=10, durMax=100, material="ceramic" }
    local t2 = { damage=60, penPower=60, armorDamage=70, penChanceBase=0.75 }
    local r2 = CALIBER.ResolveArmor(z2, t2, HITGROUP_CHEST)
    Corpus.Log("caliber", string.format("[Caliber TEST] AP vs damaged   fleshDmg=%.2f newDur=%.2f penleft=%.2f  (expect 45.00 0.00 0.75)",
        r2.fleshDmg, r2.newDur, r2.factorPenleft))

    RunConsoleCommand("caliber_armor_deterministic", "0")
end
--]]
