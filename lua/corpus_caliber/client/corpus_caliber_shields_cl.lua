-- corpus_caliber_shields_cl.lua — FX de escudos de energía (client)
-- Migrado desde ADS 2.0 (cl_ads_shields.lua).
--
-- Capa 3 del diseño (docs/Caliber_EnergyShields_Arquitectura.md): render de la
-- burbuja + partículas + reacción a eventos. El cliente NO simula nada:
--   - Estado persistente vía NWVars (Caliber_Shield_State/Type/Color) — on-change,
--     sobrevive late-joiners.
--   - Efectos transitorios vía net "corpus_caliber_shield_fx" (one-shots con filtro PVS):
--     1=hit_flash, 2=collapse, 3=restore.
-- Caliber_ShieldFX.Types es el ESPEJO visual de CALIBER.ShieldTypes (corpus_caliber_shields.lua,
-- server): MISMAS KEYS. Agregar un escudo = una entrada en cada tabla.
--
-- Técnica de burbuja rescatada de "Halo Energy Shield" (Speedy Von Gofast):
-- copia clientside del modelo bonemergeada al NPC, material aditivo con
-- TextureScroll, alpha que decae desde el último evento. El HEV usa efectos
-- built-in del engine ("Goofy Armor Effect" de sora1d). Créditos en README.
if SERVER then return end

local BUBBLE_EN = CreateClientConVar("caliber_shield_fx_bubble", "1", true, false,
    "Burbuja de energia sobre NPCs con escudo", 0, 1)
local PART_EN = CreateClientConVar("caliber_shield_fx_particles", "1", true, false,
    "Particulas de impacto/colapso/recarga del escudo", 0, 1)

-- Registro de tipos FX: file-local (no global suelto — contrato de namespace §3).
local Caliber_ShieldFX = {}
Caliber_ShieldFX.Types = {
    spartan = {
        label    = "Spartan",
        bubble   = true,
        mat      = "models/shield/energy_shield_elite",  -- variante con $alpha+phong (la spartan trae typo $alha)
        color    = Color(218, 185, 40),
        impact   = "spdy_halo_3_spartan_shield_impact_effect",
        deplete  = "spdy_halo_3_spartan_shield_deplete",
        arcs     = "spdy_halo_3_spartan_shield_deplete_arcs",
        recharge = "spdy_halo_3_spartan_shield_recharge",
        -- set colorable spdy_halo_3_custom_*: se intenta cuando el NPC trae
        -- shield_color custom (tintado por control point, ver ApplyShieldColorCP);
        -- fallback automático al set horneado del tipo si no se puede crear
        customImpact   = "spdy_halo_3_custom_shield_impact_effect",
        customDeplete  = "spdy_halo_3_custom_shield_deplete",
        customArcs     = "spdy_halo_3_custom_shield_deplete_arcs",
        customRecharge = "spdy_halo_3_custom_shield_recharge",
    },
    elite = {
        label    = "Elite Sangheili",
        bubble   = true,
        mat      = "models/shield/energy_shield_elite",
        color    = Color(51, 105, 219),
        impact   = "spdy_halo_3_elite_shield_impact_effect",
        deplete  = "spdy_halo_3_elite_shield_deplete",
        arcs     = "spdy_halo_3_elite_shield_deplete_arcs",
        recharge = "spdy_halo_3_elite_shield_recharge",
        customImpact   = "spdy_halo_3_custom_shield_impact_effect",
        customDeplete  = "spdy_halo_3_custom_shield_deplete",
        customArcs     = "spdy_halo_3_custom_shield_deplete_arcs",
        customRecharge = "spdy_halo_3_custom_shield_recharge",
    },
    hev = {
        -- HEV Charge Shield: sin burbuja ni pcf — todo built-in (Goofy Armor)
        label   = "HEV",
        bubble  = false,
        builtin = true,
        color   = Color(255, 160, 40),
    },
}

local STATE_UP, STATE_DOWN, STATE_CHARGING = 1, 2, 3

-- Estado FX per-NPC, creado LAZY al primer evento recibido (un NPC con escudo
-- que nadie golpeó no gasta nada acá). [npc] = { bubble, lastHit, broke, swell,
-- arcsOn, arcsName, rechargeAt }
local ActiveFX = {}

