-- corpus_caliber_init.lua — punto de entrada y manifest de carga de Caliber (SHARED)
-- Migrado desde ADS 2.0. Único archivo en lua/autorun/: registra el módulo y carga
-- el resto vía include() en orden explícito. Ver Caliber_Architecture.md §3 y §4.

-- ============================================================
-- CONTRATO PÚBLICO DE CALIBER (Caliber_Architecture.md §8). Consumido por otros
-- módulos vía Corpus.GetModule("caliber"). Todo lo demás colgado de esa tabla es
-- interno — no se consume desde fuera de este repo por convención, no por barrera
-- técnica.
--
--   CALIBER.HealLimbs(npc, amount, target)   -- pools de limbs; medic mods, etc.
--                                               target: nil|"head"|"arms"|"legs"|"all_limbs"
--   CALIBER.Limbs.*                          -- vacío en Block 2; los eventos de
--                                               daño/limb aterrizan cuando Cortex/
--                                               Coagulant los consuman (§9.a)
-- ============================================================

-- ============================================================
-- Manifest de carga (Caliber_Architecture.md §4): orden explícito y determinista,
-- NO el orden alfabético implícito de autorun que usaba ADS (frágil, ver §4). Los
-- sub-archivos viven en lua/corpus_caliber/<realm>/ (fuera de lua/autorun/) para
-- que ESTE init sea el único punto de carga; si estuvieran en autorun/server|client
-- se auto-ejecutarían y duplicarían la carga rompiendo el orden. El toolgun vive en
-- stools/ (lo carga el sistema de gmod_tool, no este manifest).
--
-- Orden validado contra dependencias reales entre archivos (§4): armor antes que
-- core (core.LoadConfig llama a armor.LoadArmorData en file-scope); el resto solo
-- se cruza en runtime con guardas, así que su orden es el lógico (core → limbs →
-- shields → scavenger). Regla: nunca invocar hacia adelante en file-scope (§5).
-- ============================================================
local SHARED = {
    "shared/corpus_caliber_shared.lua",
}
local SERVER_FILES = {
    "server/corpus_caliber_armor.lua",
    "server/corpus_caliber_core.lua",
    "server/corpus_caliber_limbs.lua",
    "server/corpus_caliber_shields.lua",
    "server/corpus_caliber_scavenger.lua",
}
local CLIENT_FILES = {
    "client/corpus_caliber_shields_cl.lua",
    "client/corpus_caliber_browser.lua",
    "client/corpus_caliber_client_options.lua",
}

local function inc(rel) include("corpus_caliber/" .. rel) end
local function cs(rel)  AddCSLuaFile("corpus_caliber/" .. rel) end

-- AddCSLuaFile no depende de Corpus: se hace siempre en la carga de autorun, para
-- que el cliente reciba los archivos aunque el boot quede diferido (ver abajo).
if SERVER then
    for _, f in ipairs(SHARED)       do cs(f) end
    for _, f in ipairs(CLIENT_FILES) do cs(f) end
end

-- Hard-dep: Caliber depende de Corpus (única dep dura del ecosistema, §2). No se
-- asume que ya cargó; se detecta. La sonda cubre las primitivas que los sub-archivos
-- usan en file-scope (Data/Net/Log en server, UI en client), no solo el registro.
local function CorpusListo()
    return Corpus ~= nil and Corpus.RegisterModule ~= nil and Corpus.Data ~= nil
        and Corpus.Net ~= nil and Corpus.Log ~= nil and (SERVER or Corpus.UI ~= nil)
end

-- Namespace: tabla única registrada (Caliber_Architecture.md §3). Todos los
-- archivos del módulo cachean esta misma referencia por side-effect
-- (local CALIBER = Corpus.GetModule("caliber")). Depende del invariante by-ref
-- del registro de Corpus (CORPUS_Architecture.md §3): misma tabla, sin copia.
local function Boot()
    Corpus.RegisterModule("caliber", {})

    if SERVER then
        for _, f in ipairs(SHARED)       do inc(f) end
        for _, f in ipairs(SERVER_FILES) do inc(f) end
    else
        for _, f in ipairs(SHARED)       do inc(f) end
        for _, f in ipairs(CLIENT_FILES) do inc(f) end
    end

    Corpus.Log("caliber", "cargado (" .. (SERVER and "server" or "client") .. ")")
end

if CorpusListo() then
    -- lua refresh o carga tardía: el framework ya está — boot inmediato
    Boot()
else
    -- Gmod ejecuta lua/autorun/ en orden alfabético del nombre de archivo, FUSIONADO
    -- entre todos los addons: "corpus_caliber_init.lua" ordena ANTES que
    -- "corpus_data.lua"/"corpus_registry.lua", así que en una carga de mapa normal
    -- Corpus todavía NO existe cuando corre este init. Diferir el boot al hook
    -- "Initialize" (corre en ambos realms después de TODO autorun y antes de
    -- InitPostEntity) mantiene las garantías: los tabs de UI llegan antes de
    -- PopulateToolMenu, los net strings antes de que conecte un cliente, y los
    -- hooks InitPostEntity de core se registran antes de que la barrera dispare.
    hook.Add("Initialize", "corpus_caliber_boot", function()
        hook.Remove("Initialize", "corpus_caliber_boot")
        if CorpusListo() then
            Boot()
        else
            -- Sin el framework, el módulo no arranca (falla ruidoso, no silencioso).
            -- No se usa Corpus.Log aquí: Corpus no existe.
            MsgN("[Caliber] Corpus framework no encontrado. Verificar que el addon corpus/ esté instalado y montado.")
        end
    end)
end
