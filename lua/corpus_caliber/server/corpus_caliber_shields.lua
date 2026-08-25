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

-- ⚠ EL JUGADOR SALTA ADEMAS DMG_FALL, y no es una excepcion "para jugadores".
-- Con el mapeo de CAL-27 el pool del jugador ES ply:Armor(), y el reparto del
-- engine sobre ese pool YA EXCLUYE la caida — medido en juego el 2026-08-22
-- (Caliber_Architecture.md §13.0, fila J8): la caida se lleva la vida entera con
-- la armadura INTACTA. Si el escudo la drenara, la caida pasaria a pegar distinto
-- segun cuanto escudo tengas, que es el agujero exacto que BYPASS_TYPES existe
-- para tapar (CAL-16). O sea: la lista de exclusion del engine es parte del
-- contrato del pool del jugador, y por eso viaja en el escudo y no en un if.
--
-- ⚠⚠ LOS OTROS TRES QUE EL CODIGO DE HL2 EXCLUYE —DMG_DROWN, DMG_POISON,
-- DMG_RADIATION— NO ESTAN ACA A PROPOSITO: en este build NO SE MIDIERON. El tramo
-- 0 midio bala, melee, explosion y caida, y nada mas. Ponerlos seria escribir una
-- cita del motor como si fuera una medicion. Hoy esos tres DRENAN el escudo del
-- jugador; si alguna vez se miden y resulta que el engine tampoco los reparte,
-- entran aca y la fila que lo mida va en la planilla de ese dia.
local BYPASS_TYPES_PLY = bit.bor(BYPASS_TYPES, DMG_FALL)

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
-- Entidades con escudo registradas: [entity] = true (patrón ScavengerNPCs — un
-- solo Think itera SOLO las registradas; la recarga completa produce cero
-- paquetes). Desde el paso 2 del Block 3 el registro NO es NPC-only: la mecanica
-- del escudo nunca lo fue (ProcessShield no chequea IsNPC() y ni siquiera lee el
-- hitgroup que recibe) — lo NPC-only era el CICLO DE VIDA, que es esto.
local ShieldEnts = {}

-- ── El pool, y donde vive — CAL-27 ──────────────────────────────────────────
-- En un NPC el almacen del pool es `sh.hp`. En el JUGADOR el almacen es
-- ply:Armor() y `sh.hp` NO EXISTE: un solo estado por entidad. Tener dos y que se
-- desincronicen es el modo de falla que CRG-78 nombra, y aca se paga peor que
-- alla — cualquier tercero que escriba ply:Armor() (la bateria de Cargo, un
-- charger del mapa, un addon suelto) se convierte en un escritor del pool sin
-- saberlo, y un espejo tendria que interceptarlos a todos o perder la escritura
-- en silencio.
--
-- El discriminante es `sh.onArmor` y NO `ent:IsPlayer()`: quien pregunta quiere
-- saber DONDE ESTA EL POOL, no de que especie es la victima. Asi ProcessShield y
-- el Think siguen sin mirar el tipo de entidad ni una sola vez.
--
-- ⚠ SetArmor guarda un ENTERO y el pool es float (la regen acumula rate*elapsed).
-- `sh.frac` lleva SOLO el resto sub-unitario — lo unico que un int no puede
-- guardar — y vale siempre < 1: el pool sigue siendo Armor(), frac no es una
-- segunda copia, y si un tercero escribe Armor() la lectura de aca lo toma en el
-- acto con un error residual de menos de un punto. SIN ESTO LA REGEN SE ROMPE EN
-- SILENCIO: rate 15 con think 0,1 deposita 1,5 por tick, el int trunca a 1, y el
-- escudo carga a 10/s en vez de 15/s sin un solo error.
local function PoolGet(ent, sh)
    if sh.onArmor then return ent:Armor() + (sh.frac or 0) end
    return sh.hp
end

local function PoolSet(ent, sh, v)
    v = math.Clamp(v, 0, sh.max)
    if sh.onArmor then
        local w = math.floor(v)
        sh.frac = v - w
        ent:SetArmor(w)
        return
    end
    sh.hp = v
end