local function TypeDef(npc)
    local t = npc:GetNWString("Caliber_Shield_Type", "")
    return Caliber_ShieldFX.Types[t]
end

-- Color resuelto: NWVector del server (override o default del tipo); vector
-- cero = NWVar aún no llegada (late-join pre-init) → color del tipo
local function ShieldColor(npc, def)
    local v = npc:GetNWVector("Caliber_Shield_Color", vector_origin)
    if v:IsZero() then return def.color end
    return Color(v.x, v.y, v.z)
end

-- ¿El NPC usa un color custom (distinto al default del tipo)? Decide si vale
-- intentar el set de partículas colorable (B3)
local function HasCustomColor(npc, def)
    local c = ShieldColor(npc, def)
    local d = def.color
    return math.abs(c.r - d.r) + math.abs(c.g - d.g) + math.abs(c.b - d.b) > 12
end

local function GetFX(npc)
    local fx = ActiveFX[npc]
    if not fx then
        fx = { lastHit = 0, swell = 0, arcsOn = false, rechargeAt = 0 }
        ActiveFX[npc] = fx
    end
    return fx
end

local function RemoveFX(npc, fx)
    if IsValid(fx.bubble) then fx.bubble:Remove() end
    if IsValid(npc) and fx.arcsOn and fx.arcsName then
        npc:StopParticlesNamed(fx.arcsName)
    end
    ActiveFX[npc] = nil
end

-- Los sistemas colorables spdy_halo_3_custom_* leen el color de sus partículas
-- desde un CONTROL POINT (operador "Remap Control Point to Vector" → campo 6 =
-- Color), presente en los 14 emisores. Verificado parseando el árbol DMX del pcf
-- (2026-07-08): CP de entrada = 4, rango 0..1. El color viaja como POSICIÓN del
-- control point, normalizado. Los hijos heredan los CP del padre en Source, así
-- que basta setearlo en el handle que devuelve CreateParticleSystem.
local SHIELD_COLOR_CP = 4
local function ApplyShieldColorCP(ps, col)
    ps:SetControlPoint(SHIELD_COLOR_CP, Vector(col.r / 255, col.g / 255, col.b / 255))
end

-- Partícula colorable en posición de mundo, tintada vía control point. El primer
-- intento con CreateParticleSystem+CUSTOMORIGIN caía al fallback, por eso se usa
-- CreateParticleSystemNoEntity (camino limpio para posición de mundo) primero.
-- Devuelve false si el sistema no se pudo crear → el caller cae al set horneado
-- del tipo (la burbuja tintada por SetColor es la garantía mínima).
local function TintedParticle(npc, name, pos, col)
    if not name then return false end
    local ps
    if CreateParticleSystemNoEntity then
        ps = CreateParticleSystemNoEntity(name, pos)
    end
    if (not ps or not ps:IsValid()) and IsValid(npc) then
        ps = CreateParticleSystem(npc, name, PATTACH_CUSTOMORIGIN)
    end
    if not ps or not ps:IsValid() then
        -- aviso una sola vez por sesión: dice qué camino falta para diagnosticar
        if not Caliber_ShieldFX._tintWarned then
            Caliber_ShieldFX._tintWarned = true
            Corpus.Log("caliber", string.format(
                "[Caliber Shields] sistema colorable '%s' no se pudo crear (NoEntity=%s) — fallback al set del tipo",
                name, tostring(CreateParticleSystemNoEntity ~= nil)))
        end
        return false
    end
    ps:SetControlPoint(0, pos)
    ApplyShieldColorCP(ps, col)
    return true
end

-- ── Eventos transitorios (net PVS) ───────────────────────────────────────────

