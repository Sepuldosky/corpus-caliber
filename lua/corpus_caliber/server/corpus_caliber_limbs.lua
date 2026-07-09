-- corpus_caliber_limbs.lua — subsistema de HP de extremidades (server)
-- Migrado desde ADS 2.0 (ads_limbs.lua). Cargado vía manifest tras core.
if CLIENT then return end

local CALIBER = Corpus.GetModule("caliber")
local DBG = GetConVar("caliber_debug")  -- reuse core debug convar
-- level: minimum caliber_debug tier (1=compact+, 2=verbose/events only)
local function dprint(level, ...) if DBG and DBG:GetInt() >= level then Corpus.Log("caliber", "[Caliber Limbs]", ...) end end

-- Convars (all FCVAR_REPLICATED so corpus_caliber_client_options.lua sliders work)
local EN_LIMBS      = CreateConVar("caliber_limbs_enabled",                    "1",   FCVAR_REPLICATED + FCVAR_ARCHIVE)
local HEAD_FRAC     = CreateConVar("caliber_limb_head_frac",                   "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local ARMS_FRAC     = CreateConVar("caliber_limb_arms_frac",                   "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local LEGS_FRAC     = CreateConVar("caliber_limb_legs_frac",                   "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local DMG_XFER_HEAD = CreateConVar("caliber_limb_damage_transfer_head",        "1.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local DMG_XFER_ARMS = CreateConVar("caliber_limb_damage_transfer_arms",        "0.7", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local DMG_XFER_LEGS = CreateConVar("caliber_limb_damage_transfer_legs",        "0.7", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local ACC_ARM       = CreateConVar("caliber_limb_accuracy_max_penalty_per_arm","1.0", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local ACC_HEAD      = CreateConVar("caliber_limb_accuracy_max_penalty_head",   "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local SPD_LEG       = CreateConVar("caliber_limb_min_speed_mult_per_leg",      "0.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local VJ_LIMP_T     = CreateConVar("caliber_limb_vj_limp_threshold",           "0.7", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local STN50_DUR     = CreateConVar("caliber_limb_head_stun_50_duration",       "1.0", FCVAR_REPLICATED + FCVAR_ARCHIVE)
local STN25_DUR     = CreateConVar("caliber_limb_head_stun_25_duration",       "2.5", FCVAR_REPLICATED + FCVAR_ARCHIVE)

-- Safe ratio: returns 0 if max is invalid instead of NaN/inf
local function safeRatio(cur, max)
    if not max or max <= 0 then return 0 end
    return math.Clamp(cur / max, 0, 1)
end

-- Try to get a bone world position; returns nil on failure
local function GetBonePos(npc, boneName)
    local ok, pos = pcall(function()
        local idx = npc:LookupBone(boneName)
        if idx then return npc:GetBonePosition(idx) end
    end)
    return (ok and pos) or nil
end

-- Best-effort weapon drop for NPCs. Returns the world entity left behind (or nil).
-- Marks the weapon for the scavenger subsystem and records it as the NPC's own
-- drop (retrieve-own mode). Guards keep limbs working without corpus_caliber_scavenger.lua.
local function TryDropWeapon(npc, pos)
    local wep = npc:GetActiveWeapon()
    if not IsValid(wep) then return nil end
    local cls     = wep:GetClass()
    local dropPos = pos or (npc:GetPos() + Vector(0, 0, 32))
    local dropped = nil
    -- Attempt 1: engine-level drop (exposed for some human NPC types)
    local ok = pcall(function() npc:DropWeapon(wep, dropPos, Vector(0, 0, 50)) end)
    if ok then
        dropped = wep
        -- Deferred mark: the engine clears weapon ownership one tick after the drop
        -- (same pattern as EquipWeapon in corpus_caliber_scavenger.lua)
        timer.Simple(0.05, function()
            if IsValid(dropped) and not IsValid(dropped:GetOwner())
               and CALIBER.MarkWeaponAsDroppedBy then
                CALIBER.MarkWeaponAsDroppedBy(dropped, npc)
            end
        end)
    else
        -- Attempt 2: spawn world copy + strip from NPC (the original is destroyed,
        -- so the copy is what gets tracked)
        local w = ents.Create(cls)
        if IsValid(w) then
            w:SetPos(dropPos)
            w:Spawn()
            pcall(function() w:PhysWake() end)
            dropped = w
            if CALIBER.MarkWeaponAsDroppedBy then CALIBER.MarkWeaponAsDroppedBy(w, npc) end
        end
        pcall(function() npc:StripWeapon(cls) end)
    end
    -- Record for the scavenger's retrieve-own mode
    if dropped and CALIBER.RecordOwnWeaponDrop then
        CALIBER.RecordOwnWeaponDrop(npc, dropped, cls)
    end
    return dropped
end

-- ── Cojera VJ (base humana) ──────────────────────────────────────────────────
-- Los NPC VJ de suelo usan el motor NATIVO de pathing (TASK_RUN_PATH/TASK_WALK_PATH):
-- la velocidad real sale del root motion de la animación de locomoción, que VJ elige
-- vía ENT:TranslateActivity + AnimationTranslations (por hold type del arma). Palanca
-- correcta: degradar la familia run→walk ANTES de la traducción de VJ — las ramas
-- internas de TranslateActivity llaman self:TranslateActivity recursivamente
-- (npc_vj_human_base/init.lua L2437/L2448), así que las variantes de arma/aim
-- (ACT_WALK_AIM_RIFLE, etc.) se conservan solas. SetPlaybackRate quedó descartado:
-- VJ lo detourea hacia AnimPlaybackRate (funcs.lua L872) y eso escala TODAS las
-- animaciones (recarga, ataque) y los timers que dependen de ellas.
local VJ_RUN_TO_WALK = {
    [ACT_RUN]            = ACT_WALK,
    [ACT_RUN_AIM]        = ACT_WALK_AIM,
    [ACT_RUN_AGITATED]   = ACT_WALK_AGITATED,
    [ACT_RUN_CROUCH]     = ACT_WALK_CROUCH,
    [ACT_RUN_CROUCH_AIM] = ACT_WALK_CROUCH_AIM,
    [ACT_RUN_PROTECTED]  = ACT_WALK,
}

-- Wrapper per-entity de TranslateActivity. Idempotente; se instala al primer cruce
-- del umbral y queda inerte cuando Caliber_VJ_Limping es false (curación). No toca la
-- tabla AnimationTranslations de VJ (se reconstruye en cada cambio de arma), por eso
-- el wrapper sobrevive a UpdateAnimationTranslations sin re-aplicar nada.
local function InstallVJLimpTranslator(npc)
    if npc.Caliber_VJ_LimpInstalled then return end
    npc.Caliber_VJ_LimpInstalled = true
    -- Cache: ¿el modelo tiene animación de caminar herido? (citizens HL2 sí; soldados
    -- Combine no). El modelo no cambia en vida de la entidad.
    npc.Caliber_VJ_HasHurtWalk = (VJ and VJ.AnimExists and VJ.AnimExists(npc, ACT_WALK_HURT)) or false
    local orig = npc.TranslateActivity  -- método de clase (ENT), capturado vía __index
    npc.TranslateActivity = function(self, act)
        if self.Caliber_VJ_Limping then
            local out = orig(self, VJ_RUN_TO_WALK[act] or act)
            -- Solo si VJ devolvió el walk pelado (sin variante de arma/aim) usamos la
            -- animación de herido del modelo: cojera visible estilo HL2.
            if out == ACT_WALK and self.Caliber_VJ_HasHurtWalk then
                return ACT_WALK_HURT
            end
            return out
        end
        return orig(self, act)
    end
end

-- Apply head stun with dual-path:
--  · VJ NPCs: se fuerza el flinch NATIVO de VJ marcando el dmginfo con
--    VJ.DMG_FORCE_FLINCH (llamada a método del userdata, no inyección de campo —
--    respeta el contrato de CLAUDE.md). VJ lo consume en su OnTakeDamage →
--    ENT:Flinch() y reproduce la animación correcta para el modelo
--    (FlinchHitGroupMap / AnimTbl_Flinch) con lockAnim: bloquea schedule, ataques
--    y movimiento durante la animación. La duración la manda la animación, no las
--    convars caliber_limb_head_stun_* (esas quedan solo para NPCs nativos).
--    El camino previo (IsGuard + StopMoving + VJ_ACT_PLAYACTIVITY(ACT_*_FLINCH))
--    no interrumpía el schedule en curso (IsGuard solo afecta la PRÓXIMA selección
--    de schedule) y fallaba mudo si el modelo no tenía esa activity.
--  · Native NPCs: check model activity support first to avoid T-pose on
--    unsupported models.
-- isSevere=true → 25% threshold (big flinch), false → 50% threshold (small flinch).
-- Native: shared timer key so 25% stun always cancels any active 50% stun.
local function ApplyHeadStun(npc, isSevere, dmginfo)
    if not IsValid(npc) then return end
    local stunKey = "caliber_limb_stun_" .. npc:EntIndex()
    timer.Remove(stunKey)

    local dur = isSevere and STN25_DUR:GetFloat() or STN50_DUR:GetFloat()

    if npc.IsVJBaseSNPC then
        -- Solo forzable dentro del pipeline de daño (spawn/heal no traen dmginfo)
        if not dmginfo then return end
        -- Habilitar flinch si el autor del NPC lo dejó apagado (default: false).
        -- FlinchChance enorme: el roll aleatorio (math.random(1, N)) queda inerte;
        -- DMG_FORCE_FLINCH lo bypassa, así que solo dispara el flinch de CALIBER.
        if not npc.CanFlinch then
            npc.CanFlinch    = true
            npc.FlinchChance = 1e9
        end
        -- Flinch() chequea cooldown y lock ANTES del bypass de FORCE_FLINCH
        -- (vj_base/ai/core.lua L2598): limpiar el cooldown para que el stun por
        -- umbral nunca se trague.
        npc.NextFlinchT = 0
        if isSevere then
            -- 25% pisa a un flinch/lock activo (paridad con el diseño previo)
            npc.Flinching    = false
            npc.AnimLockTime = 0
        end
        -- No pisar un DamageCustom ajeno (p. ej. DMG_BLEED de armas VJ)
        if VJ and VJ.DMG_FORCE_FLINCH and dmginfo:GetDamageCustom() == 0 then
            dmginfo:SetDamageCustom(VJ.DMG_FORCE_FLINCH)
            dprint(2, "event", npc:GetClass(), "stun_vj_flinch " .. (isSevere and "25" or "50"))
        else
            dprint(2, "event", npc:GetClass(), "stun_vj_skip (DamageCustom ocupado o VJ ausente)")
        end
        return
    end

    -- Native path: verify model supports a flinch activity before scheduling to avoid T-pose
    local activities = isSevere
        and {ACT_BIG_FLINCH, ACT_FLINCH_HEAD, ACT_SMALL_FLINCH, ACT_FLINCH_PHYSICS}
        or  {ACT_SMALL_FLINCH, ACT_FLINCH_HEAD, ACT_BIG_FLINCH, ACT_FLINCH_PHYSICS}

    local hasFlinch = false
    for _, act in ipairs(activities) do
        if npc:SelectWeightedSequence(act) >= 0 then
            hasFlinch = true
            break
        end
    end

    if hasFlinch then
        local sched = isSevere and SCHED_BIG_FLINCH or SCHED_SMALL_FLINCH
        npc:SetSchedule(sched)
        local repeats = math.ceil(dur / 0.3)
        timer.Create(stunKey, 0.3, repeats, function()
            if not IsValid(npc) then return end
            npc:SetSchedule(sched)
        end)
        dprint(2, "event", npc:GetClass(), "stun_native " .. (isSevere and "25" or "50") .. " dur=" .. dur)
    else
        -- Model has no flinch animation: briefly clear enemy to disrupt targeting
        pcall(function()
            npc:SetEnemy(NULL)
            npc:ClearEnemyMemory()
        end)
        dprint(2, "event", npc:GetClass(), "stun_noflinch " .. (isSevere and "25" or "50"))
    end
end

-- Central debuff application. Called after every pool change.
-- reason: "spawn" | "damage" | "heal"
-- dmginfo: solo presente con reason="damage" (desde ProcessLimbHit); habilita el
-- stun VJ por flinch forzado. Los paths spawn/heal no stunean (correcto: sin daño).
local function ApplyLimbDebuffs(npc, reason, dmginfo)
    if not IsValid(npc) then return end
    if not npc.Caliber_HP_HeadMax then return end  -- not initialized

    local r_head = safeRatio(npc.Caliber_HP_Head, npc.Caliber_HP_HeadMax)
    local r_armL = safeRatio(npc.Caliber_HP_ArmL, npc.Caliber_HP_ArmLMax)
    local r_armR = safeRatio(npc.Caliber_HP_ArmR, npc.Caliber_HP_ArmRMax)
    local r_legL = safeRatio(npc.Caliber_HP_LegL, npc.Caliber_HP_LegLMax)
    local r_legR = safeRatio(npc.Caliber_HP_LegR, npc.Caliber_HP_LegRMax)

    -- Accuracy penalty: Lerp(ratio, maxPenalty, 0) → 0 HP gives max penalty, full HP gives 0
    local maxPenArm  = ACC_ARM:GetFloat()
    local maxPenHead = ACC_HEAD:GetFloat()
    local totalPen   = Lerp(r_armL, maxPenArm, 0) + Lerp(r_armR, maxPenArm, 0)
                     + Lerp(r_head, maxPenHead, 0)
    npc.Weapon_Accuracy = (npc.Caliber_WeaponAccuracyBase or 1) * (1 + totalPen)

    -- Speed multiplier: Lerp(ratio, minSpd, 1.0) → 0 HP gives minSpd, full HP gives 1.0.
    -- Both legs multiplied (0.5 * 0.5 = 0.25 when both destroyed).
    -- VJ humano: cojera por traducción de activities (InstallVJLimpTranslator) — el
    -- motor nativo recalcula la velocidad desde el root motion de la animación, así
    -- que m_flGroundSpeed/SetLocalVelocity no le hacen efecto estable.
    -- Nativos: mecanismo 1 m_flGroundSpeed + mecanismo 2 Think con SetLocalVelocity.
    local minSpd   = SPD_LEG:GetFloat()
    local multLegL = Lerp(r_legL, minSpd, 1.0)
    local multLegR = Lerp(r_legR, minSpd, 1.0)
    local finalSpd = multLegL * multLegR
    npc.Caliber_LegSpeedMult = finalSpd
    if npc.IsVJBaseSNPC_Human then
        local limping = finalSpd < VJ_LIMP_T:GetFloat()
        if limping and not npc.Caliber_VJ_LimpInstalled then InstallVJLimpTranslator(npc) end
        if (npc.Caliber_VJ_Limping == true) ~= limping then
            npc.Caliber_VJ_Limping = limping
            -- Nudge: cortar el movimiento en curso para que la locomoción se
            -- re-traduzca ya; si no, mantiene la animación actual (y su velocidad)
            -- hasta el próximo cambio de schedule.
            pcall(function() npc:StopMoving() end)
            dprint(2, "event", npc:GetClass(), limping and "vj_limp_on" or "vj_limp_off",
                "spd=" .. string.format("%.2f", finalSpd))
        end
    else
        pcall(function() npc:SetSaveValue("m_flGroundSpeed", npc.Caliber_GroundSpeedBase * finalSpd) end)
    end

    dprint(2, "debuff", npc:GetClass(),
        "acc_penalty=" .. string.format("%.2f", totalPen),
        "speed_mult="  .. string.format("%.2f", finalSpd))

    -- One-shot: arm L drop at 0 HP
    local hasWeapon = IsValid(npc:GetActiveWeapon()) and npc:GetActiveWeapon():GetClass() ~= "weapon_nothingfornpc"
    if r_armL == 0 and not npc.Caliber_ArmL_Dropped then
        npc.Caliber_ArmL_Dropped = true
        local pos = GetBonePos(npc, "ValveBiped.Bip01_L_Hand")
                 or GetBonePos(npc, "ValveBiped.Bip01_L_Forearm")
                 or npc:GetPos()
        TryDropWeapon(npc, pos)
        dprint(2, "event", npc:GetClass(), "drop_weapon_L")
    end
    if r_armL > 0 or hasWeapon then npc.Caliber_ArmL_Dropped = false end

    -- One-shot: arm R drop at 0 HP
    if r_armR == 0 and not npc.Caliber_ArmR_Dropped then
        npc.Caliber_ArmR_Dropped = true
        local pos = GetBonePos(npc, "ValveBiped.Bip01_R_Hand")
                 or GetBonePos(npc, "ValveBiped.Bip01_R_Forearm")
                 or npc:GetPos()
        TryDropWeapon(npc, pos)
        dprint(2, "event", npc:GetClass(), "drop_weapon_R")
    end
    if r_armR > 0 or hasWeapon then npc.Caliber_ArmR_Dropped = false end

    -- One-shot: head stun 25% (checked FIRST so it cancels/overrides the 50% stun)
    if r_head < 0.25 and not npc.Caliber_HeadStun25_Fired then
        npc.Caliber_HeadStun25_Fired = true
        npc.Caliber_HeadStun50_Fired = true  -- prevent separate 50% fire
        ApplyHeadStun(npc, true, dmginfo)
    end
    if r_head >= 0.25 then npc.Caliber_HeadStun25_Fired = false end

    -- One-shot: head stun 50%
    if r_head < 0.5 and not npc.Caliber_HeadStun50_Fired then
        npc.Caliber_HeadStun50_Fired = true
        ApplyHeadStun(npc, false, dmginfo)
    end
    if r_head >= 0.5 then npc.Caliber_HeadStun50_Fired = false end

    hook.Run("Caliber_LimbsUpdated", npc, reason or "damage")
end

-- Expose publicly for HealLimbs and external callers
CALIBER.ApplyLimbDebuffs = ApplyLimbDebuffs

-- Initialize limb pools on spawn
local function InitLimbs(npc)
    if not EN_LIMBS:GetBool() then return end
    if not IsValid(npc) or not npc:IsNPC() then return end
    local hp = npc:Health()
    if hp <= 0 then return end
    npc.Caliber_SpawnHP = hp  -- guardado para reconstruir fracs en toolgun M2 y ResizeLimbPools

    -- Key de spawnmenu (si tiene config) > classname (ver CALIBER.GetOverrideForEnt)
    local override = CALIBER.GetOverrideForEnt and CALIBER.GetOverrideForEnt(npc)
    local hf = (override and tonumber(override.head_hp_frac)) or HEAD_FRAC:GetFloat()
    local af = (override and tonumber(override.arms_hp_frac)) or ARMS_FRAC:GetFloat()
    local lf = (override and tonumber(override.legs_hp_frac)) or LEGS_FRAC:GetFloat()

    local headMax = hp * hf
    local armMax  = hp * af
    local legMax  = hp * lf

    npc.Caliber_HP_Head = headMax; npc.Caliber_HP_HeadMax = headMax
    npc.Caliber_HP_ArmL = armMax;  npc.Caliber_HP_ArmLMax = armMax
    npc.Caliber_HP_ArmR = armMax;  npc.Caliber_HP_ArmRMax = armMax
    npc.Caliber_HP_LegL = legMax;  npc.Caliber_HP_LegLMax = legMax
    npc.Caliber_HP_LegR = legMax;  npc.Caliber_HP_LegRMax = legMax

    -- Base accuracy; read once at spawn, never updated (prevents drift)
    npc.Caliber_WeaponAccuracyBase = npc.Weapon_Accuracy or 1

    -- Base ground speed for leg slowdown mechanism 1 (m_flGroundSpeed).
    -- pcall: un addon externo (Lua Patcher) detourea GetSaveValue y su wrapper
    -- puede fallar en algunas entidades; atrapamos aquí para no gatillar su log.
    -- El SetSaveValue equivalente (ApplyLimbDebuffs) ya está protegido igual.
    local okGSV, baseSpd = pcall(function() return npc:GetSaveValue("m_flGroundSpeed") end)
    npc.Caliber_GroundSpeedBase = (okGSV and baseSpd and baseSpd > 0) and baseSpd or 1
    npc.Caliber_LegSpeedMult    = 1.0

    -- Track HP for universal heal polling
    npc.Caliber_LastKnownHP = hp

    -- One-shot event flags
    npc.Caliber_ArmL_Dropped     = false
    npc.Caliber_ArmR_Dropped     = false
    npc.Caliber_HeadStun50_Fired = false
    npc.Caliber_HeadStun25_Fired = false

    dprint(2, "init", npc:GetClass(),
        "max_head=" .. string.format("%.1f", headMax),
        "max_arms=" .. string.format("%.1f", armMax),
        "max_legs=" .. string.format("%.1f", legMax))

    ApplyLimbDebuffs(npc, "spawn")
end

-- Called from corpus_caliber_core.lua ScaleNPCDamage hook (Option B: deterministic ordering)
-- Redimensiona pools de limbs en un NPC vivo. Usado por el toolgun debug (M1 con Apply Limbs).
-- current = newMax (cura completa al redimensionar). Usa Caliber_SpawnHP para fracs fieles;
-- fallback a Health() si no está disponible.
function CALIBER.ResizeLimbPools(npc, hf, af, lf)
    if not IsValid(npc) or not npc.Caliber_HP_HeadMax then return end
    hf = math.max(hf or 0.5, 0.01)
    af = math.max(af or 0.5, 0.01)
    lf = math.max(lf or 0.5, 0.01)
    local hp = npc.Caliber_SpawnHP or npc:Health()
    if hp <= 0 then return end
    npc.Caliber_HP_HeadMax = hp * hf; npc.Caliber_HP_Head = npc.Caliber_HP_HeadMax
    npc.Caliber_HP_ArmLMax = hp * af; npc.Caliber_HP_ArmL = npc.Caliber_HP_ArmLMax
    npc.Caliber_HP_ArmRMax = hp * af; npc.Caliber_HP_ArmR = npc.Caliber_HP_ArmRMax
    npc.Caliber_HP_LegLMax = hp * lf; npc.Caliber_HP_LegL = npc.Caliber_HP_LegLMax
    npc.Caliber_HP_LegRMax = hp * lf; npc.Caliber_HP_LegR = npc.Caliber_HP_LegRMax
    dprint(2, "ResizeLimbPools", npc:GetClass(),
        "head=" .. string.format("%.1f", npc.Caliber_HP_HeadMax),
        "arms=" .. string.format("%.1f", npc.Caliber_HP_ArmLMax),
        "legs=" .. string.format("%.1f", npc.Caliber_HP_LegLMax))
end

function CALIBER.ProcessLimbHit(npc, hitgroup, dmginfo)
    if not EN_LIMBS:GetBool() then return end
    if not IsValid(npc) or not npc:IsNPC() then return end
    if not npc.Caliber_HP_HeadMax then return end

    local dmg = dmginfo:GetDamage()
    if dmg <= 0 then return end

    local override = CALIBER.GetOverrideForEnt and CALIBER.GetOverrideForEnt(npc)

    local zone, before, after, poolMax, xfer
    if hitgroup == HITGROUP_HEAD then
        xfer = (override and tonumber(override.limb_damage_transfer_head)) or DMG_XFER_HEAD:GetFloat()
        zone = "head";  before = npc.Caliber_HP_Head
        npc.Caliber_HP_Head = math.max(0, npc.Caliber_HP_Head - dmg * xfer)
        after = npc.Caliber_HP_Head;  poolMax = npc.Caliber_HP_HeadMax
    elseif hitgroup == HITGROUP_LEFTARM then
        xfer = (override and tonumber(override.limb_damage_transfer_arms)) or DMG_XFER_ARMS:GetFloat()
        zone = "arm_l"; before = npc.Caliber_HP_ArmL
        npc.Caliber_HP_ArmL = math.max(0, npc.Caliber_HP_ArmL - dmg * xfer)
        after = npc.Caliber_HP_ArmL;  poolMax = npc.Caliber_HP_ArmLMax
    elseif hitgroup == HITGROUP_RIGHTARM then
        xfer = (override and tonumber(override.limb_damage_transfer_arms)) or DMG_XFER_ARMS:GetFloat()
        zone = "arm_r"; before = npc.Caliber_HP_ArmR
        npc.Caliber_HP_ArmR = math.max(0, npc.Caliber_HP_ArmR - dmg * xfer)
        after = npc.Caliber_HP_ArmR;  poolMax = npc.Caliber_HP_ArmRMax
    elseif hitgroup == HITGROUP_LEFTLEG then
        xfer = (override and tonumber(override.limb_damage_transfer_legs)) or DMG_XFER_LEGS:GetFloat()
        zone = "leg_l"; before = npc.Caliber_HP_LegL
        npc.Caliber_HP_LegL = math.max(0, npc.Caliber_HP_LegL - dmg * xfer)
        after = npc.Caliber_HP_LegL;  poolMax = npc.Caliber_HP_LegLMax
    elseif hitgroup == HITGROUP_RIGHTLEG then
        xfer = (override and tonumber(override.limb_damage_transfer_legs)) or DMG_XFER_LEGS:GetFloat()
        zone = "leg_r"; before = npc.Caliber_HP_LegR
        npc.Caliber_HP_LegR = math.max(0, npc.Caliber_HP_LegR - dmg * xfer)
        after = npc.Caliber_HP_LegR;  poolMax = npc.Caliber_HP_LegRMax
    else
        return  -- no pool for chest/stomach/generic/etc
    end

    -- One-shot stash for the caliber_core trace (consumed and cleared by ScaleNPCDamage)
    npc.Caliber_LastLimbHit = {
        zone    = zone,
        dmgPool = dmg * xfer,
        before  = before,
        after   = after,
        poolMax = poolMax,
    }

    -- Sync Caliber_LastKnownHP on next tick so heal polling doesn't misread damage as a heal
    timer.Simple(0, function()
        if IsValid(npc) then npc.Caliber_LastKnownHP = npc:Health() end
    end)

    ApplyLimbDebuffs(npc, "damage", dmginfo)
end

-- Public healing API for external integration (medic mods, etc.)
-- target: nil (proportional), "head", "arms", "legs", "all_limbs"
function CALIBER.HealLimbs(npc, amount, target)
    if not IsValid(npc) or not npc.Caliber_HP_HeadMax then return end
    local function healPool(cur, max, amt) return math.min(cur + amt, max) end

    if target == nil then
        local totalMax = npc.Caliber_HP_HeadMax + npc.Caliber_HP_ArmLMax + npc.Caliber_HP_ArmRMax
                       + npc.Caliber_HP_LegLMax + npc.Caliber_HP_LegRMax
        if totalMax <= 0 then return end
        npc.Caliber_HP_Head = healPool(npc.Caliber_HP_Head, npc.Caliber_HP_HeadMax, amount * npc.Caliber_HP_HeadMax / totalMax)
        npc.Caliber_HP_ArmL = healPool(npc.Caliber_HP_ArmL, npc.Caliber_HP_ArmLMax, amount * npc.Caliber_HP_ArmLMax / totalMax)
        npc.Caliber_HP_ArmR = healPool(npc.Caliber_HP_ArmR, npc.Caliber_HP_ArmRMax, amount * npc.Caliber_HP_ArmRMax / totalMax)
        npc.Caliber_HP_LegL = healPool(npc.Caliber_HP_LegL, npc.Caliber_HP_LegLMax, amount * npc.Caliber_HP_LegLMax / totalMax)
        npc.Caliber_HP_LegR = healPool(npc.Caliber_HP_LegR, npc.Caliber_HP_LegRMax, amount * npc.Caliber_HP_LegRMax / totalMax)
    elseif target == "head" then
        npc.Caliber_HP_Head = healPool(npc.Caliber_HP_Head, npc.Caliber_HP_HeadMax, amount)
    elseif target == "arms" then
        npc.Caliber_HP_ArmL = healPool(npc.Caliber_HP_ArmL, npc.Caliber_HP_ArmLMax, amount / 2)
        npc.Caliber_HP_ArmR = healPool(npc.Caliber_HP_ArmR, npc.Caliber_HP_ArmRMax, amount / 2)
    elseif target == "legs" then
        npc.Caliber_HP_LegL = healPool(npc.Caliber_HP_LegL, npc.Caliber_HP_LegLMax, amount / 2)
        npc.Caliber_HP_LegR = healPool(npc.Caliber_HP_LegR, npc.Caliber_HP_LegRMax, amount / 2)
    elseif target == "all_limbs" then
        local each = amount / 5
        npc.Caliber_HP_Head = healPool(npc.Caliber_HP_Head, npc.Caliber_HP_HeadMax, each)
        npc.Caliber_HP_ArmL = healPool(npc.Caliber_HP_ArmL, npc.Caliber_HP_ArmLMax, each)
        npc.Caliber_HP_ArmR = healPool(npc.Caliber_HP_ArmR, npc.Caliber_HP_ArmRMax, each)
        npc.Caliber_HP_LegL = healPool(npc.Caliber_HP_LegL, npc.Caliber_HP_LegLMax, each)
        npc.Caliber_HP_LegR = healPool(npc.Caliber_HP_LegR, npc.Caliber_HP_LegRMax, each)
    end
    ApplyLimbDebuffs(npc, "heal")
end

-- Spawn hook: slight delay after core's 0.2s to ensure HP is fully set
hook.Add("OnEntityCreated", "Caliber_Limbs_Spawn", function(e)
    timer.Simple(0.3, function()
        if not IsValid(e) or e:IsPlayer() or not e:IsNPC() then return end
        if not EN_LIMBS:GetBool() then return end
        InitLimbs(e)
    end)
end)

-- Cleanup: remove stun timer when entity is removed
hook.Add("EntityRemoved", "Caliber_Limbs_Cleanup", function(e)
    timer.Remove("caliber_limb_stun_" .. e:EntIndex())
end)

-- Fix 1: Recurring leg slowdown via SetLocalVelocity (20 Hz, only NPCs with reduced speed).
-- VJ humanos excluidos: su cojera va por traducción de activities (root motion);
-- pelear acá con el motor nativo solo produce jitter.
local legThinkNext = 0
hook.Add("Think", "Caliber_Limbs_LegSpeed", function()
    if not EN_LIMBS:GetBool() then return end
    local now = CurTime()
    if now < legThinkNext then return end
    legThinkNext = now + 0.05

    for _, npc in ipairs(ents.GetAll()) do
        if IsValid(npc) and npc:IsNPC() and not npc.IsVJBaseSNPC_Human
           and npc.Caliber_LegSpeedMult and npc.Caliber_LegSpeedMult < 1.0 then
            local v = npc:GetVelocity()
            if v:LengthSqr() > 1 then
                pcall(function() npc:SetLocalVelocity(v * npc.Caliber_LegSpeedMult) end)
            end
        end
    end
end)

-- Fix 2: Universal heal polling — detects HP increases and propagates proportionally to pools.
-- Also initializes pools on-the-fly for NPCs that spawned before caliber_limbs_enabled was turned on.
timer.Create("Caliber_Limbs_HealPoll", 0.5, 0, function()
    if not EN_LIMBS:GetBool() then return end

    for _, npc in ipairs(ents.GetAll()) do
        if not IsValid(npc) or not npc:IsNPC() or npc:Health() <= 0 then continue end

        -- Auto-repair: NPC without pools initialized → init now
        if not npc.Caliber_HP_HeadMax then
            InitLimbs(npc)
            continue
        end

        local currentHP = npc:Health()
        if not npc.Caliber_LastKnownHP then
            npc.Caliber_LastKnownHP = currentHP
            continue
        end

        local delta = currentHP - npc.Caliber_LastKnownHP
        if delta > 0 then
            local maxHP = npc:GetMaxHealth()
            if maxHP > 0 then
                local healRatio = delta / maxHP
                npc.Caliber_HP_Head = math.min(npc.Caliber_HP_Head + npc.Caliber_HP_HeadMax * healRatio, npc.Caliber_HP_HeadMax)
                npc.Caliber_HP_ArmL = math.min(npc.Caliber_HP_ArmL + npc.Caliber_HP_ArmLMax * healRatio, npc.Caliber_HP_ArmLMax)
                npc.Caliber_HP_ArmR = math.min(npc.Caliber_HP_ArmR + npc.Caliber_HP_ArmRMax * healRatio, npc.Caliber_HP_ArmRMax)
                npc.Caliber_HP_LegL = math.min(npc.Caliber_HP_LegL + npc.Caliber_HP_LegLMax * healRatio, npc.Caliber_HP_LegLMax)
                npc.Caliber_HP_LegR = math.min(npc.Caliber_HP_LegR + npc.Caliber_HP_LegRMax * healRatio, npc.Caliber_HP_LegRMax)
                ApplyLimbDebuffs(npc, "heal")
                dprint(2, "heal_poll", npc:GetClass(), "delta=" .. delta, "ratio=" .. string.format("%.2f", healRatio))
            end
        end

        npc.Caliber_LastKnownHP = currentHP
    end
end)

-- Fix 3: Reset arm drop flags when NPC equips a new weapon (covers Give, scavenger, any source)
hook.Add("WeaponEquip", "Caliber_Limbs_ResetDropFlags", function(weapon, owner)
    if not IsValid(owner) or not owner:IsNPC() then return end
    if not owner.Caliber_HP_HeadMax then return end  -- pools not initialized, nothing to reset
    owner.Caliber_ArmL_Dropped = false
    owner.Caliber_ArmR_Dropped = false
    dprint(2, "equip_reset", owner:GetClass(), weapon:GetClass())
end)

-- Nota VJ: el stun de cabeza en NPCs VJ va por el flinch nativo de VJ
-- (DMG_FORCE_FLINCH en ApplyHeadStun); Flinch() ya hace StopAttacks + lockAnim,
-- no hace falta scaffolding externo (IsGuard/StopMoving eran ineficaces).