-- Deja el pool LLENO, y si el almacen es ply:Armor() le corre el techo para que
-- quepa. ⚠ Ese techo de 100 NO ES DEL ENGINE: es PLAYER.MaxArmor del gamemode
-- base (gamemodes/base/gamemode/player_class/player_default.lua:19), que
-- player_manager.SetPlayerClass aplica con ply:SetMaxArmor() en CADA spawn. Es
-- Lua, igual que el escalado de hitgroup de §13.0, y por eso se puede mover: sin
-- esto un escudo de max_hp 150 entraria topado en 100 sin avisar. Se guarda el
-- techo anterior para devolverlo al sacar el escudo.
local function SeedPool(ent, sh, maxHp)
    if not sh.onArmor then sh.hp = maxHp return end
    -- ⚠ EL TECHO ORIGINAL SE GUARDA EN LA ENTIDAD Y NO EN LA TABLA DEL ESCUDO, y
    -- solo la PRIMERA vez. InitShield es idempotente y se vuelve a llamar sin que
    -- medie un respawn —RefreshAllShields al editar el whitelist, y el re-registro
    -- de un hot-reload de lua—; con el guardado en `sh`, la tabla nueva capturaria
    -- como "anterior" el techo QUE LE PUSO EL ESCUDO ANTERIOR, y RemoveShield
    -- devolveria 70 donde iban 100. Sin error, y visible recien el dia que alguien
    -- se saca el escudo. En el respawn no se nota porque player_manager repone el
    -- 100 antes de que corra el timer — o sea que el defecto se esconde justo en el
    -- camino que se prueba primero.
    if ent.Caliber_MaxArmorPrev == nil then
        ent.Caliber_MaxArmorPrev = (ent.GetMaxArmor and ent:GetMaxArmor()) or 100
    end
    if ent.SetMaxArmor then ent:SetMaxArmor(maxHp) end
    ent:SetArmor(maxHp)
    sh.frac = 0
end

-- caliber_enabled_ply es la perilla REAL del lado jugador (el checkbox muerto
-- salio de la UI el 2026-08-22 y el slider se retiro entero). La convar la crea
-- core, que carga antes por el manifest; si faltara, el default honesto es
-- ENCENDIDO — un modulo que se apaga solo porque no encuentra su perilla se lee
-- como que el mecanismo no existe.
local function PlayerSideEnabled()
    local c = GetConVar("caliber_enabled_ply")
    return (c == nil) or c:GetBool()
end

-- Sonido de carga: acompaña el estado CHARGING de inicio a fin. Los wav del mod
-- Halo traen loop embebido (cue de Source) → hay que cortarlos con StopSound;
-- el pitch se estira para que UN sweep dure lo que falta de carga (clamp de
-- Source: [30,255] — cargas muy largas loopean hasta el corte igual).
local function StartChargeSound(ent, sh)
    if not SND_SH:GetBool() then return end
    local def = CALIBER.ShieldTypes[sh.type]
    local snd = def and def.sounds.charge
    if not snd then return end
    local remaining = (sh.max - PoolGet(ent, sh)) / math.max(sh.rechargeRate, 0.01)
    local natural = SoundDuration(snd)
    local pitch = 100
    if natural and natural > 0 and remaining > 0 then
        pitch = math.Clamp(math.Round(natural / remaining * 100), 30, 255)
    end
    ent:EmitSound(snd, 72, pitch, 1)
    sh.chargeSnd = snd
end

local function StopChargeSound(ent, sh)
    if sh and sh.chargeSnd then
        ent:StopSound(sh.chargeSnd)
        sh.chargeSnd = nil
    end
end

-- Escribe el estado en el espejo server Y en la NWVar, solo on-change
-- (la NWVar solo replica cambios; el guard evita spam de escrituras).
-- Centraliza el sonido de carga: TODA salida de CHARGING lo corta (completar,
-- hit que interrumpe, EMP, colapso) y toda entrada lo arranca.
local function SetState(ent, state)
    local sh = ent.Caliber_Shield
    if not sh or sh.state == state then return end
    if sh.state == STATE_CHARGING and state ~= STATE_CHARGING then
        StopChargeSound(ent, sh)
    end
    sh.state = state
    ent:SetNWInt("Caliber_Shield_State", state)
    if state == STATE_CHARGING then
        StartChargeSound(ent, sh)
    end
end