net.Receive("corpus_caliber_shield_fx", function()
    local ev = net.ReadUInt(2)
    local npc = net.ReadEntity()
    local pos = (ev == 1) and net.ReadVector() or nil
    if not IsValid(npc) then return end
    local def = TypeDef(npc)
    if not def then return end
    local fx = GetFX(npc)

    if ev == 1 then  -- hit flash
        fx.lastHit = CurTime()
        if PART_EN:GetBool() and pos then
            if def.builtin then
                -- hev: anillo orientado hacia afuera del cuerpo (Goofy Armor).
                -- Normal APLANADA (z=0): con la componente vertical, un hit al
                -- pecho alto ladeaba el anillo ~45° respecto al disparo
                local nrm = pos - npc:WorldSpaceCenter()
                nrm.z = 0
                if nrm:IsZero() then nrm = Vector(1, 0, 0) end
                nrm:Normalize()
                local ed = EffectData()
                ed:SetOrigin(pos)
                ed:SetNormal(nrm)
                util.Effect("selection_ring", ed)
            else
                local col = ShieldColor(npc, def)
                if not (HasCustomColor(npc, def) and TintedParticle(npc, def.customImpact, pos, col)) then
                    ParticleEffect(def.impact, pos, angle_zero)
                end
            end
        end
    elseif ev == 2 then  -- colapso
        fx.lastHit = CurTime()
        fx.broke = CurTime()
        fx.swell = 0
        if PART_EN:GetBool() then
            if def.builtin then
                -- hev: descarga eléctrica sobre los hitboxes (Goofy Armor),
                -- reducida un 25% respecto al original (pedido del autor)
                local ed = EffectData()
                ed:SetOrigin(npc:WorldSpaceCenter())
                ed:SetScale(0.75)
                ed:SetMagnitude(0.75)
                ed:SetRadius(750)
                ed:SetEntity(npc)
                for _ = 0, 20 do util.Effect("TeslaHitBoxes", ed) end
            else
                local p = npc:GetPos()
                p.z = p.z + npc:OBBMaxs().z / 2
                local col = ShieldColor(npc, def)
                if not (HasCustomColor(npc, def) and TintedParticle(npc, def.customDeplete, p, col)) then
                    ParticleEffect(def.deplete, p, angle_zero)
                end
            end
        end
    elseif ev == 3 then  -- restaurado a full: pop breve de burbuja
        fx.lastHit = CurTime()
        fx.broke = nil
        fx.swell = 0
    end
end)

-- ── Burbuja ──────────────────────────────────────────────────────────────────

local function EnsureBubble(npc, fx, def)
    if not def.bubble or not BUBBLE_EN:GetBool() then
        if IsValid(fx.bubble) then fx.bubble:Remove() fx.bubble = nil end
        return nil
    end
    if not IsValid(fx.bubble) then
        local b = ClientsideModel(npc:GetModel(), RENDERGROUP_TRANSLUCENT)
        if not IsValid(b) then return nil end
        b:SetPos(npc:GetPos())
        b:SetParent(npc)
        b:AddEffects(EF_BONEMERGE)
        b:SetMaterial(def.mat)
        b:SetRenderMode(RENDERMODE_GLOW)
        b:SetNoDraw(true)
        -- sincronizar bodygroups con el NPC (patrón del mod original)
        for i = 0, npc:GetNumBodyGroups() - 1 do
            b:SetBodygroup(i, npc:GetBodygroup(i))
        end
        fx.bubble = b
    end
    -- el NPC puede cambiar de modelo en runtime (patrón del original)
    if fx.bubble:GetModel() ~= npc:GetModel() then
        fx.bubble:SetModel(npc:GetModel())
    end
    return fx.bubble
end

-- ── Think cliente único ──────────────────────────────────────────────────────
-- Anima el alpha de la burbuja y mantiene las partículas de estado (arcs en
-- DOWN, loop de recarga en CHARGING). Early-out si no hay FX activos.

