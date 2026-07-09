-- corpus_caliber_scavenger.lua — subsistema de recolección de armas (server)
-- Migrado desde ADS 2.0 (ads_scavenger.lua). Cargado vía manifest tras core y limbs.
if CLIENT then return end

-- ============================================================
-- ConVars
-- ============================================================
local SCAV_EN      = CreateConVar("caliber_scavenger_enabled",              "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local DROP_LIFE    = CreateConVar("caliber_scavenger_drop_lifetime",        "60",  FCVAR_REPLICATED + FCVAR_ARCHIVE)
local SEARCH_RAD   = CreateConVar("caliber_scavenger_search_radius",        "800", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local PICKUP_DIST  = CreateConVar("caliber_scavenger_pickup_distance",      "40",  FCVAR_REPLICATED + FCVAR_ARCHIVE)
local THINK_INT    = CreateConVar("caliber_scavenger_think_interval",       "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local INT_COMBAT   = CreateConVar("caliber_scavenger_interrupt_combat",     "0",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local WORLD_WEPS   = CreateConVar("caliber_scavenger_allow_world_weapons",  "0",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local FORCE_ALL    = CreateConVar("caliber_scavenger_force_all_npcs",       "0",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local MOVE_MODE    = CreateConVar("caliber_scavenger_movement_mode",        "run", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local SCAV_DBG     = CreateConVar("caliber_scavenger_debug",                "0",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local POST_DROP_CD = CreateConVar("caliber_scavenger_post_drop_cooldown",   "8",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local DROP_OWN_T   = CreateConVar("caliber_scavenger_drop_ownership_time",  "30",  FCVAR_REPLICATED + FCVAR_ARCHIVE)
-- Retrieve-own mode: armed NPCs never swap; disarmed NPCs prioritize recovering
-- their own dropped weapon, falling back to normal scavenging on failure.
local RETRIEVE_EN  = CreateConVar("caliber_scavenger_retrieve_own",         "0",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local RETRIEVE_DEL = CreateConVar("caliber_scavenger_retrieve_delay",       "2",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local RETRIEVE_TO  = CreateConVar("caliber_scavenger_retrieve_timeout",     "20",  FCVAR_REPLICATED + FCVAR_ARCHIVE)
-- Crouch fallback: si el modelo no tiene animación de pickup (sets combine/metrocop),
-- el NPC se agacha un tiempo fijo antes de equipar, en vez de equipar instantáneo.
local CROUCH_FB    = CreateConVar("caliber_scavenger_crouch_fallback",      "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local CROUCH_TIME  = CreateConVar("caliber_scavenger_crouch_time",          "1.2", FCVAR_REPLICATED + FCVAR_ARCHIVE)

local function dprint(...) if SCAV_DBG:GetBool() then Corpus.Log("caliber", "[Caliber Scavenger]", ...) end end

-- ============================================================
-- Public API table — namespace vía tabla única registrada (Caliber_Architecture.md §3)
-- ============================================================
local CALIBER = Corpus.GetModule("caliber")
CALIBER.ScavengerWeightOverrides = {}

-- Registered scavenger NPCs: [entity] = true.
-- Maintained proactively to avoid iterating all entities each Think tick.
local ScavengerNPCs = {}

-- Hold types that are problematic/unusable for NPCs
local BAD_HOLD_TYPES = {
    physgun = true,
    camera  = true,
    magic   = true,
    grenade = true,
}

-- ============================================================
-- Persistence: weight overrides — vía primitiva Corpus.Data (clean-slate).
-- Ruta: data/corpus/caliber/scav_weights.json
-- ============================================================
local function LoadOverrides()
    CALIBER.ScavengerWeightOverrides = {}
    local tbl = Corpus.Data.Load("caliber", "scav_weights")
    if type(tbl) ~= "table" then return end
    for k, v in pairs(tbl) do
        if type(k) == "string" and tonumber(v) then
            CALIBER.ScavengerWeightOverrides[k] = tonumber(v)
        end
    end
end

local function SaveOverrides()
    Corpus.Data.Save("caliber", "scav_weights", CALIBER.ScavengerWeightOverrides)
end

-- ============================================================
-- Weapon marking
-- ============================================================

-- Public: mark a weapon as scavengeable, tracking which NPC dropped it.
-- permanent=true → never expires (math.huge timestamp, used for world weapons).
-- npc parameter is optional; when set, the ownership cooldown prevents that NPC
-- from picking the weapon back up for caliber_scavenger_drop_ownership_time seconds.
function CALIBER.MarkWeaponAsDroppedBy(weapon, npc, permanent)
    if not IsValid(weapon) or not weapon:IsWeapon() then return end
    weapon.Caliber_WasDropped = true
    weapon.Caliber_DropTime   = permanent and math.huge or CurTime()
    if IsValid(npc) then
        weapon.Caliber_DroppedBy     = npc:EntIndex()
        weapon.Caliber_DroppedByTime = CurTime()
    end
    dprint("mark", weapon:GetClass(), "permanent=" .. tostring(permanent == true),
           IsValid(npc) and ("dropper=" .. npc:GetClass()) or "")
end

-- Backward-compatible wrapper: no dropper tracking, other NPCs can pick up immediately.
function CALIBER.MarkWeaponAsDropped(weapon, permanent)
    CALIBER.MarkWeaponAsDroppedBy(weapon, nil, permanent)
end

-- Public: record the weapon an NPC just lost involuntarily (limb-break drop from
-- caliber_limbs) so retrieve-own mode can prioritize it. Always recorded (cheap) but
-- only CONSUMED when caliber_scavenger_retrieve_own is on, so hot-toggling works.
-- Deliberately NOT folded into MarkWeaponAsDroppedBy: that is also called for
-- voluntary swaps (EquipWeapon) and death drops, which must not trigger retrieval.
function CALIBER.RecordOwnWeaponDrop(npc, weapon, class)
    if not IsValid(npc) or not npc:IsNPC() then return end
    npc.Caliber_OwnWeaponDrop = {
        wep   = weapon,  -- entity reference, never EntIndex (indices get recycled)
        time  = CurTime(),
        class = class or (IsValid(weapon) and weapon:GetClass()) or "?",
    }
    npc.Caliber_EverArmed = true  -- it dropped a weapon, so it was armed
    if RETRIEVE_EN:GetBool() then
        -- Shorten any pending cooldown (e.g. 8s post-drop) so retrieval starts
        -- after the configured delay; normal mode timing is left untouched.
        local wakeAt = CurTime() + RETRIEVE_DEL:GetFloat()
        if (npc.Caliber_NextScavengerCheck or 0) > wakeAt then
            npc.Caliber_NextScavengerCheck = wakeAt
        end
    end
    dprint("own-drop recorded", npc:GetClass(), "->", npc.Caliber_OwnWeaponDrop.class)
end

-- Returns true if the weapon is currently eligible for pickup.
local function IsScavengeable(weapon)
    if not IsValid(weapon) then return false end
    if not weapon:IsWeapon() then return false end
    if not weapon.Caliber_WasDropped then return false end
    if IsValid(weapon:GetOwner()) then return false end
    if weapon:IsPlayerHolding() then return false end
    if weapon:GetClass() == "weapon_nothingfornpc" then return false end
    if BAD_HOLD_TYPES[weapon:GetHoldType()] then return false end
    -- Lifetime: math.huge means permanent (world weapons)
    if weapon.Caliber_DropTime ~= math.huge then
        if (CurTime() - weapon.Caliber_DropTime) > DROP_LIFE:GetFloat() then return false end
    end
    return true
end

-- ============================================================
-- Weapon weight
-- ============================================================

-- Slot fallback weights for weapons with no Primary.Damage defined
local SLOT_WEIGHTS = {[0]=1, [1]=5, [2]=8, [3]=12, [4]=15}

local function GetWeaponWeight(weapon)
    if not IsValid(weapon) then return 0 end
    -- Return cached value if available
    if weapon.Caliber_AutoWeight then return weapon.Caliber_AutoWeight end
    -- Manual override has priority
    local cls  = weapon:GetClass()
    local over = CALIBER.ScavengerWeightOverrides[cls]
    if over then
        weapon.Caliber_AutoWeight = over
        return over
    end
    -- Auto-calculate from weapon properties
    local dmg   = tonumber(weapon.Primary and weapon.Primary.Damage)   or 0
    local delay = tonumber(weapon.Primary and weapon.Primary.Delay)    or 1
    local clip  = tonumber(weapon.Primary and weapon.Primary.ClipSize) or 1
    local w
    if dmg <= 0 then
        local slot = tonumber(weapon:GetSlot()) or -1
        w = SLOT_WEIGHTS[slot] or (slot >= 5 and 10 or 3)
    else
        w = dmg * (1 / math.max(delay, 0.05)) * math.sqrt(math.max(clip, 1)) / 10
    end
    w = math.Clamp(w, 0.1, 100)
    weapon.Caliber_AutoWeight = w
    return w
end

-- Set a manual weight override for a weapon class.
function CALIBER.SetWeaponWeight(class, weight)
    if not class or not tonumber(weight) then return end
    weight = math.Clamp(tonumber(weight), 0, 1000)
    CALIBER.ScavengerWeightOverrides[class] = weight
    SaveOverrides()
    -- Invalidate cache on all currently-spawned weapons of this class
    for _, wep in ipairs(ents.FindByClass(class)) do
        if IsValid(wep) then wep.Caliber_AutoWeight = nil end
    end
    Corpus.Log("caliber", "[Caliber Scavenger] Weight override set:", class, "=", weight)
end

-- Clear a manual weight override and re-invalidate the cache of spawned weapons.
function CALIBER.ClearWeaponWeight(class)
    if not class or class == "" then return end
    CALIBER.ScavengerWeightOverrides[class] = nil
    SaveOverrides()
    for _, wep in ipairs(ents.FindByClass(class)) do
        if IsValid(wep) then wep.Caliber_AutoWeight = nil end
    end
    Corpus.Log("caliber", "[Caliber Scavenger] Weight override cleared for:", class)
end

function CALIBER.GetWeaponWeightOverride(class)
    return CALIBER.ScavengerWeightOverrides[class]
end

-- Expose weight calculation publicly for inspect and external integrations
CALIBER.GetWeaponWeight = GetWeaponWeight

-- Apply post-drop cooldown: NPC won't scavenge again for POST_DROP_CD seconds.
-- Called after any weapon equip attempt (success or failure) to prevent re-scan loops.
local function ApplyPostDropCooldown(npc)
    if not IsValid(npc) then return end
    npc.Caliber_NextScavengerCheck = CurTime() + POST_DROP_CD:GetFloat()
end

-- ============================================================
-- NPC registration
-- ============================================================

local function RegisterNPC(npc)
    if not IsValid(npc) or not npc:IsNPC() then return end

    -- Caliber blacklisted NPCs don't scavenge (combatants that intentionally have no armor).
    -- IsUserBlacklisted resuelve key de spawnmenu > classname (ver caliber_core).
    if CALIBER.IsUserBlacklisted and CALIBER.IsUserBlacklisted(npc) then
        npc.Caliber_CanScavenge = false
        dprint("register", npc:GetClass(), "can_scavenge=false (Caliber blacklist)")
        return
    end

    -- Auto-detect: NPCs that spawned with a real weapon are considered "armed by trade".
    -- Always computed (even under force_all): retrieve-own mode uses Caliber_EverArmed
    -- to keep never-armed NPCs from picking anything up.
    local wep = npc:GetActiveWeapon()
    local spawnedArmed = IsValid(wep) and wep:GetClass() ~= "weapon_nothingfornpc"
    npc.Caliber_EverArmed = npc.Caliber_EverArmed or spawnedArmed

    npc.Caliber_CanScavenge = FORCE_ALL:GetBool() or spawnedArmed

    npc.Caliber_NextScavengerCheck    = 0
    npc.Caliber_ScavengerTargetWeapon = nil

    if npc.Caliber_CanScavenge then
        ScavengerNPCs[npc] = true
    end

    dprint("register", npc:GetClass(), "can_scavenge=" .. tostring(npc.Caliber_CanScavenge))
end

-- ============================================================
-- Pickup animation
-- ============================================================

-- Candidatas en orden de preferencia; PlayAnim de VJ acepta activities y strings de
-- secuencia (auto-convierte), y valida con VJ.AnimExists (devuelve dur=0 si falta).
local PICKUP_ANIMS_VJ = {ACT_PICKUP_GROUND, ACT_PICKUP_RACK, "pickup", "pickup_weapon", "physgun_pickup"}

-- Fallback de agacharse cuando el modelo no tiene anim de pickup (sets combine y
-- metrocop no traen ACT_PICKUP_*). En VJ, ACT_COVER_LOW se traduce por set DENTRO
-- de PlayAnim (combine → ACT_COVER + vjseq_Leanwall_Crouch*, metrocop →
-- ACT_COVER_SMG1_LOW, rebel → coverlow) — un candidato cubre todos los sets.
-- OJO: son idles en LOOP → lockAnimTime SIEMPRE numérico fijo, nunca false.
local CROUCH_ANIMS_VJ     = {ACT_COVER_LOW, ACT_CROUCHIDLE}
local CROUCH_ANIMS_NATIVE = {ACT_COVER_LOW, ACT_COVER_SMG1_LOW, ACT_CROUCHIDLE}

-- Devuelve la duración FIJA del agachado, o 0 (apagado / modelo sin anim de crouch).
local function TryCrouchFallback(npc)
    if not CROUCH_FB:GetBool() then return 0 end
    local t = math.Clamp(CROUCH_TIME:GetFloat(), 0.3, 3.0)

    if npc.IsVJBaseSNPC and npc.VJ_ACT_PLAYACTIVITY then
        for _, anim in ipairs(CROUCH_ANIMS_VJ) do
            -- lockAnim=true: mismo mecanismo que la anim de pickup (corta el schedule
            -- y bloquea chase/idle/ataques). lockAnimTime=t numérico: con false, VJ
            -- calcularía la duración del loop y el NPC quedaría clavado un ciclo
            -- arbitrario. PlayAnim valida con VJ.AnimExists → dur=0 si falta.
            local ok, _, dur = pcall(npc.VJ_ACT_PLAYACTIVITY, npc, anim, true, t, false)
            if ok and isnumber(dur) and dur > 0 then
                dprint("crouch fallback (VJ)", npc:GetClass(), "t=" .. t)
                return t
            end
        end
        return 0
    end

    -- Nativos: mismo patrón ResetSequence de los approaches 1/2. Parquear la IA en
    -- idle primero minimiza que el FSM pise la pose durante el agachado (si igual
    -- la pisa, se conserva el beneficio funcional: el equip queda diferido).
    for _, act in ipairs(CROUCH_ANIMS_NATIVE) do
        local seq = npc:SelectWeightedSequence(act)
        if seq and seq >= 0 then
            local ok = pcall(function()
                npc:SetSchedule(SCHED_IDLE_STAND)
                npc:ResetSequence(seq)
                npc:SetCycle(0)
                npc:SetPlaybackRate(1)
            end)
            if ok then
                dprint("crouch fallback (native)", npc:GetClass(), "t=" .. t)
                return t
            end
        end
    end
    return 0
end

local function TryPickupAnimation(npc)
    if not IsValid(npc) then return 0 end

    -- Rama VJ: ResetSequence crudo no sirve aquí — el FSM de RunAI (0.1 s) lo pisa
    -- al siguiente tick. VJ_ACT_PLAYACTIVITY (alias de PlayAnim) con lockAnim=true
    -- interrumpe el schedule en curso (StopMoving + ClearSchedule) y bloquea
    -- chase/idle/ataques durante la animación; lockAnimTime=false = duración real.
    if npc.IsVJBaseSNPC and npc.VJ_ACT_PLAYACTIVITY then
        for _, anim in ipairs(PICKUP_ANIMS_VJ) do
            local ok, _, dur = pcall(npc.VJ_ACT_PLAYACTIVITY, npc, anim,
                true,   -- lockAnim: bloquea la IA mientras dura la animación
                false,  -- lockAnimTime=false: que VJ calcule la duración real
                false)  -- faceEnemy: sin rotación
            if ok and isnumber(dur) and dur > 0 then return dur end
        end
        return TryCrouchFallback(npc)  -- sin anim de pickup: agacharse (o 0 = inmediato)
    end

    -- Approach 1: native Source pickup activities (Combine, Citizen, Metropolice support these)
    local activities = {ACT_PICKUP_GROUND, ACT_PICKUP_RACK}
    for _, act in ipairs(activities) do
        local seq = npc:SelectWeightedSequence(act)
        if seq and seq >= 0 then
            local ok = pcall(function()
                npc:ResetSequence(seq)
                npc:SetCycle(0)
                npc:SetPlaybackRate(1)
            end)
            if ok then
                local dur = npc:SequenceDuration(seq) or 0
                return dur > 0 and dur or 1.0
            end
        end
    end

    -- Approach 2: fallback to named sequences for legacy or custom models
    local sequences = {"pickup", "pickup_weapon", "physgun_pickup"}
    for _, seqName in ipairs(sequences) do
        local seq = npc:LookupSequence(seqName)
        if seq and seq >= 0 then
            local ok = pcall(function()
                npc:ResetSequence(seq)
                npc:SetCycle(0)
                npc:SetPlaybackRate(1)
            end)
            if ok then
                local dur = npc:SequenceDuration(seq) or 0
                return dur > 0 and dur or 1.0
            end
        end
    end

    return TryCrouchFallback(npc)  -- no pickup animation: crouch fallback (or 0 = equip now)
end

-- ============================================================
-- NPC movement toward weapon
-- ============================================================

local function MoveNPCToWeapon(npc, weapon)
    if not IsValid(npc) or not IsValid(weapon) then return end
    npc:SetLastPosition(weapon:GetPos())

    if npc.IsVJBaseSNPC then
        -- VJ Base: use SCHEDULE_GOTO_POSITION with native task name
        local taskName = MOVE_MODE:GetString() == "walk" and "TASK_WALK_PATH" or "TASK_RUN_PATH"
        local ok = pcall(function()
            npc:SCHEDULE_GOTO_POSITION(taskName, function(x)
                x.CanShootWhenMoving = true
                x.TurnData = {Type = VJ.FACE_ENEMY}
            end)
        end)
        if not ok then
            dprint("VJ schedule failed, fallback to native for", npc:GetClass())
            local sched = MOVE_MODE:GetString() == "walk" and SCHED_FORCED_GO or SCHED_FORCED_GO_RUN
            pcall(function() npc:SetSchedule(sched) end)
        end
    else
        local sched = MOVE_MODE:GetString() == "walk" and SCHED_FORCED_GO or SCHED_FORCED_GO_RUN
        pcall(function() npc:SetSchedule(sched) end)
    end
end

-- ============================================================
-- Equip weapon
-- ============================================================

local function HasNoWeapon(npc)
    local wep = npc:GetActiveWeapon()
    return not IsValid(wep) or wep:GetClass() == "weapon_nothingfornpc"
end

local function EquipWeapon(npc, newWeapon)
    if not IsValid(npc) or not IsValid(newWeapon) then return end
    -- Retrieve-own mode: armed NPCs never swap (covers the one-tick race where the
    -- NPC got a weapon while en route to a target)
    if RETRIEVE_EN:GetBool() and not HasNoWeapon(npc) then return end
    local newClass = newWeapon:GetClass()

    -- Drop current weapon before equipping new one so it stays in the world
    local current = npc:GetActiveWeapon()
    if IsValid(current) and current:GetClass() ~= "weapon_nothingfornpc" then
        local dropPos = npc:GetPos() + npc:GetForward() * 20 + Vector(0, 0, 30)
        local dropped = current
        pcall(function() npc:DropWeapon(current, dropPos, Vector(0, 0, 50)) end)
        -- Mark with ownership so this NPC won't immediately re-pick it up
        timer.Simple(0.05, function()
            if IsValid(dropped) then
                CALIBER.MarkWeaponAsDroppedBy(dropped, npc)
            end
        end)
    end

    -- Try pickup animation; returns duration in seconds (0 = no animation, equip immediately)
    local animDuration = TryPickupAnimation(npc)

    local function doEquip()
        if not IsValid(npc) or not IsValid(newWeapon) then return end
        pcall(function() npc:Give(newClass) end)

        -- Validate that the NPC actually received the weapon (some NPC types cannot hold any)
        timer.Simple(0.1, function()
            if not IsValid(newWeapon) then return end
            if not IsValid(npc) then return end

            local equipped = false
            for _, w in ipairs(npc:GetWeapons()) do
                if IsValid(w) and w:GetClass() == newClass then
                    equipped = true
                    break
                end
            end

            if equipped then
                newWeapon:Remove()
                dprint("equip", npc:GetClass(), "<-", newClass)
            else
                -- Give failed: NPC cannot hold weapons. Leave world entity intact for others.
                npc.Caliber_CanScavenge = false
                ScavengerNPCs[npc]  = nil  -- stop Think from processing this NPC
                dprint("equip FAILED for", npc:GetClass(),
                       "leaving weapon in world, marking as non-scavenger")
            end
        end)
    end

    if animDuration > 0 then
        timer.Simple(animDuration * 0.7, doEquip)
    else
        doEquip()
    end

    -- Clear target and apply cooldown regardless of equip outcome
    npc.Caliber_ScavengerTargetWeapon = nil
    npc.Caliber_OwnWeaponDrop         = nil  -- equipped something: retrieval done or obsolete
    ApplyPostDropCooldown(npc)
end

-- ============================================================
-- Find best weapon
-- ============================================================

local function FindBestWeapon(npc)
    if not IsValid(npc) then return nil end

    -- Baseline: must strictly beat what NPC currently has
    local curWep    = npc:GetActiveWeapon()
    local curWeight = 0
    if IsValid(curWep) and curWep:GetClass() ~= "weapon_nothingfornpc" then
        curWeight = GetWeaponWeight(curWep)
    end

    local bestWep    = nil
    local bestWeight = curWeight

    for _, ent in ipairs(ents.FindInSphere(npc:GetPos(), SEARCH_RAD:GetFloat())) do
        if not IsValid(ent) then continue end
        if not ent:IsWeapon() then continue end
        if not IsScavengeable(ent) then continue end
        if not npc:Visible(ent) then continue end  -- avoids weapons through walls
        -- Skip weapons this NPC dropped recently (ownership window prevents self re-pick)
        if ent.Caliber_DroppedBy == npc:EntIndex() then
            local elapsed = CurTime() - (ent.Caliber_DroppedByTime or 0)
            if elapsed < DROP_OWN_T:GetFloat() then continue end
        end
        local w = GetWeaponWeight(ent)
        if w > bestWeight then
            bestWeight = w
            bestWep    = ent
        end
    end

    return bestWep
end

-- ============================================================
-- Per-NPC processing (called from Think)
-- ============================================================

local function ProcessScavengerNPC(npc)
    if not IsValid(npc) then return end
    if npc:Health() <= 0 then return end

    -- Combat interrupt gate: unarmed NPCs always bypass; others respect convar
    if IsValid(npc:GetEnemy()) and not INT_COMBAT:GetBool() then
        if not HasNoWeapon(npc) then return end
    end

    -- ── Retrieve-own mode ─────────────────────────────────────────────────
    if RETRIEVE_EN:GetBool() then
        -- Armed NPCs NEVER swap weapons; clear any state inherited from normal mode
        if not HasNoWeapon(npc) then
            npc.Caliber_ScavengerTargetWeapon = nil
            npc.Caliber_OwnWeaponDrop         = nil
            return
        end
        -- Never-armed NPCs pick nothing up, even under force_all
        if not npc.Caliber_EverArmed then return end

        local drop = npc.Caliber_OwnWeaponDrop
        if drop then
            -- Floor of 0.25s guarantees the deferred mark (0.05s timer) already ran
            local delay   = math.max(RETRIEVE_DEL:GetFloat(), 0.25)
            local elapsed = CurTime() - drop.time
            if elapsed < delay then return end
            if elapsed > RETRIEVE_TO:GetFloat() or not IsScavengeable(drop.wep) then
                -- Gone / taken by someone else / timed out → fall back to normal scavenging
                dprint("retrieve ABORT", npc:GetClass(), drop.class,
                       IsScavengeable(drop.wep) and "timeout" or "weapon unavailable")
                if npc.Caliber_ScavengerTargetWeapon == drop.wep then
                    npc.Caliber_ScavengerTargetWeapon = nil
                end
                npc.Caliber_OwnWeaponDrop = nil
                -- no return: continue into the normal flow below (FindBestWeapon)
            else
                -- Prioritize the NPC's own weapon as a direct target. This deliberately
                -- bypasses the self-ownership exclusion in FindBestWeapon; IsScavengeable
                -- does not care who dropped the weapon.
                if npc.Caliber_ScavengerTargetWeapon ~= drop.wep then
                    npc.Caliber_ScavengerTargetWeapon = drop.wep
                    MoveNPCToWeapon(npc, drop.wep)
                    npc.Caliber_NextMoveReissue = CurTime() + 1.5
                    dprint("retrieve GO", npc:GetClass(), "->", drop.class)
                elseif CurTime() > (npc.Caliber_NextMoveReissue or 0) then
                    -- Re-issue movement: combat/flinch from the broken arm cancels schedules
                    MoveNPCToWeapon(npc, drop.wep)
                    npc.Caliber_NextMoveReissue = CurTime() + 1.5
                end
                -- The target-tracking block below handles the equip at pickup distance
            end
        end
        -- No record (or aborted): disarmed NPC that was armed at some point falls
        -- through to the normal flow; with bestWeight=0 it grabs any scavengeable weapon.
    end

    -- If already tracking a target, check it first
    local target = npc.Caliber_ScavengerTargetWeapon
    if IsValid(target) then
        if not IsScavengeable(target) then
            -- Target expired or removed; fall through to find a new one
            npc.Caliber_ScavengerTargetWeapon = nil
        else
            local dist = npc:GetPos():Distance(target:GetPos())
            if dist <= PICKUP_DIST:GetFloat() then
                EquipWeapon(npc, target)
            end
            -- Still en-route; MoveNPCToWeapon was already called, don't repeat
            return
        end
    end

    -- No current target: scan for a better weapon
    local best = FindBestWeapon(npc)
    if not best then return end

    local dist = npc:GetPos():Distance(best:GetPos())
    dprint("target", npc:GetClass(), "->", best:GetClass(),
        "dist="    .. string.format("%.0f", dist),
        "weight="  .. string.format("%.1f", GetWeaponWeight(best)))

    if dist <= PICKUP_DIST:GetFloat() then
        EquipWeapon(npc, best)
    else
        npc.Caliber_ScavengerTargetWeapon = best
        MoveNPCToWeapon(npc, best)
    end
end

-- ============================================================
-- Global Think loop — single hook, no per-NPC Think overhead
-- ============================================================

hook.Add("Think", "Caliber_Scavenger_Think", function()
    if not SCAV_EN:GetBool() then return end
    if not next(ScavengerNPCs) then return end  -- early exit when world is empty

    local now = CurTime()
    for npc, _ in pairs(ScavengerNPCs) do
        if not IsValid(npc) then
            ScavengerNPCs[npc] = nil
            continue
        end
        if not npc.Caliber_CanScavenge then
            ScavengerNPCs[npc] = nil
            continue
        end
        if now < (npc.Caliber_NextScavengerCheck or 0) then continue end
        npc.Caliber_NextScavengerCheck = now + THINK_INT:GetFloat()
        ProcessScavengerNPC(npc)
    end
end)

-- ============================================================
-- Drop detection: NPC death
-- ============================================================

hook.Add("OnNPCKilled", "Caliber_Scavenger_NPCKilled", function(npc, attacker, inflictor)
    -- Record what weapon class the NPC had before it was killed
    local wep = npc:GetActiveWeapon()
    if not IsValid(wep) then return end
    local wclass = wep:GetClass()
    if wclass == "weapon_nothingfornpc" then return end

    local lastPos = npc:GetPos()
    -- Small delay: Source creates the dropped weapon entity slightly after the kill event
    timer.Simple(0.15, function()
        for _, ent in ipairs(ents.FindInSphere(lastPos, 120)) do
            if not IsValid(ent) then continue end
            if not ent:IsWeapon() then continue end
            if ent:GetClass() ~= wclass then continue end
            if ent.Caliber_WasDropped then continue end  -- already marked by another source
            if IsValid(ent:GetOwner()) then continue end
            -- Pass the dead NPC as dropper: it can't pick it up (it's dead), but
            -- using MarkWeaponAsDroppedBy lets other code distinguish source if needed.
            CALIBER.MarkWeaponAsDroppedBy(ent, npc, false)
        end
    end)
end)

-- ============================================================
-- Drop detection: Player drops weapon
-- ============================================================

hook.Add("PlayerDroppedWeapon", "Caliber_Scavenger_PlayerDrop", function(ply, weapon)
    if not IsValid(weapon) then return end
    CALIBER.MarkWeaponAsDropped(weapon, false)
end)

-- ============================================================
-- Entity creation: NPC registration + world weapon marking
-- ============================================================

hook.Add("OnEntityCreated", "Caliber_Scavenger_EntityCreated", function(ent)
    if not IsValid(ent) then return end

    if ent:IsWeapon() then
        -- World weapon: mark as permanent if the convar is enabled.
        -- Deferred one frame so PlayerDroppedWeapon/OnNPCKilled can mark first;
        -- if another source already set Caliber_WasDropped, we skip.
        if WORLD_WEPS:GetBool() then
            timer.Simple(0, function()
                if not IsValid(ent) then return end
                if ent.Caliber_WasDropped then return end     -- already claimed by NPC/player drop
                if IsValid(ent:GetOwner()) then return end  -- currently owned
                CALIBER.MarkWeaponAsDropped(ent, true)
            end)
        end
        return
    end

    if not ent:IsNPC() then return end
    -- Delay > caliber_core's 0.2s and caliber_limbs's 0.3s; also lets VJ finish arming the NPC
    timer.Simple(0.5, function()
        RegisterNPC(ent)
    end)
end)

-- ============================================================
-- Cleanup
-- ============================================================

hook.Add("EntityRemoved", "Caliber_Scavenger_Cleanup", function(ent)
    ScavengerNPCs[ent] = nil
end)

-- ============================================================
-- Ever-armed tracking (retrieve-own mode)
-- ============================================================

-- Covers NPCs armed after spawn (toolgun, Give, the scavenger itself)
hook.Add("WeaponEquip", "Caliber_Scavenger_EverArmed", function(weapon, owner)
    if not IsValid(owner) or not owner:IsNPC() then return end
    if not IsValid(weapon) or weapon:GetClass() == "weapon_nothingfornpc" then return end
    owner.Caliber_EverArmed = true
end)

-- ============================================================
-- Console commands (admin-only)
-- ============================================================

concommand.Add("caliber_scavenger_set_weight", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local class  = args[1]
    local weight = tonumber(args[2])
    if not class or not weight then
        Corpus.Log("caliber", "[Caliber Scavenger] Usage: caliber_scavenger_set_weight <class> <weight>")
        return
    end
    CALIBER.SetWeaponWeight(class, weight)
end)

concommand.Add("caliber_scavenger_clear_weight", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local class = args[1]
    if not class then
        Corpus.Log("caliber", "[Caliber Scavenger] Usage: caliber_scavenger_clear_weight <class>")
        return
    end
    CALIBER.ClearWeaponWeight(class)
end)

concommand.Add("caliber_scavenger_list_weights", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then return end
    Corpus.Log("caliber", "[Caliber Scavenger] Weight overrides:")
    local count = 0
    for class, weight in pairs(CALIBER.ScavengerWeightOverrides) do
        Corpus.Log("caliber", string.format("  %-40s = %.2f", class, weight))
        count = count + 1
    end
    if count == 0 then Corpus.Log("caliber", "  (none)") end
end)

-- ============================================================
-- Browser UI: weight overrides (net strings registered in corpus_caliber_core.lua)
-- ============================================================

local function SendScavWeightsTo(ply)
    if not IsValid(ply) then return end
    net.Start("corpus_caliber_scav_weights_data")
    net.WriteTable(CALIBER.ScavengerWeightOverrides or {})
    net.Send(ply)
end

net.Receive("corpus_caliber_request_scav_weights", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    SendScavWeightsTo(ply)
end)

-- Payload: string classname + bool remove + float weight.
-- Explicit remove flag: 0 is a legitimate weight ("never pick this up"),
-- so no magic sentinel values.
net.Receive("corpus_caliber_save_scav_weight", function(_, ply)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local class  = net.ReadString()
    local remove = net.ReadBool()
    local weight = net.ReadFloat()
    if not class or class == "" then return end
    if remove then
        CALIBER.ClearWeaponWeight(class)
    else
        CALIBER.SetWeaponWeight(class, weight)  -- clamps to [0,1000] and persists JSON
    end
    SendScavWeightsTo(ply)  -- echo back so the client re-renders with fresh data
end)

-- ============================================================
-- Startup
-- ============================================================

LoadOverrides()
Corpus.Log("caliber", string.format("[Caliber Scavenger] Loaded. Weight overrides: %d", table.Count(CALIBER.ScavengerWeightOverrides)))

-- ============================================================
-- INTEGRATION WITH Caliber LIMBS
-- ============================================================
-- TryDropWeapon() in corpus_caliber_limbs.lua marks limb-break drops via
-- CALIBER.MarkWeaponAsDroppedBy (ownership window keeps the dropper from
-- re-picking it in normal mode) and registers them via
-- CALIBER.RecordOwnWeaponDrop (consumed by retrieve-own mode). Both calls
-- are guarded with "if CALIBER.X then" so limbs works without this file.
