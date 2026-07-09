-- corpus_caliber_shields.lua — subsistema de escudos de energía (server)
-- Migrado desde ADS 2.0 (ads_shields.lua). Cargado vía manifest tras core.
--
-- Capa 1 del diseño (docs/Caliber_EnergyShields_Arquitectura.md): motor mecánico.
-- Pool GLOBAL por NPC (no zonal) que se resuelve ANTES de la armadura:
--   Hit → ESCUDO → ARMADURA → LIMBS
-- No-overflow canon: el escudo absorbe el hit COMPLETO (el exceso no pasa).
-- La recarga la simula un único Think server-only (patrón caliber_scavenger);
-- el cliente solo ve transiciones de estado vía NWVar + one-shots net PVS
-- (esos los emite corpus_caliber_core.lua/este archivo; consumidos por
-- corpus_caliber_shields_cl.lua, migrado junto con el resto de este bloque).
--
-- Concepto y assets rescatados de "Halo Energy Shield" (Speedy Von Gofast) y
-- "Goofy Armor Effect" (sora1d) — créditos en README. El wiring de red
-- original era single-player y se reescribió multi-NPC.
if CLIENT then return end

local DBG = GetConVar("caliber_debug")  -- reuse core debug convar
-- level: minimum caliber_debug tier (1=compact+, 2=verbose/events only)
local function dprint(level, ...) if DBG and DBG:GetInt() >= level then Corpus.Log("caliber", "[Caliber Shields]", ...) end end