hook.Add("Think", "Caliber_ShieldFX_Think", function()
    if not next(ActiveFX) then return end
    local now = CurTime()

    for npc, fx in pairs(ActiveFX) do
        if not IsValid(npc) then
            if IsValid(fx.bubble) then fx.bubble:Remove() end
            ActiveFX[npc] = nil
            continue
        end
        local state = npc:GetNWInt("Caliber_Shield_State", 0)
        local def = TypeDef(npc)
        if state == 0 or not def then
            RemoveFX(npc, fx)
            continue
        end

        -- NPC dormant (fuera de PVS): ocultar la burbuja y no tocar partículas.
        -- Si se dibuja igual, al romperse el parent la copia queda huérfana.
        if npc:IsDormant() then
            if IsValid(fx.bubble) then fx.bubble:SetNoDraw(true) end
            continue
        end

        -- burbuja: alpha decae desde el último evento (flash), con swell al colapsar
        local bubble = EnsureBubble(npc, fx, def)
        if bubble then
            -- Re-afirmar parent/pos/bonemerge CADA frame (patrón del mod original):
            -- con lag o dormancy el parent se rompe y la copia queda en T-pose
            -- lejos del modelo hasta la muerte del NPC
            bubble:SetPos(npc:GetPos())
            bubble:SetParent(npc)
            bubble:AddEffects(EF_BONEMERGE)

            local alpha
            if fx.broke then
                -- estallido: fade corto + inflado creciente (fórmulas del original)
                fx.swell = math.min(fx.swell + RealFrameTime() * 1.5, 0.6)
                alpha = math.Clamp((fx.broke + 0.3 - now) * 250, 0, 255)
            else
                alpha = math.Clamp((fx.lastHit + 0.45 - now) * 255 / 0.45, 0, 255)
            end

            if alpha > 0 then
                bubble:SetNoDraw(false)
                local s = 1.05 + fx.swell
                for i = 0, bubble:GetBoneCount() - 1 do
                    bubble:ManipulateBoneScale(i, Vector(s, s, s))
                end
                local col = ShieldColor(npc, def)
                bubble:SetColor(Color(col.r, col.g, col.b, math.min(alpha, 254)))
            else
                bubble:SetNoDraw(true)
                if fx.broke and now > fx.broke + 0.5 then
                    fx.broke = nil
                    fx.swell = 0
                end
            end
        end

        -- arcos eléctricos persistentes mientras el escudo está caído. Con color
        -- custom se usa el set colorable (tintado por CP); si no, el horneado.
        -- Se recuerda el nombre atacheado (fx.arcsName) para detener el correcto.
        if PART_EN:GetBool() and state == STATE_DOWN and def.arcs then
            if not fx.arcsOn then
                local name = def.arcs
                local ps
                if def.customArcs and HasCustomColor(npc, def) then
                    ps = CreateParticleSystem(npc, def.customArcs, PATTACH_ABSORIGIN_FOLLOW)
                    if ps and ps:IsValid() then
                        ApplyShieldColorCP(ps, ShieldColor(npc, def))
                        name = def.customArcs
                    else
                        ps = nil
                    end
                end
                if not ps then
                    ParticleEffectAttach(def.arcs, PATTACH_ABSORIGIN_FOLLOW, npc, 0)
                end
                fx.arcsName = name
                fx.arcsOn = true
            end
        elseif fx.arcsOn then
            if fx.arcsName then npc:StopParticlesNamed(fx.arcsName) end
            fx.arcsOn = false
        end

        -- loop visual de recarga: re-attach cada 0.7 s (patrón del original).
        -- Con shield_color custom se usa el sistema colorable (tintado por CP,
        -- siguiendo el origen del NPC); si no, el set horneado del tipo.
        if PART_EN:GetBool() and state == STATE_CHARGING and def.recharge and now >= fx.rechargeAt then
            local tinted = false
            if def.customRecharge and HasCustomColor(npc, def) then
                local ps = CreateParticleSystem(npc, def.customRecharge, PATTACH_ABSORIGIN_FOLLOW)
                if ps and ps:IsValid() then
                    ApplyShieldColorCP(ps, ShieldColor(npc, def))
                    tinted = true
                end
            end
            if not tinted then
                ParticleEffectAttach(def.recharge, PATTACH_ABSORIGIN_FOLLOW, npc, 0)
            end
            fx.rechargeAt = now + 0.7
        end
    end
end)

-- En cliente EntityRemoved también dispara al salir del PVS: el estado FX es
-- transitorio, recrearse lazy en el próximo evento es lo esperado.
hook.Add("EntityRemoved", "Caliber_ShieldFX_Cleanup", function(ent)
    local fx = ActiveFX[ent]
    if fx then
        if IsValid(fx.bubble) then fx.bubble:Remove() end
        ActiveFX[ent] = nil
    end
end)