-- Sonidos del motor (server-side EmitSound: atenuación/PVS gratis, patrón
-- PlayArmorSounds de caliber_core). event: "hit"|"break"|"restore"; tier solo en hit.
local function PlayShieldSounds(ent, event, drain)
    if not SND_SH:GetBool() then return end
    local sh = ent.Caliber_Shield
    local def = sh and CALIBER.ShieldTypes[sh.type]
    if not def then return end
    local snd = def.sounds
    if event == "hit" then
        -- tiers canon del mod original (sv_shield.lua): <10 light, <25 medium, ≥25 heavy
        local set = (drain < 10 and snd.hit_light) or (drain < 25 and snd.hit_medium) or snd.hit_heavy
        if set and #set > 0 then ent:EmitSound(set[math.random(#set)], 72, math.random(96, 104), 1) end
    elseif event == "break" then
        if snd.brk and #snd.brk > 0 then ent:EmitSound(snd.brk[math.random(#snd.brk)], 100, 100, 1) end
        if snd.brk_extra and #snd.brk_extra > 0 then
            ent:EmitSound(snd.brk_extra[math.random(#snd.brk_extra)], 90, math.random(90, 110), 1)
        end
    elseif event == "restore" then
        if snd.restore then ent:EmitSound(snd.restore, 72, 100, 1) end
    end
end

-- One-shots visuales transitorios (§5): SOLO a jugadores que pueden ver al NPC
-- (CRecipientFilter:AddPVS). ev: 1=hit_flash, 2=collapse, 3=restore.
-- El consumidor es corpus_caliber_shields_cl.lua; emitir sin él (instalación parcial) es inocuo.
local FX_HIT, FX_COLLAPSE, FX_RESTORE = 1, 2, 3
local function EmitShieldFX(ent, ev, pos)
    -- throttle: máx 1 flash de hit por NPC por frame (ráfagas/perdigones);
    -- collapse y restore nunca se throttlean
    if ev == FX_HIT then
        if ent.Caliber_ShieldFXFrame == FrameNumber() then return end
        ent.Caliber_ShieldFXFrame = FrameNumber()
    end
    pos = (pos and not pos:IsZero()) and pos or ent:WorldSpaceCenter()
    local rf = RecipientFilter()
    rf:AddPVS(pos)
    net.Start("corpus_caliber_shield_fx")
    net.WriteUInt(ev, 2)
    net.WriteEntity(ent)
    if ev == FX_HIT then net.WriteVector(pos) end
    net.Send(rf)
end

-- Cualquier hit que afecte el escudo (incluidos bypass) frena la regen (§4).
-- Si estaba regenerando, vuelve al estado base según el pool.
local function ResetRegenTimer(ent, sh)
    sh.regenAt = CurTime() + sh.rechargeDelay
    if sh.state == STATE_CHARGING then
        SetState(ent, PoolGet(ent, sh) > 0 and STATE_UP or STATE_DOWN)
    end
end

-- ── Init / remove per-NPC ────────────────────────────────────────────────────

-- Limpia escudo y NWVars. Seguro de llamar aunque la entidad nunca tuvo escudo.
function CALIBER.RemoveShield(ent)
    if not IsValid(ent) then return end
    ShieldEnts[ent] = nil
    local sh = ent.Caliber_Shield
    -- ⚠ ESTE EARLY RETURN ES LO QUE PROTEGE LA ARMADURA DE HL2 DE UN JUGADOR SIN
    -- ESCUDO. InitShield llama aca cada vez que no encuentra entry valido, o sea en
    -- CADA spawn de CADA jugador que no tiene escudo configurado: si la devolucion
    -- del techo y el SetArmor(0) de abajo corrieran igual, Caliber le estaria
    -- vaciando la armadura vanilla a todo el mundo, en silencio y sin tener un solo
    -- escudo puesto en el juego.
    if not sh then return end
    StopChargeSound(ent, sh)
    if sh.onArmor then
        -- el pool se va con el escudo: ply:Armor() deja de significarlo, y el techo
        -- que se le movio al ponerselo vuelve a donde estaba (ver SeedPool)
        if ent.SetMaxArmor then ent:SetMaxArmor(ent.Caliber_MaxArmorPrev or 100) end
        ent.Caliber_MaxArmorPrev = nil   -- el proximo escudo vuelve a capturar de cero
        ent:SetArmor(0)
    end
    ent.Caliber_Shield = nil
    ent:SetNWInt("Caliber_Shield_State", 0)
    ent:SetNWString("Caliber_Shield_Type", "")
    dprint(2, "shield removed", ent:GetClass())
end

-- Idempotente: re-init resetea el pool a full (mismo criterio que InitArmorNWvars).
-- La autoridad es el whitelist entry (§6): sin entry o sin shield_type válido → sin escudo.
function CALIBER.InitShield(ent)
    if not IsValid(ent) then return end
    -- El ciclo de vida deja de ser NPC-only (Block 3, paso 2). La mecanica nunca lo
    -- fue: ProcessShield toma (ent, hg, di), no chequea IsNPC(), y ni siquiera lee
    -- el hitgroup que recibe — el escudo es un POOL GLOBAL (CAL-14).
    local isPly = ent:IsPlayer()
    if not isPly and not ent:IsNPC() then return end
    -- Con el lado jugador apagado, Caliber NO le toca ply:Armor() a nadie: la
    -- armadura vuelve a ser la de HL2 y el modulo se retira entero.
    if isPly and not PlayerSideEnabled() then CALIBER.RemoveShield(ent) return end
    -- Key de spawnmenu (si tiene config) > classname (ver CALIBER.GetOverrideForEnt).
    -- Para un jugador la key SIEMPRE cae en el classname "player" —GetConfigKey
    -- resuelve NPCName > GetClass() y ningun jugador tiene NPCName—, asi que hoy la
    -- unica via de configuracion del lado jugador es un entry de whitelist llamado
    -- "player". El perfil por PLAYERMODEL es el paso 4 del tramo y todavia no
    -- existe; el empuje de Cargo (CAL-24) es el paso 3. Ninguno se implementa aca.
    local override = CALIBER.GetOverrideForEnt and CALIBER.GetOverrideForEnt(ent) or nil
    local stype = override and override.shield_type or nil
    local def = stype and CALIBER.ShieldTypes[stype] or nil
    if not def then
        if stype then
            dprint(1, string.format("shield_type '%s' desconocido en %s — sin escudo", tostring(stype), ent:GetClass()))
        end
        CALIBER.RemoveShield(ent)
        return
    end

    local d = def.defaults
    local maxHp = math.floor(math.Clamp(tonumber(override.shield_max_hp) or d.max_hp, 1, 5000))
    -- false es valor legítimo: resolver con ~= nil, nunca con `or`
    local canRegen = override.shield_can_regen
    if canRegen == nil then canRegen = d.can_regen end
    local col = type(override.shield_color) == "table" and override.shield_color or def.color

    local sh = {
        -- `hp` NO se declara aca: lo pone SeedPool, y SOLO del lado NPC. Para el
        -- jugador el almacen es ply:Armor() y este campo no debe existir (CAL-27) —
        -- si existiera seria la segunda copia que toda esta seccion evita.
        onArmor       = isPly,
        frac          = 0,
        max           = maxHp,
        type          = stype,
        canRegen      = canRegen == true,
        rechargeDelay = tonumber(override.shield_recharge_delay) or d.recharge_delay,
        rechargeRate  = tonumber(override.shield_recharge_rate) or d.recharge_rate,
        regenAt       = 0,
        lockoutUntil  = 0,
        state         = 0,   -- lo fija SetState (guard on-change necesita valor previo)
        nextThink     = 0,
        -- la lista de bypass viaja EN EL ESCUDO, no en un if sobre el tipo de
        -- entidad: ver el comentario de BYPASS_TYPES_PLY
        bypass        = isPly and BYPASS_TYPES_PLY or BYPASS_TYPES,
    }
    ent.Caliber_Shield = sh
    SeedPool(ent, sh, maxHp)
    SetState(ent, STATE_UP)
    ent:SetNWString("Caliber_Shield_Type", stype)
    ent:SetNWVector("Caliber_Shield_Color", Vector(
        math.Clamp(tonumber(col.r) or 255, 0, 255),
        math.Clamp(tonumber(col.g) or 255, 0, 255),
        math.Clamp(tonumber(col.b) or 255, 0, 255)))
    ShieldEnts[ent] = true
    dprint(2, string.format("shield init %s: %s %d HP (pool=%s regen=%s delay=%.1f rate=%.1f)",
        ent:GetClass(), stype, maxHp, isPly and "ply:Armor()" or "sh.hp",
        tostring(canRegen), sh.rechargeDelay, sh.rechargeRate))
end

-- Re-sincroniza los escudos vivos de una clase con su whitelist entry vigente
-- (InitShield ya decide dar/quitar según el entry). Las llama caliber_core tras
-- los net.Receive que tocan el whitelist.
function CALIBER.RefreshShieldsForClass(classname)
    if not classname or classname == "" then return end
    for _, e in ipairs(ents.GetAll()) do
        -- Matchea classname o key de spawnmenu: editar el entry de una key
        -- refresca en vivo los NPCs spawneados con ella
        -- "player" es un classname como cualquier otro (GetConfigKey lo resuelve
        -- asi), de modo que editar ese entry refresca en vivo a los jugadores
        if IsValid(e) and (e:IsNPC() or e:IsPlayer())
           and (e:GetClass() == classname or e.NPCName == classname) then
            CALIBER.InitShield(e)
        end
    end
end

function CALIBER.RefreshAllShields()
    for _, e in ipairs(ents.GetAll()) do
        if IsValid(e) and (e:IsNPC() or e:IsPlayer()) then CALIBER.InitShield(e) end
    end
end

-- ── Motor de daño ────────────────────────────────────────────────────────────

-- Consulta PURA (sin side effects) para el detour ARC9: ¿este hit sería
-- absorbido? true ⟺ sistema on, escudo con pool, daño > 0 y tipo no-bypass.
-- EMP cuenta como absorción (colapsa, pero el hit no pasa).
function CALIBER.ShieldWillAbsorb(ent, di)
    if not SH_EN:GetBool() then return false end
    local sh = ent.Caliber_Shield
    if not sh or PoolGet(ent, sh) <= 0 then return false end
    if di:GetDamage() <= 0 then return false end
    if bit.band(di:GetDamageType(), sh.bypass or BYPASS_TYPES) ~= 0 then return false end
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
function CALIBER.ProcessShield(ent, hg, di)
    -- ⚠ `hg` NO SE LEE EN NINGUNA LINEA DE ESTE CUERPO, y no es un descuido: el
    -- escudo es un POOL GLOBAL y no zonal (CAL-14). El parametro se conserva porque
    -- es la firma que el call site NPC ya usa, y porque el paso 3 del tramo mete la
    -- zona en el pipeline — pero HOY es lo que permite que el punto de entrada del
    -- jugador viva en EntityTakeDamage, que no trae hitgroup y cubre TODO el daño.
    if not SH_EN:GetBool() then return false, nil end
    local sh = ent.Caliber_Shield
    if not sh then return false, nil end
    local dmg = di:GetDamage()
    -- dmg<=0 no resetea timer ni genera trace: el call site no debe descartar
    -- stash ARC9 legítimo por un hit vacío
    if dmg <= 0 then return false, nil end
    -- ⚠ Los tres returns de arriba devuelven trace NIL, y los de abajo devuelven
    -- trace CON reason. Esa diferencia es la que el call site del jugador usa para
    -- saber si Caliber esta gobernando este hit o si se retiro: nil = no toques
    -- nada, que HL2 haga lo suyo. No es cosmetica.
    local pool = PoolGet(ent, sh)

    -- Bypass melee (§4): salta el pool pero SÍ frena la regen (canon). La lista la
    -- trae el escudo (sh.bypass) porque el jugador salta ademas DMG_FALL — ver
    -- BYPASS_TYPES_PLY.
    if bit.band(di:GetDamageType(), sh.bypass or BYPASS_TYPES) ~= 0 then
        ResetRegenTimer(ent, sh)
        return false, { reason = "bypass", hpBefore = pool, hpAfter = pool, drain = 0 }
    end

    -- Flags de arma: lookup independiente del extractor — el arma EFT conserva
    -- su tuple balístico Branch-1 intacto; los flags viven solo en curated
    local atk = di:GetAttacker()
    local wep = (IsValid(atk) and atk.GetActiveWeapon) and atk:GetActiveWeapon() or nil
    local cw = IsValid(wep) and CALIBER.CuratedWeapons and CALIBER.CuratedWeapons[wep:GetClass()] or nil
    local plasma = cw ~= nil and cw.plasma == true
    local emp = cw ~= nil and cw.emp == true

    -- Escudo caído: el hit pasa entero; EMP extiende el lockout igual
    if pool <= 0 then
        ResetRegenTimer(ent, sh)
        if emp then sh.lockoutUntil = CurTime() + EMP_LOCK:GetFloat() end
        return false, { reason = "down", hpBefore = 0, hpAfter = 0, drain = 0 }
    end

    -- EMP con escudo arriba: colapso total instantáneo + lockout (§4)
    if emp then
        PoolSet(ent, sh, 0)
        sh.lockoutUntil = CurTime() + EMP_LOCK:GetFloat()
        ResetRegenTimer(ent, sh)
        SetState(ent, STATE_DOWN)
        PlayShieldSounds(ent, "break")
        EmitShieldFX(ent, FX_COLLAPSE)
        di:SetDamage(0)
        return true, { reason = "emp", hpBefore = pool, hpAfter = 0, drain = pool }
    end

    -- Drain normal: un solo knob global (+plasma). La penetración NO participa (§4).
    local drain = dmg * DMG_MULT:GetFloat() * (plasma and PLASMA_MULT:GetFloat() or 1)
    local after = math.max(0, pool - drain)
    PoolSet(ent, sh, after)
    ResetRegenTimer(ent, sh)

    if after <= 0 then
        SetState(ent, STATE_DOWN)
        PlayShieldSounds(ent, "break")
        EmitShieldFX(ent, FX_COLLAPSE)
        di:SetDamage(0)
        return true, { reason = "break", hpBefore = pool, hpAfter = 0, drain = drain, plasma = plasma }
    end

    PlayShieldSounds(ent, "hit", drain)
    EmitShieldFX(ent, FX_HIT, di:GetDamagePosition())
    di:SetDamage(0)
    return true, { reason = "absorbed", hpBefore = pool, hpAfter = after, drain = drain, plasma = plasma }
end

-- ── Recarga: un solo Think sobre los NPCs registrados ────────────────────────
-- Cero tráfico de red durante la recarga; lo único que cruza al completar es el
-- flip de NWVar CHARGING→UP + un one-shot de restauración (§5).

hook.Add("Think", "Caliber_Shields_Think", function()
    if not SH_EN:GetBool() then return end
    if not next(ShieldEnts) then return end  -- early exit when world is empty

    local now = CurTime()
    for ent, _ in pairs(ShieldEnts) do
        if not IsValid(ent) then
            ShieldEnts[ent] = nil
            continue
        end
        local sh = ent.Caliber_Shield
        if not sh then
            ShieldEnts[ent] = nil
            continue
        end
        -- Vale para las dos especies: un NPC muerto y un jugador muerto dan los dos
        -- Health() <= 0, y al jugador lo vuelve a registrar InitShield en su spawn.
        if ent:Health() <= 0 then
            StopChargeSound(ent, sh)  -- que la carga no siga sonando sobre el cadáver
            ShieldEnts[ent] = nil
            continue
        end
        if now < sh.nextThink then continue end
        sh.nextThink = now + THINK_INT:GetFloat()

        if sh.state == STATE_CHARGING then
            -- elapsed real acumulado (no el intervalo nominal del throttle)
            local elapsed = now - (sh.lastRegenTick or now)
            sh.lastRegenTick = now
            -- ⚠ Se LEE el pool en cada tick en vez de acumular sobre una copia. Con
            -- el almacen en ply:Armor() eso es lo que hace que una bateria de Cargo
            -- usada a mitad de carga se sume sola en vez de que el proximo tick la
            -- pise con el valor que el escudo venia arrastrando.
            local pool = math.min(sh.max, PoolGet(ent, sh) + sh.rechargeRate * elapsed)
            PoolSet(ent, sh, pool)
            if pool >= sh.max then
                SetState(ent, STATE_UP)
                PlayShieldSounds(ent, "restore")
                EmitShieldFX(ent, FX_RESTORE)
                dprint(2, string.format("shield full %s (%d/%d)", ent:GetClass(), pool, sh.max))
            end
        elseif sh.canRegen and PoolGet(ent, sh) < sh.max and now >= sh.regenAt and now >= sh.lockoutUntil then
            -- DOWN o UP-parcial con delay (y lockout EMP) vencidos → empezar a cargar
            sh.lastRegenTick = now
            SetState(ent, STATE_CHARGING)
            dprint(2, string.format("shield charging %s (%.1f/%d)", ent:GetClass(), PoolGet(ent, sh), sh.max))
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

-- ⚠ EL `e:IsPlayer()` DE ARRIBA SE QUEDA, Y ES UNA DECISION, NO UN OLVIDO. El paso
-- 2 vuelve agnostico el ciclo de vida, pero la PUERTA del jugador no es esta:
-- OnEntityCreated corre cuando el jugador entra al server, y en ese instante
-- todavia no paso player_manager.SetPlayerClass — o sea que el SetMaxArmor de
-- SeedPool se lo pisaria el spawn, y sin un solo error. La puerta del jugador es
-- PlayerSpawn, que ademas es la unica que vuelve a correr en cada muerte.
--
-- ⚠⚠ Y CIERRA SIN `return` CON VALOR, igual que el listener de EntityTakeDamage de
-- core: hook.Call aborta la cadena cuando un listener devuelve algo, y del otro
-- lado de esta cadena esta GM:PlayerSpawn ENTERO — el loadout, el playermodel y el
-- gate `ready` de Cargo. Tres sintomas que serian uno, y ninguno imprime un error.
hook.Add("PlayerSpawn", "Caliber_Shields_PlayerSpawn", function(ply)
    -- Diferido por la misma razon que el de NPC, pero contra otro reloj: hay que
    -- caer DESPUES de que player_manager haya hecho SetMaxArmor + SetArmor con los
    -- valores de la clase, o SeedPool escribe primero y el spawn lo revierte. Se
    -- reusa el mismo 0.4 del lado NPC para no tener dos numeros que digan lo mismo.
    timer.Simple(0.4, function()
        if not IsValid(ply) or not ply:IsPlayer() then return end
        if not ply:Alive() then return end
        CALIBER.InitShield(ply)
    end)
end)

-- Cortar el sonido de carga CON LA ENTIDAD AÚN VÁLIDA: si el NPC muere y se
-- remueve en el mismo tick, la purga del Think no llega a cortarlo, y Source
-- REUTILIZA el índice de entidad → el loop quedaba pegado al índice y lo
-- heredaba el próximo NPC spawneado (bug de verificación del Bloque B).
hook.Add("OnNPCKilled", "Caliber_Shields_NPCKilled", function(npc)
    local sh = npc.Caliber_Shield
    if sh then StopChargeSound(npc, sh) end
    ShieldEnts[npc] = nil
end)

-- El gemelo del de arriba para el jugador: OnNPCKilled NO dispara para jugadores,
-- asi que sin esto el escudo de un jugador muerto queda registrado hasta que el
-- Think lo barra por Health() <= 0 — y el sonido de carga sigue sonando mientras
-- tanto, que es el bug del indice de entidad reutilizado que ya se pago una vez.
--
-- NO se llama RemoveShield: el escudo no se PIERDE al morir, se re-siembra en el
-- PlayerSpawn de al lado. Y ply:Armor() lo resetea el propio spawn.
-- ⚠ Sin `return` con valor: la cadena de PlayerDeath tambien es de todos.
hook.Add("PlayerDeath", "Caliber_Shields_PlayerDeath", function(ply)
    local sh = ply.Caliber_Shield
    if sh then StopChargeSound(ply, sh) end
    ShieldEnts[ply] = nil
end)

hook.Add("EntityRemoved", "Caliber_Shields_Cleanup", function(ent)
    local sh = ent.Caliber_Shield
    if sh and sh.chargeSnd and IsValid(ent) then
        ent:StopSound(sh.chargeSnd)
        sh.chargeSnd = nil
    end
    ShieldEnts[ent] = nil
end)

-- Hot-reload lua: el registry file-local se vació — re-registrar NPCs vivos.
-- En carga de mapa normal ents.GetAll() está vacío: no-op.
CALIBER.RefreshAllShields()

-- ── Concommands de debug (verificación del Bloque A sin UI) ──────────────────

-- Escudo efímero al NPC apuntado, SIN tocar el whitelist/JSON (paralelo al
-- stool de debug). caliber_shield_give [tipo] [max_hp]
-- Resuelve el sujeto de los tres concommands de debug: lo que estas mirando si es
-- un NPC o un jugador, y A TI MISMO si no estas mirando a nadie. Sin esto no hay
-- forma de darle un escudo al propio jugador —que es todo el sujeto del paso 2—
-- salvo en multiplayer mirando a otro.
-- ⚠ Imprime SIEMPRE sobre quien va a operar. Un comando que resuelve su sujeto
-- solo y no lo dice deja al que mide sin saber que midio.
local function ShieldTarget(ply)
    local e = IsValid(ply) and ply:GetEyeTrace().Entity or nil
    if IsValid(e) and (e:IsNPC() or e:IsPlayer()) then return e end
    if IsValid(ply) and ply:IsPlayer() then return ply end
    return nil
end

concommand.Add("caliber_shield_give", function(ply, _, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local e = ShieldTarget(ply)
    if not IsValid(e) then
        Corpus.Log("caliber", "[Caliber Shields] apunta a un NPC o a un jugador, o a nada para aplicartelo a ti mismo")
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
    local isPly = e:IsPlayer()
    local sh = {
        max = maxHp, type = stype, canRegen = d.can_regen,
        onArmor = isPly, frac = 0,
        bypass = isPly and BYPASS_TYPES_PLY or BYPASS_TYPES,
        rechargeDelay = d.recharge_delay, rechargeRate = d.recharge_rate,
        regenAt = 0, lockoutUntil = 0, state = 0, nextThink = 0,
    }
    e.Caliber_Shield = sh
    SeedPool(e, sh, maxHp)   -- pone `hp` en NPC, o ply:Armor()+techo en jugador
    SetState(e, STATE_UP)
    e:SetNWString("Caliber_Shield_Type", stype)
    e:SetNWVector("Caliber_Shield_Color", Vector(def.color.r, def.color.g, def.color.b))
    ShieldEnts[e] = true
    Corpus.Log("caliber", string.format("[Caliber Shields] %s ← %s %d HP  pool en %s  (efimero, no persiste)",
        e:GetClass(), stype, maxHp, isPly and "ply:Armor()" or "sh.hp"))
end)

concommand.Add("caliber_shield_clear", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local e = ShieldTarget(ply)
    if not IsValid(e) then
        Corpus.Log("caliber", "[Caliber Shields] apunta a un NPC o a un jugador, o a nada para aplicartelo a ti mismo")
        return
    end
    CALIBER.RemoveShield(e)
    Corpus.Log("caliber", "[Caliber Shields] escudo removido de " .. e:GetClass())
end)

concommand.Add("caliber_shield_status", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local e = ShieldTarget(ply)
    if not IsValid(e) then
        Corpus.Log("caliber", "[Caliber Shields] apunta a un NPC o a un jugador, o a nada para aplicartelo a ti mismo")
        return
    end
    local sh = e.Caliber_Shield
    if not sh then
        -- ⚠ Se imprime ADEMAS ply:Armor(). "Sin escudo" y "escudo a cero" son dos
        -- estados distintos que sobre el jugador dan el MISMO numero en la barra del
        -- panel, y sin este renglon no hay como separarlos desde afuera.
        Corpus.Log("caliber", string.format("[Caliber Shields] %s: SIN ESCUDO%s",
            e:GetClass(), e:IsPlayer() and string.format("  (ply:Armor()=%d, armadura de HL2 — Caliber no la toca)", e:Armor()) or ""))
        -- ⚠ El techo se imprime TAMBIEN sin escudo, y es lo unico que hace medible
        -- desde la consola que RemoveShield lo haya devuelto. Sin este renglon la
        -- unica via era un lua_run, y una fila que necesita otro instrumento para
        -- leerse mide dos cosas a la vez.
        if e:IsPlayer() and e.GetMaxArmor then
            Corpus.Log("caliber", string.format("[Caliber Shields]   techo del almacen  GetMaxArmor()=%d  (sin escudo tiene que ser el de la clase, 100 por default)", e:GetMaxArmor()))
        end
        return
    end
    local stateName = ({ [STATE_UP] = "UP", [STATE_DOWN] = "DOWN", [STATE_CHARGING] = "CHARGING" })[sh.state] or "?"
    Corpus.Log("caliber", string.format(
        "[Caliber Shields] %s: %s  %.2f/%d  pool_en=%s  state=%s  regen=%s(rate=%.1f/s)  regen_in=%.1fs  lockout_in=%.1fs  bypass=%d",
        e:GetClass(), sh.type, PoolGet(e, sh), sh.max,
        sh.onArmor and string.format("ply:Armor()=%d+frac=%.2f", e:Armor(), sh.frac or 0) or "sh.hp",
        stateName, tostring(sh.canRegen), sh.rechargeRate,
        math.max(0, sh.regenAt - CurTime()), math.max(0, sh.lockoutUntil - CurTime()),
        sh.bypass or BYPASS_TYPES))
    if sh.onArmor and e.GetMaxArmor then
        Corpus.Log("caliber", string.format(
            "[Caliber Shields]   techo del almacen  GetMaxArmor()=%d  max_hp=%d  (eran %d antes del escudo)",
            e:GetMaxArmor(), sh.max, e.Caliber_MaxArmorPrev or 100))
    end
end)