-- Convars (REPLICATED para que los sliders/checkboxes de corpus_caliber_client_options.lua funcionen)
local SH_EN       = CreateConVar("caliber_shield_enabled",        "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Master toggle del subsistema de escudos de energia")
local DMG_MULT    = CreateConVar("caliber_shield_damage_mult",    "1.0", FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Cuanto drena un hit generico al pool del escudo (knob global unico, sin penetracion)")
local PLASMA_MULT = CreateConVar("caliber_shield_plasma_mult",    "2.0", FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Factor global extra de drain para armas con flag plasma")
local EMP_LOCK    = CreateConVar("caliber_shield_emp_lockout",    "8.0", FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Segundos de lockout de recarga tras un hit de arma con flag emp")
local SND_SH      = CreateConVar("caliber_shield_sounds",         "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Sonidos del escudo (hits/colapso/restauracion)")
local THINK_INT   = CreateConVar("caliber_shield_think_interval", "0.1", FCVAR_REPLICATED + FCVAR_ARCHIVE,
    "Throttle per-NPC del Think de recarga (segundos)")

local CALIBER = Corpus.GetModule("caliber")

-- Estados del escudo (NWInt Caliber_Shield_State; 0 = sin escudo)
local STATE_UP       = 1
local STATE_DOWN     = 2
local STATE_CHARGING = 3

-- Bypass por damage type (§4 del diseño): melee/espada saltan el pool.
-- SOLO estos dos; blast/fuego/etc. drenan normal via shield_damage_mult.
local BYPASS_TYPES = bit.bor(DMG_SLASH, DMG_CLUB)

-- ── Capa 2: registry de tipos ────────────────────────────────────────────────
-- Agregar un escudo nuevo = una entrada acá + la entrada espejo (visuales) en
-- Caliber_ShieldFX.Types de corpus_caliber_shields_cl.lua. MISMAS KEYS en ambas tablas.
-- La mecánica NO cambia entre tipos: solo assets y defaults.

-- sound/ads/shield/<dir>/hit1-7.wav (rescatados del mod Halo, ver A6)
local function HaloHitSet(dir)
    local t = {}
    for i = 1, 7 do t[i] = "ads/shield/" .. dir .. "/hit" .. i .. ".wav" end
    return t
end
local HALO_BREAKS = { "ads/shield/break1.wav", "ads/shield/break2.wav", "ads/shield/break3.wav" }

CALIBER.ShieldTypes = {
    spartan = {
        label    = "Spartan",
        defaults = { max_hp = 70, recharge_delay = 4.0, recharge_rate = 15, can_regen = true },
        color    = { r = 218, g = 185, b = 40 },
        sounds   = {
            hit_light  = HaloHitSet("light"),
            hit_medium = HaloHitSet("medium"),
            hit_heavy  = HaloHitSet("heavy"),
            brk        = HALO_BREAKS,
            -- charge: sonido INCREMENTAL de carga (wav con loop embebido, cue de
            -- Source). Se emite al ENTRAR a CHARGING con pitch estirado al tiempo
            -- real de carga y se corta con StopSound al completar/interrumpirse —
            -- nunca como one-shot (quedaría loopeando para siempre).
            charge     = "ads/shield/recharge_spartan.wav",
        },
    },
    elite = {
        label    = "Elite Sangheili",
        defaults = { max_hp = 70, recharge_delay = 4.0, recharge_rate = 15, can_regen = true },
        color    = { r = 51, g = 105, b = 219 },
        sounds   = {
            hit_light  = HaloHitSet("light"),
            hit_medium = HaloHitSet("medium"),
            hit_heavy  = HaloHitSet("heavy"),
            brk        = HALO_BREAKS,
            charge     = "ads/shield/recharge_elite.wav",
        },
    },
    hev = {
        -- HEV Charge Shield: mismo motor, capa de efectos ligera (Goofy Armor).
        -- Todo built-in del engine: sin assets propios.
        label    = "HEV",
        defaults = { max_hp = 50, recharge_delay = 6.0, recharge_rate = 10, can_regen = true },
        color    = { r = 255, g = 160, b = 40 },
        sounds   = {
            hit_light  = { "physics/metal/metal_canister_impact_soft1.wav",
                           "physics/metal/metal_canister_impact_soft2.wav",
                           "physics/metal/metal_canister_impact_soft3.wav" },
            hit_medium = { "physics/concrete/concrete_block_impact_hard1.wav",
                           "physics/concrete/concrete_block_impact_hard2.wav",
                           "physics/concrete/concrete_block_impact_hard3.wav" },
            hit_heavy  = { "ambient/energy/spark1.wav", "ambient/energy/spark2.wav",
                           "ambient/energy/spark3.wav", "ambient/energy/spark4.wav",
                           "ambient/energy/spark5.wav", "ambient/energy/spark6.wav" },
            brk        = { "npc/vort/vort_attack_shoot3.wav" },
            -- 2ª capa del colapso (el Goofy tocaba ambos a la vez)
            brk_extra  = { "weapons/physcannon/energy_disintegrate4.wav",
                           "weapons/physcannon/energy_disintegrate5.wav" },
            charge     = "items/suitcharge1.wav",   -- hum de cargador HEV (loop stock)
            restore    = "items/suitchargeok1.wav", -- ding de carga completa
        },
    },
}

-- precache de los wav custom: evita que el primer hit suene mudo
for _, def in pairs(CALIBER.ShieldTypes) do
    for _, key in ipairs({ "hit_light", "hit_medium", "hit_heavy", "brk", "brk_extra" }) do
        local set = def.sounds[key]
        if set then for _, s in ipairs(set) do util.PrecacheSound(s) end end
    end
    if def.sounds.charge then util.PrecacheSound(def.sounds.charge) end
    if def.sounds.restore then util.PrecacheSound(def.sounds.restore) end
end

-- ── Estado server-only ───────────────────────────────────────────────────────
-- Registered shield NPCs: [entity] = true (patrón ScavengerNPCs — un solo Think
-- itera SOLO los registrados; la recarga completa produce cero paquetes).
local ShieldNPCs = {}

-- Sonido de carga: acompaña el estado CHARGING de inicio a fin. Los wav del mod
-- Halo traen loop embebido (cue de Source) → hay que cortarlos con StopSound;
-- el pitch se estira para que UN sweep dure lo que falta de carga (clamp de
-- Source: [30,255] — cargas muy largas loopean hasta el corte igual).
local function StartChargeSound(npc, sh)
    if not SND_SH:GetBool() then return end
    local def = CALIBER.ShieldTypes[sh.type]
    local snd = def and def.sounds.charge
    if not snd then return end
    local remaining = (sh.max - sh.hp) / math.max(sh.rechargeRate, 0.01)
    local natural = SoundDuration(snd)
    local pitch = 100
    if natural and natural > 0 and remaining > 0 then
        pitch = math.Clamp(math.Round(natural / remaining * 100), 30, 255)
    end
    npc:EmitSound(snd, 72, pitch, 1)
    sh.chargeSnd = snd
end

local function StopChargeSound(npc, sh)
    if sh and sh.chargeSnd then
        npc:StopSound(sh.chargeSnd)
        sh.chargeSnd = nil
    end
end

-- Escribe el estado en el espejo server Y en la NWVar, solo on-change
-- (la NWVar solo replica cambios; el guard evita spam de escrituras).
-- Centraliza el sonido de carga: TODA salida de CHARGING lo corta (completar,
-- hit que interrumpe, EMP, colapso) y toda entrada lo arranca.
local function SetState(npc, state)
    local sh = npc.Caliber_Shield
    if not sh or sh.state == state then return end
    if sh.state == STATE_CHARGING and state ~= STATE_CHARGING then
        StopChargeSound(npc, sh)
    end
    sh.state = state
    npc:SetNWInt("Caliber_Shield_State", state)
    if state == STATE_CHARGING then
        StartChargeSound(npc, sh)
    end
end

-- Sonidos del motor (server-side EmitSound: atenuación/PVS gratis, patrón
-- PlayArmorSounds de caliber_core). event: "hit"|"break"|"restore"; tier solo en hit.
local function PlayShieldSounds(npc, event, drain)
    if not SND_SH:GetBool() then return end
    local sh = npc.Caliber_Shield
    local def = sh and CALIBER.ShieldTypes[sh.type]
    if not def then return end
    local snd = def.sounds
    if event == "hit" then
        -- tiers canon del mod original (sv_shield.lua): <10 light, <25 medium, ≥25 heavy
        local set = (drain < 10 and snd.hit_light) or (drain < 25 and snd.hit_medium) or snd.hit_heavy
        if set and #set > 0 then npc:EmitSound(set[math.random(#set)], 72, math.random(96, 104), 1) end
    elseif event == "break" then
        if snd.brk and #snd.brk > 0 then npc:EmitSound(snd.brk[math.random(#snd.brk)], 100, 100, 1) end
        if snd.brk_extra and #snd.brk_extra > 0 then
            npc:EmitSound(snd.brk_extra[math.random(#snd.brk_extra)], 90, math.random(90, 110), 1)
        end
    elseif event == "restore" then
        if snd.restore then npc:EmitSound(snd.restore, 72, 100, 1) end
    end
end

-- One-shots visuales transitorios (§5): SOLO a jugadores que pueden ver al NPC
-- (CRecipientFilter:AddPVS). ev: 1=hit_flash, 2=collapse, 3=restore.
-- El consumidor es corpus_caliber_shields_cl.lua; emitir sin él (instalación parcial) es inocuo.
local FX_HIT, FX_COLLAPSE, FX_RESTORE = 1, 2, 3
local function EmitShieldFX(npc, ev, pos)
    -- throttle: máx 1 flash de hit por NPC por frame (ráfagas/perdigones);
    -- collapse y restore nunca se throttlean
    if ev == FX_HIT then
        if npc.Caliber_ShieldFXFrame == FrameNumber() then return end
        npc.Caliber_ShieldFXFrame = FrameNumber()
    end
    pos = (pos and not pos:IsZero()) and pos or npc:WorldSpaceCenter()
    local rf = RecipientFilter()
    rf:AddPVS(pos)
    net.Start("corpus_caliber_shield_fx")
    net.WriteUInt(ev, 2)
    net.WriteEntity(npc)
    if ev == FX_HIT then net.WriteVector(pos) end
    net.Send(rf)
end

-- Cualquier hit que afecte el escudo (incluidos bypass) frena la regen (§4).
-- Si estaba regenerando, vuelve al estado base según el pool.
local function ResetRegenTimer(npc, sh)
    sh.regenAt = CurTime() + sh.rechargeDelay
    if sh.state == STATE_CHARGING then
        SetState(npc, sh.hp > 0 and STATE_UP or STATE_DOWN)
    end
end

-- ── Init / remove per-NPC ────────────────────────────────────────────────────

-- Limpia escudo y NWVars. Seguro de llamar aunque el NPC nunca tuvo escudo.
function CALIBER.RemoveShield(npc)
    if not IsValid(npc) then return end
    ShieldNPCs[npc] = nil
    if not npc.Caliber_Shield then return end
    StopChargeSound(npc, npc.Caliber_Shield)
    npc.Caliber_Shield = nil
    npc:SetNWInt("Caliber_Shield_State", 0)
    npc:SetNWString("Caliber_Shield_Type", "")
    dprint(2, "shield removed", npc:GetClass())
end

-- Idempotente: re-init resetea el pool a full (mismo criterio que InitArmorNWvars).
-- La autoridad es el whitelist entry (§6): sin entry o sin shield_type válido → sin escudo.
function CALIBER.InitShield(npc)
    if not IsValid(npc) or not npc:IsNPC() then return end
    -- Key de spawnmenu (si tiene config) > classname (ver CALIBER.GetOverrideForEnt)
    local override = CALIBER.GetOverrideForEnt and CALIBER.GetOverrideForEnt(npc) or nil
    local stype = override and override.shield_type or nil
    local def = stype and CALIBER.ShieldTypes[stype] or nil
    if not def then
        if stype then
            dprint(1, string.format("shield_type '%s' desconocido en %s — sin escudo", tostring(stype), npc:GetClass()))
        end
        CALIBER.RemoveShield(npc)
        return
    end

    local d = def.defaults
    local maxHp = math.floor(math.Clamp(tonumber(override.shield_max_hp) or d.max_hp, 1, 5000))
    -- false es valor legítimo: resolver con ~= nil, nunca con `or`
    local canRegen = override.shield_can_regen
    if canRegen == nil then canRegen = d.can_regen end
    local col = type(override.shield_color) == "table" and override.shield_color or def.color

    npc.Caliber_Shield = {
        hp            = maxHp,
        max           = maxHp,
        type          = stype,
        canRegen      = canRegen == true,
        rechargeDelay = tonumber(override.shield_recharge_delay) or d.recharge_delay,
        rechargeRate  = tonumber(override.shield_recharge_rate) or d.recharge_rate,
        regenAt       = 0,
        lockoutUntil  = 0,
        state         = 0,   -- lo fija SetState (guard on-change necesita valor previo)
        nextThink     = 0,
    }
    SetState(npc, STATE_UP)
    npc:SetNWString("Caliber_Shield_Type", stype)
    npc:SetNWVector("Caliber_Shield_Color", Vector(
        math.Clamp(tonumber(col.r) or 255, 0, 255),
        math.Clamp(tonumber(col.g) or 255, 0, 255),
        math.Clamp(tonumber(col.b) or 255, 0, 255)))
    ShieldNPCs[npc] = true
    dprint(2, string.format("shield init %s: %s %d HP (regen=%s delay=%.1f rate=%.1f)",
        npc:GetClass(), stype, maxHp, tostring(canRegen), npc.Caliber_Shield.rechargeDelay, npc.Caliber_Shield.rechargeRate))
end

-- Re-sincroniza los escudos vivos de una clase con su whitelist entry vigente
-- (InitShield ya decide dar/quitar según el entry). Las llama caliber_core tras
-- los net.Receive que tocan el whitelist.
function CALIBER.RefreshShieldsForClass(classname)
    if not classname or classname == "" then return end
    for _, e in ipairs(ents.GetAll()) do
        -- Matchea classname o key de spawnmenu: editar el entry de una key
        -- refresca en vivo los NPCs spawneados con ella
        if IsValid(e) and e:IsNPC()
           and (e:GetClass() == classname or e.NPCName == classname) then
            CALIBER.InitShield(e)
        end
    end
end

function CALIBER.RefreshAllShields()
    for _, e in ipairs(ents.GetAll()) do
        if IsValid(e) and e:IsNPC() then CALIBER.InitShield(e) end
    end
end

-- ── Motor de daño ────────────────────────────────────────────────────────────

-- Consulta PURA (sin side effects) para el detour ARC9: ¿este hit sería
-- absorbido? true ⟺ sistema on, escudo con pool, daño > 0 y tipo no-bypass.
-- EMP cuenta como absorción (colapsa, pero el hit no pasa).
function CALIBER.ShieldWillAbsorb(npc, di)
    if not SH_EN:GetBool() then return false end
    local sh = npc.Caliber_Shield
    if not sh or sh.hp <= 0 then return false end
    if di:GetDamage() <= 0 then return false end
    if bit.band(di:GetDamageType(), BYPASS_TYPES) ~= 0 then return false end
    return true
end

-- Pre-filtro de escudo. Lo llama ScaleNPCDamage ANTES de la armadura.
-- Devuelve: absorbed (bool), trace (tabla|nil).
--   absorbed=true  → hit consumido ÍNTEGRO (no-overflow §4). Ya se hizo
--                    di:SetDamage(0); el caller DEBE early-return del hook.
--   absorbed=false → el hit pasa entero (bypass / escudo caído / sin escudo /
--                    dmg<=0 / off). trace.reason distingue el porqué.
-- trace = { reason="absorbed"|"break"|"emp"|"bypass"|"down",
--           hpBefore, hpAfter, drain, plasma } | nil
function CALIBER.ProcessShield(npc, hg, di)
    if not SH_EN:GetBool() then return false, nil end
    local sh = npc.Caliber_Shield
    if not sh then return false, nil end
    local dmg = di:GetDamage()
    -- dmg<=0 no resetea timer ni genera trace: el call site no debe descartar
    -- stash ARC9 legítimo por un hit vacío
    if dmg <= 0 then return false, nil end

    -- Bypass melee (§4): salta el pool pero SÍ frena la regen (canon)
    if bit.band(di:GetDamageType(), BYPASS_TYPES) ~= 0 then
        ResetRegenTimer(npc, sh)
        return false, { reason = "bypass", hpBefore = sh.hp, hpAfter = sh.hp, drain = 0 }
    end

    -- Flags de arma: lookup independiente del extractor — el arma EFT conserva
    -- su tuple balístico Branch-1 intacto; los flags viven solo en curated
    local atk = di:GetAttacker()
    local wep = (IsValid(atk) and atk.GetActiveWeapon) and atk:GetActiveWeapon() or nil
    local cw = IsValid(wep) and CALIBER.CuratedWeapons and CALIBER.CuratedWeapons[wep:GetClass()] or nil
    local plasma = cw ~= nil and cw.plasma == true
    local emp = cw ~= nil and cw.emp == true

    -- Escudo caído: el hit pasa entero; EMP extiende el lockout igual
    if sh.hp <= 0 then
        ResetRegenTimer(npc, sh)
        if emp then sh.lockoutUntil = CurTime() + EMP_LOCK:GetFloat() end
        return false, { reason = "down", hpBefore = 0, hpAfter = 0, drain = 0 }
    end

    -- EMP con escudo arriba: colapso total instantáneo + lockout (§4)
    if emp then
        local before = sh.hp
        sh.hp = 0
        sh.lockoutUntil = CurTime() + EMP_LOCK:GetFloat()
        ResetRegenTimer(npc, sh)
        SetState(npc, STATE_DOWN)
        PlayShieldSounds(npc, "break")
        EmitShieldFX(npc, FX_COLLAPSE)
        di:SetDamage(0)
        return true, { reason = "emp", hpBefore = before, hpAfter = 0, drain = before }
    end

    -- Drain normal: un solo knob global (+plasma). La penetración NO participa (§4).
    local drain = dmg * DMG_MULT:GetFloat() * (plasma and PLASMA_MULT:GetFloat() or 1)
    local before = sh.hp
    sh.hp = math.max(0, sh.hp - drain)
    ResetRegenTimer(npc, sh)

    if sh.hp <= 0 then
        SetState(npc, STATE_DOWN)
        PlayShieldSounds(npc, "break")
        EmitShieldFX(npc, FX_COLLAPSE)
        di:SetDamage(0)
        return true, { reason = "break", hpBefore = before, hpAfter = 0, drain = drain, plasma = plasma }
    end

    PlayShieldSounds(npc, "hit", drain)
    EmitShieldFX(npc, FX_HIT, di:GetDamagePosition())
    di:SetDamage(0)
    return true, { reason = "absorbed", hpBefore = before, hpAfter = sh.hp, drain = drain, plasma = plasma }
end

-- ── Recarga: un solo Think sobre los NPCs registrados ────────────────────────
-- Cero tráfico de red durante la recarga; lo único que cruza al completar es el
-- flip de NWVar CHARGING→UP + un one-shot de restauración (§5).

hook.Add("Think", "Caliber_Shields_Think", function()
    if not SH_EN:GetBool() then return end
    if not next(ShieldNPCs) then return end  -- early exit when world is empty

    local now = CurTime()
    for npc, _ in pairs(ShieldNPCs) do
        if not IsValid(npc) then
            ShieldNPCs[npc] = nil
            continue
        end
        local sh = npc.Caliber_Shield
        if not sh then
            ShieldNPCs[npc] = nil
            continue
        end
        if npc:Health() <= 0 then
            StopChargeSound(npc, sh)  -- que la carga no siga sonando sobre el cadáver
            ShieldNPCs[npc] = nil
            continue
        end
        if now < sh.nextThink then continue end
        sh.nextThink = now + THINK_INT:GetFloat()

        if sh.state == STATE_CHARGING then
            -- elapsed real acumulado (no el intervalo nominal del throttle)
            local elapsed = now - (sh.lastRegenTick or now)
            sh.lastRegenTick = now
            sh.hp = math.min(sh.max, sh.hp + sh.rechargeRate * elapsed)
            if sh.hp >= sh.max then
                SetState(npc, STATE_UP)
                PlayShieldSounds(npc, "restore")
                EmitShieldFX(npc, FX_RESTORE)
                dprint(2, string.format("shield full %s (%d/%d)", npc:GetClass(), sh.hp, sh.max))
            end
        elseif sh.canRegen and sh.hp < sh.max and now >= sh.regenAt and now >= sh.lockoutUntil then
            -- DOWN o UP-parcial con delay (y lockout EMP) vencidos → empezar a cargar
            sh.lastRegenTick = now
            SetState(npc, STATE_CHARGING)
            dprint(2, string.format("shield charging %s (%.1f/%d)", npc:GetClass(), sh.hp, sh.max))
        end
    end
end)

-- ── Registro / cleanup ───────────────────────────────────────────────────────

hook.Add("OnEntityCreated", "Caliber_Shields_Init", function(e)
    -- Delay 0.4s: después de core (0.2) y limbs (0.3) — el whitelist entry ya
    -- está resuelto — y antes del scavenger (0.5)
    timer.Simple(0.4, function()
        if not IsValid(e) or e:IsPlayer() or not e:IsNPC() then return end
        CALIBER.InitShield(e)
    end)
end)

-- Cortar el sonido de carga CON LA ENTIDAD AÚN VÁLIDA: si el NPC muere y se
-- remueve en el mismo tick, la purga del Think no llega a cortarlo, y Source
-- REUTILIZA el índice de entidad → el loop quedaba pegado al índice y lo
-- heredaba el próximo NPC spawneado (bug de verificación del Bloque B).
hook.Add("OnNPCKilled", "Caliber_Shields_NPCKilled", function(npc)
    local sh = npc.Caliber_Shield
    if sh then StopChargeSound(npc, sh) end
    ShieldNPCs[npc] = nil
end)

hook.Add("EntityRemoved", "Caliber_Shields_Cleanup", function(ent)
    local sh = ent.Caliber_Shield
    if sh and sh.chargeSnd and IsValid(ent) then
        ent:StopSound(sh.chargeSnd)
        sh.chargeSnd = nil
    end
    ShieldNPCs[ent] = nil
end)

-- Hot-reload lua: el registry file-local se vació — re-registrar NPCs vivos.
-- En carga de mapa normal ents.GetAll() está vacío: no-op.
CALIBER.RefreshAllShields()

-- ── Concommands de debug (verificación del Bloque A sin UI) ──────────────────

-- Escudo efímero al NPC apuntado, SIN tocar el whitelist/JSON (paralelo al
-- stool de debug). caliber_shield_give [tipo] [max_hp]
concommand.Add("caliber_shield_give", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local e = IsValid(ply) and ply:GetEyeTrace().Entity or nil
    if not IsValid(e) or not e:IsNPC() then
        Corpus.Log("caliber", "[Caliber Shields] apunta a un NPC")
        return
    end
    local stype = args[1] or "spartan"
    local def = CALIBER.ShieldTypes[stype]
    if not def then
        Corpus.Log("caliber", "[Caliber Shields] tipo desconocido '" .. tostring(stype) .. "' (spartan/elite/hev)")
        return
    end
    local d = def.defaults
    local maxHp = math.floor(math.Clamp(tonumber(args[2]) or d.max_hp, 1, 5000))
    e.Caliber_Shield = {
        hp = maxHp, max = maxHp, type = stype, canRegen = d.can_regen,
        rechargeDelay = d.recharge_delay, rechargeRate = d.recharge_rate,
        regenAt = 0, lockoutUntil = 0, state = 0, nextThink = 0,
    }
    SetState(e, STATE_UP)
    e:SetNWString("Caliber_Shield_Type", stype)
    e:SetNWVector("Caliber_Shield_Color", Vector(def.color.r, def.color.g, def.color.b))
    ShieldNPCs[e] = true
    Corpus.Log("caliber", string.format("[Caliber Shields] %s ← %s %d HP (efimero, no persiste)", e:GetClass(), stype, maxHp))
end)

concommand.Add("caliber_shield_clear", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local e = IsValid(ply) and ply:GetEyeTrace().Entity or nil
    if not IsValid(e) or not e:IsNPC() then
        Corpus.Log("caliber", "[Caliber Shields] apunta a un NPC")
        return
    end
    CALIBER.RemoveShield(e)
    Corpus.Log("caliber", "[Caliber Shields] escudo removido de " .. e:GetClass())
end)

concommand.Add("caliber_shield_status", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local e = IsValid(ply) and ply:GetEyeTrace().Entity or nil
    if not IsValid(e) or not e:IsNPC() then
        Corpus.Log("caliber", "[Caliber Shields] apunta a un NPC")
        return
    end
    local sh = e.Caliber_Shield
    if not sh then
        Corpus.Log("caliber", "[Caliber Shields] " .. e:GetClass() .. ": sin escudo")
        return
    end
    local stateName = ({ [STATE_UP] = "UP", [STATE_DOWN] = "DOWN", [STATE_CHARGING] = "CHARGING" })[sh.state] or "?"
    Corpus.Log("caliber", string.format(
        "[Caliber Shields] %s: %s  %.1f/%d  state=%s  regen=%s(rate=%.1f/s)  regen_in=%.1fs  lockout_in=%.1fs",
        e:GetClass(), sh.type, sh.hp, sh.max, stateName, tostring(sh.canRegen), sh.rechargeRate,
        math.max(0, sh.regenAt - CurTime()), math.max(0, sh.lockoutUntil - CurTime())))
end)
