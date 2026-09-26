-- Luau | Executor
-- Facility — Main + Kill Aura + Auto Farm + Webhooks
-- v22

local BASE = "https://raw.githubusercontent.com/FacilityHUB/UI-Facility-Test/refs/heads/main/"
local source = game:HttpGet(BASE .. "main.luau")
assert(#source > 1000 and not string.find(source, "404", 1, true), "main.luau introuvable")
local chunk, err = loadstring(source)
assert(chunk, "compile error: " .. tostring(err))
local Library = chunk()
assert(type(Library) == "table", "main.luau incomplet")
Library.BaseUrl = BASE

local SaveManager      = Library.SaveManager
local InterfaceManager = Library.InterfaceManager
local ThemeManager     = Library.ThemeManager

local Players          = game:GetService("Players")
local RS               = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local TeleportService  = game:GetService("TeleportService")
local UserInputService = game:GetService("UserInputService")
local Lighting         = game:GetService("Lighting")
local VirtualUser      = game:GetService("VirtualUser")
local HttpService      = game:GetService("HttpService")

--=====================================================================
-- Wait For Character
--=====================================================================

while not Players.LocalPlayer do task.wait(0.1) end
local LocalPlayer = Players.LocalPlayer

while not LocalPlayer.Character do task.wait(0.1) end
while not LocalPlayer.Character:FindFirstChild("HumanoidRootPart") do task.wait(0.1) end
task.wait(0.3)

--=====================================================================
-- GunConfig Cache
--=====================================================================

local GunConfig = nil
pcall(function() GunConfig = require(RS.Data.GunConfig) end)

local configCache = {}
local function getGunConfig(name)
    if configCache[name] ~= nil then return configCache[name] end
    local cfg = nil
    if GunConfig and GunConfig.GetConfig then
        pcall(function() cfg = GunConfig.GetConfig(name) end)
    end
    configCache[name] = cfg or false
    return configCache[name]
end

local function isMelee(name)
    local cfg = getGunConfig(name)
    return cfg and cfg.IsMelee == true
end

local function needsProjectileAuth(name)
    local cfg = getGunConfig(name)
    return cfg and cfg.RequiresProjectileAuthorization == true
end

--=====================================================================
-- MapData / MutatorData
--=====================================================================

local MapData     = nil
local MutatorData = nil
pcall(function() MapData     = require(RS.Data.MapData) end)
pcall(function() MutatorData = require(RS.Data.MutatorData) end)

local function getWavesMaps()
    if MapData and MapData.Order then
        local t = {}
        for _, k in ipairs(MapData.Order) do
            local d = MapData:Get(k)
            if d and d.RaidEnabled ~= true then table.insert(t, k) end
        end
        if #t > 0 then return t end
    end
    return {"RooftopSiege","AbandonedFarm","PrisonYard","Atlantis","Tundra"}
end

local function getRaidMaps()
    if MapData and MapData.Order then
        local t = {}
        for _, k in ipairs(MapData.Order) do
            local d = MapData:Get(k)
            if d and d.RaidEnabled == true then table.insert(t, k) end
        end
        if #t > 0 then return t end
    end
    return {"Crossroads","AbandonedShip","Tundra"}
end

local MUTATOR_OPTS = {"None"}
if MutatorData and MutatorData.Order then
    for _, k in ipairs(MutatorData.Order) do table.insert(MUTATOR_OPTS, k) end
else
    for _, m in ipairs({"HordeRush","GlassCannon","BloodFrenzy","Icy","GlassFrenzy"}) do
        table.insert(MUTATOR_OPTS, m)
    end
end

--=====================================================================
-- Helpers
--=====================================================================

local function getChar()    return LocalPlayer.Character end
local function getHRP()     local c = getChar(); return c and c:FindFirstChild("HumanoidRootPart") end
local function getCharPos() local h = getHRP();  return h and h.Position or nil end

local function getHumanoid()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function getHealthPct()
    local hum = getHumanoid()
    if not hum or hum.MaxHealth <= 0 then return 1 end
    return hum.Health / hum.MaxHealth
end

local function getZC()
    if _G.ZombieClient then return _G.ZombieClient end
    local ok, sr = pcall(function() return require(RS.Modules.ServiceRegistry) end)
    if ok and sr and sr.Get then
        local zc = nil
        pcall(function() zc = sr.Get("ZombieClient") end)
        return zc
    end
    return nil
end

local function getEquippedGunName()
    local c = getChar()
    if c then
        for _, obj in ipairs(c:GetChildren()) do
            if obj:IsA("Tool") then return obj.Name end
        end
    end
    return nil
end

local function getPlayerStat(name)
    local v = LocalPlayer:FindFirstChild(name)
    return v and tostring(v.Value) or "N/A"
end

--=====================================================================
-- Auto-Touch Ship
--=====================================================================

local function isSeated()
    local queues = workspace:FindFirstChild("Queues")
    if not queues then return false end
    local char = getChar()
    if not char then return false end
    for _, ship in ipairs(queues:GetChildren()) do
        for _, obj in ipairs(ship:GetDescendants()) do
            if (obj:IsA("Seat") or obj:IsA("VehicleSeat")) and obj.Occupant then
                if obj.Occupant.Parent == char then return true end
            end
        end
    end
    return false
end

local function touchShip()
    local queues = workspace:FindFirstChild("Queues")
    if not queues then return false end
    local hrp = getHRP()
    if not hrp then return false end
    for _, ship in ipairs(queues:GetChildren()) do
        local touchPart = ship:FindFirstChild("TouchPart")
        if not touchPart then continue end
        local prevCF = hrp.CFrame
        hrp.CFrame = touchPart.CFrame
        task.wait(0.3)
        hrp.CFrame = prevCF
        return true
    end
    return false
end

--=====================================================================
-- Flags
--=====================================================================

local Flags = {
    kill_aura     = false,
    aura_radius   = 60,
    aura_interval = 0.01,
}

local MFlags = {
    walkspeed      = false,
    walkspeed_v    = 16,
    jumppower      = false,
    jumppower_v    = 50,
    noclip         = false,
    fly            = false,
    fly_speed      = 50,
    anti_afk       = false,
    no_fog         = false,
    disable_render = false,
    black_screen   = false,
    potato         = false,
    antivoid       = false,
    antivoid_y     = -100,
}

local QFlags = {
    mode          = "Waves",
    difficulty    = "Normal",
    map           = getWavesMaps()[1],
    raid_map      = getRaidMaps()[1],
    party_size    = 1,
    mutator       = "None",
    auto_create   = false,
    auto_delay    = 5,
    max_wave      = 20,
    auto_replay   = false,
    suicide_delay = 3,
}

local SFlags = {
    auto_salvage  = false,
    salvage_delay = 0.5,
}

local SafeFlags = { active = false }
local AEFlags   = { auto_equip = false }

local UFlags = {
    auto_upgrade_health = false,
    auto_upgrade_weapon = false,
}

local GearFlags = {
    gear1 = false, gear2 = false, gear3 = false,
    interval1 = 1, interval2 = 1, interval3 = 1,
}

local WFlags = {
    enabled           = false,
    url               = "",
    current_name      = "",
    autoload_name     = "",
    send_on_start     = true,
    send_on_end       = true,
    stat_wood         = true,
    stat_iron         = true,
    stat_bloodmoon    = false,
    stat_voidshards   = false,
    stat_class        = true,
    stat_tophard      = false,
    stat_topmutator   = false,
    stat_topnightmare = false,
}

local savedWebhooks         = {}
local currentWaveForWebhook = 0

local function getMaxWave()   return QFlags.max_wave end
local function getAutoDelay() return QFlags.auto_delay end

--=====================================================================
-- Webhook Persistence
--=====================================================================

local WEBHOOK_FOLDER = "Facility/ArenaSurvivalZombie/WebHook"
local WEBHOOK_FILE   = WEBHOOK_FOLDER .. "/webhooks.json"

local function ensureWebhookFolder()
    pcall(function()
        if not isfolder("Facility") then makefolder("Facility") end
        if not isfolder("Facility/ArenaSurvivalZombie") then makefolder("Facility/ArenaSurvivalZombie") end
        if not isfolder(WEBHOOK_FOLDER) then makefolder(WEBHOOK_FOLDER) end
    end)
end

local function saveWebhooksToDisk()
    pcall(function()
        ensureWebhookFolder()
        writefile(WEBHOOK_FILE, HttpService:JSONEncode({
            webhooks = savedWebhooks,
            autoload = WFlags.autoload_name,
        }))
    end)
end

local function loadWebhooksFromDisk()
    pcall(function()
        ensureWebhookFolder()
        if isfile(WEBHOOK_FILE) then
            local data    = readfile(WEBHOOK_FILE)
            local decoded = HttpService:JSONDecode(data)
            if type(decoded) == "table" then
                if type(decoded.webhooks) == "table" then
                    savedWebhooks = decoded.webhooks
                end
                if type(decoded.autoload) == "string" then
                    WFlags.autoload_name = decoded.autoload
                end
            end
        end
    end)
end

loadWebhooksFromDisk()

if WFlags.autoload_name ~= "" then
    for _, entry in ipairs(savedWebhooks) do
        if entry.name == WFlags.autoload_name then
            WFlags.url          = entry.url
            WFlags.current_name = entry.name
            break
        end
    end
end

local function getWebhookNames()
    local opts = {"None"}
    for _, entry in ipairs(savedWebhooks) do
        table.insert(opts, entry.name)
    end
    return opts
end

--=====================================================================
-- Webhook Send
--=====================================================================

local function buildWebhookPayload(eventType)
    local fields = {}
    table.insert(fields, { name = "Event",  value = eventType,                       inline = true })
    table.insert(fields, { name = "Player", value = LocalPlayer.Name,                inline = true })
    table.insert(fields, { name = "Wave",   value = tostring(currentWaveForWebhook), inline = true })
    if WFlags.stat_class        then table.insert(fields, { name = "Class",               value = getPlayerStat("SelectedClass"),    inline = true }) end
    if WFlags.stat_wood         then table.insert(fields, { name = "Wood",                value = getPlayerStat("Wood"),             inline = true }) end
    if WFlags.stat_iron         then table.insert(fields, { name = "Iron",                value = getPlayerStat("Iron"),             inline = true }) end
    if WFlags.stat_bloodmoon    then table.insert(fields, { name = "Bloodmoon Shards",    value = getPlayerStat("BloodmoonShards"),  inline = true }) end
    if WFlags.stat_voidshards   then table.insert(fields, { name = "Void Shards",         value = getPlayerStat("VoidShards"),       inline = true }) end
    if WFlags.stat_tophard      then table.insert(fields, { name = "Top Wave Hard",       value = getPlayerStat("TopWaveHard"),      inline = true }) end
    if WFlags.stat_topmutator   then table.insert(fields, { name = "Top Wave Mutator",    value = getPlayerStat("TopWaveMutator"),   inline = true }) end
    if WFlags.stat_topnightmare then table.insert(fields, { name = "Top Wave Nightmare",  value = getPlayerStat("TopWaveNightmare"), inline = true }) end
    local color = eventType == "Game Started" and 3066993 or 15158332
    return HttpService:JSONEncode({
        embeds = {{
            title     = "Facility — " .. eventType,
            color     = color,
            fields    = fields,
            footer    = { text = "Facility HUB v22" },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }}
    })
end

local function sendWebhookDirect(eventType)
    if not WFlags.enabled then return end
    local url = WFlags.url
    if not url or url == "" then
        Library:Warn("Webhooks", "No URL configured.", 3)
        return
    end
    task.spawn(function()
        local ok, e = pcall(function()
            local payload = buildWebhookPayload(eventType)
            local reqFn   = request or http_request or (syn and syn.request) or (fluxus and fluxus.request)
            if reqFn then
                reqFn({
                    Url     = url,
                    Method  = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body    = payload,
                })
            end
        end)
        if ok then
            Library:Success("Webhooks", eventType .. " sent.", 3)
        else
            Library:Error("Webhooks", "Failed: " .. tostring(e), 4)
        end
    end)
end

--=====================================================================
-- Player Features
--=====================================================================

local walkspeedConn = nil
local function applyWalkspeed()
    local hum = getHumanoid()
    if hum then hum.WalkSpeed = MFlags.walkspeed_v end
end
local function startWalkspeed()
    applyWalkspeed()
    if walkspeedConn then return end
    walkspeedConn = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        if MFlags.walkspeed then applyWalkspeed() end
    end)
end
local function stopWalkspeed()
    local hum = getHumanoid()
    if hum then hum.WalkSpeed = 16 end
    if walkspeedConn then walkspeedConn:Disconnect(); walkspeedConn = nil end
end

local jumppowerConn = nil
local function applyJumpPower()
    local hum = getHumanoid()
    if hum then hum.JumpPower = MFlags.jumppower_v end
end
local function startJumpPower()
    applyJumpPower()
    if jumppowerConn then return end
    jumppowerConn = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.5)
        if MFlags.jumppower then applyJumpPower() end
    end)
end
local function stopJumpPower()
    local hum = getHumanoid()
    if hum then hum.JumpPower = 50 end
    if jumppowerConn then jumppowerConn:Disconnect(); jumppowerConn = nil end
end

local noclipConn = nil
local function startNoclip()
    if noclipConn then return end
    noclipConn = RunService.Heartbeat:Connect(function()
        if not MFlags.noclip then return end
        local char = getChar()
        if not char then return end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then part.CanCollide = false end
        end
    end)
end
local function stopNoclip()
    MFlags.noclip = false
    if noclipConn then noclipConn:Disconnect(); noclipConn = nil end
end

local flyConn  = nil
local bodyVel  = nil
local bodyGyro = nil
local FLY_KEYS = {
    forward  = Enum.KeyCode.W, backward = Enum.KeyCode.S,
    left     = Enum.KeyCode.A, right    = Enum.KeyCode.D,
    up       = Enum.KeyCode.E, down     = Enum.KeyCode.Q,
}
local function startFly()
    if flyConn then return end
    local hrp = getHRP()
    if not hrp then return end
    bodyVel = Instance.new("BodyVelocity")
    bodyVel.Velocity  = Vector3.zero
    bodyVel.MaxForce  = Vector3.new(math.huge, math.huge, math.huge)
    bodyVel.Parent    = hrp
    bodyGyro = Instance.new("BodyGyro")
    bodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
    bodyGyro.D         = 100
    bodyGyro.CFrame    = hrp.CFrame
    bodyGyro.Parent    = hrp
    local hum = getHumanoid()
    if hum then hum.PlatformStand = true end
    flyConn = RunService.Heartbeat:Connect(function()
        if not MFlags.fly then return end
        local h = getHRP()
        if not h or not bodyVel or not bodyVel.Parent then return end
        local cam   = workspace.CurrentCamera
        local speed = MFlags.fly_speed
        local dir   = Vector3.zero
        if UserInputService:IsKeyDown(FLY_KEYS.forward)  then dir = dir + cam.CFrame.LookVector end
        if UserInputService:IsKeyDown(FLY_KEYS.backward) then dir = dir - cam.CFrame.LookVector end
        if UserInputService:IsKeyDown(FLY_KEYS.right)    then dir = dir + cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(FLY_KEYS.left)     then dir = dir - cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(FLY_KEYS.up)       then dir = dir + Vector3.new(0, 1, 0) end
        if UserInputService:IsKeyDown(FLY_KEYS.down)     then dir = dir - Vector3.new(0, 1, 0) end
        bodyVel.Velocity = dir.Magnitude > 0 and (dir.Unit * speed) or Vector3.zero
        bodyGyro.CFrame  = cam.CFrame
    end)
end
local function stopFly()
    MFlags.fly = false
    if flyConn  then flyConn:Disconnect();  flyConn  = nil end
    if bodyVel  then bodyVel:Destroy();     bodyVel  = nil end
    if bodyGyro then bodyGyro:Destroy();    bodyGyro = nil end
    local hum = getHumanoid()
    if hum then hum.PlatformStand = false end
end

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.5)
    if MFlags.walkspeed then applyWalkspeed() end
    if MFlags.jumppower  then applyJumpPower() end
    if MFlags.fly then
        stopFly(); task.wait(0.2)
        MFlags.fly = true; startFly()
    end
end)

--=====================================================================
-- Misc Features
--=====================================================================

local antiAfkConn = nil
local function startAntiAfk()
    pcall(function()
        local AfkPolicy = require(RS.Shared.AfkPolicy)
        if setreadonly then
            setreadonly(AfkPolicy, false)
            rawset(AfkPolicy, "WARN_AT_IDLE_SECONDS",   math.huge)
            rawset(AfkPolicy, "RETURN_AT_IDLE_SECONDS", math.huge)
            setreadonly(AfkPolicy, true)
        end
    end)
    if antiAfkConn then return end
    antiAfkConn = LocalPlayer.Idled:Connect(function()
        if not MFlags.anti_afk then return end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:Button1Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
            task.wait(0.1)
            VirtualUser:Button1Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        end)
    end)
end

local originalFogEnd   = Lighting.FogEnd
local originalFogStart = Lighting.FogStart
local function enableNoFog()
    originalFogEnd   = Lighting.FogEnd
    originalFogStart = Lighting.FogStart
    Lighting.FogEnd   = math.huge
    Lighting.FogStart = math.huge
end
local function disableNoFog()
    Lighting.FogEnd   = originalFogEnd
    Lighting.FogStart = originalFogStart
end

local renderGuiConns = {}
local function enableDisableRender()
    pcall(function() RunService:Set3dRenderingEnabled(false) end)
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _, gui in ipairs(pg:GetChildren()) do
            if (gui:IsA("ScreenGui") or gui:IsA("BillboardGui")) and gui.Enabled then
                gui.Enabled = false
                table.insert(renderGuiConns, gui)
            end
        end
    end
end
local function disableDisableRender()
    pcall(function() RunService:Set3dRenderingEnabled(true) end)
    for _, gui in ipairs(renderGuiConns) do
        pcall(function() gui.Enabled = true end)
    end
    renderGuiConns = {}
end

local blackScreenGui = nil
local function enableBlackScreen()
    if blackScreenGui then return end
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    local sg = Instance.new("ScreenGui")
    sg.Name           = "FacilityBlackScreen"
    sg.ResetOnSpawn   = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Global
    sg.Parent         = pg
    local f = Instance.new("Frame")
    f.Size             = UDim2.new(1, 0, 1, 0)
    f.BackgroundColor3 = Color3.new(0, 0, 0)
    f.BorderSizePixel  = 0
    f.ZIndex           = 9999
    f.Parent           = sg
    blackScreenGui = sg
end
local function disableBlackScreen()
    if blackScreenGui then blackScreenGui:Destroy(); blackScreenGui = nil end
end

local potatoDestroyed = {}
local function enablePotato()
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    Lighting.GlobalShadows = false
    Lighting.FogEnd        = math.huge
    Lighting.FogStart      = math.huge
    pcall(function()
        workspace.Terrain.WaterWaveSize    = 0
        workspace.Terrain.WaterWaveSpeed   = 0
        workspace.Terrain.WaterReflectance = 0
    end)
    local blacklist = {
        "ParticleEmitter","Trail","Beam","Decal","Texture","Sky",
        "PointLight","SurfaceLight","SpotLight","Smoke","Fire","Sparkles",
    }
    for _, obj in ipairs(workspace:GetDescendants()) do
        for _, cls in ipairs(blacklist) do
            if obj:IsA(cls) then
                pcall(function()
                    table.insert(potatoDestroyed, {obj, obj.Parent})
                    obj.Parent = nil
                end)
                break
            end
        end
    end
    for _, obj in ipairs(Lighting:GetDescendants()) do
        if obj:IsA("Sky") or obj:IsA("Atmosphere") or obj:IsA("BloomEffect")
            or obj:IsA("BlurEffect") or obj:IsA("ColorCorrectionEffect")
            or obj:IsA("DepthOfFieldEffect") or obj:IsA("SunRaysEffect") then
            pcall(function()
                table.insert(potatoDestroyed, {obj, obj.Parent})
                obj.Parent = nil
            end)
        end
    end
    Library:Success("Misc", "Potato mode enabled.", 4)
end
local function disablePotato()
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic end)
    Lighting.GlobalShadows = true
    if not MFlags.no_fog then
        Lighting.FogEnd   = originalFogEnd
        Lighting.FogStart = originalFogStart
    end
    for _, pair in ipairs(potatoDestroyed) do
        pcall(function()
            local obj, parent = pair[1], pair[2]
            if obj and parent then obj.Parent = parent end
        end)
    end
    potatoDestroyed = {}
end

local antivoidConn    = nil
local antivoidSafePos = nil
local function startAntiVoid()
    if antivoidConn then return end
    antivoidConn = RunService.Heartbeat:Connect(function()
        if not MFlags.antivoid then return end
        local hrp = getHRP()
        if not hrp then return end
        if hrp.Position.Y > MFlags.antivoid_y then
            antivoidSafePos = hrp.CFrame
        else
            if antivoidSafePos then
                hrp.CFrame = antivoidSafePos
            else
                hrp.CFrame = CFrame.new(0, 50, 0)
            end
        end
    end)
end
local function stopAntiVoid()
    MFlags.antivoid = false
    if antivoidConn then antivoidConn:Disconnect(); antivoidConn = nil end
    antivoidSafePos = nil
end

--=====================================================================
-- Safe Place
--=====================================================================

local safePart     = nil
local safeConn     = nil
local SAFE_HEIGHT  = 5
local currentSafeY = 5
local salvageTping = false
local safeRetreat  = false

local function getSafeAbsoluteHeight()
    local hrp = getHRP()
    if not hrp then currentSafeY = SAFE_HEIGHT; return SAFE_HEIGHT end
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = { LocalPlayer.Character }
    local result  = workspace:Raycast(hrp.Position, Vector3.new(0, -5000, 0), rayParams)
    local groundY = result and result.Position.Y or 0
    currentSafeY  = groundY + SAFE_HEIGHT
    return currentSafeY
end

local function goToSafeHeight()
    local hrp = getHRP()
    if not hrp then return end
    hrp.CFrame = CFrame.new(hrp.Position.X, currentSafeY + 5, hrp.Position.Z)
end

local function enableSafePlace()
    local hrp = getHRP()
    if not hrp then Library:Warn("Safe Place", "Character not found.", 3); return end
    local absHeight = getSafeAbsoluteHeight()
    safePart = Instance.new("Part")
    safePart.Name         = "SafePlate"
    safePart.Size         = Vector3.new(10, 1, 10)
    safePart.Anchored     = true
    safePart.CanCollide   = true
    safePart.CanQuery     = false
    safePart.CastShadow   = false
    safePart.Transparency = 0.4
    safePart.BrickColor   = BrickColor.new("Bright blue")
    safePart.Material     = Enum.Material.SmoothPlastic
    safePart.CFrame       = CFrame.new(hrp.Position.X, absHeight, hrp.Position.Z)
    safePart.Parent       = workspace
    hrp.CFrame = CFrame.new(hrp.Position.X, absHeight + 5, hrp.Position.Z)
    safeConn = RunService.Heartbeat:Connect(function()
        if not SafeFlags.active then return end
        local h = getHRP()
        if not h then return end
        if salvageTping and not safeRetreat then
            if getHealthPct() < 0.5 then
                safeRetreat = true
                goToSafeHeight()
            end
        end
        if safeRetreat then
            if getHealthPct() >= 1 then
                safeRetreat = false
            else
                if h.Position.Y < currentSafeY + 1 then goToSafeHeight() end
                safePart.CFrame = CFrame.new(h.Position.X, currentSafeY, h.Position.Z)
                return
            end
        end
        if salvageTping then return end
        if h.Position.Y < currentSafeY + 1 then goToSafeHeight() end
        safePart.CFrame = CFrame.new(h.Position.X, currentSafeY, h.Position.Z)
    end)
    Library:Success("Safe Place", "Active at Y=" .. math.floor(absHeight) .. ".", 4)
end

local function disableSafePlace()
    if safeConn then safeConn:Disconnect(); safeConn = nil end
    if safePart then safePart:Destroy(); safePart = nil end
    safeRetreat  = false
    salvageTping = false
end

--=====================================================================
-- Auto Equip
--=====================================================================

local autoEquipConn     = nil
local autoEquipCharConn = nil

local function tryEquip()
    local char = getChar()
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    for _, v in ipairs(char:GetChildren()) do
        if v:IsA("Tool") then return end
    end
    local bp   = LocalPlayer:FindFirstChild("Backpack")
    local tool = bp and bp:GetChildren()[1]
    if tool and tool:IsA("Tool") then
        pcall(function() hum:EquipTool(tool) end)
    end
end

local function startAutoEquip()
    if autoEquipConn then return end
    tryEquip()
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then
        autoEquipConn = bp.ChildAdded:Connect(function(child)
            if not AEFlags.auto_equip then return end
            if not child:IsA("Tool") then return end
            task.wait(0.15)
            tryEquip()
        end)
    end
    autoEquipCharConn = LocalPlayer.CharacterAdded:Connect(function()
        if not AEFlags.auto_equip then return end
        task.wait(0.5)
        tryEquip()
    end)
end

local function stopAutoEquip()
    if autoEquipConn then autoEquipConn:Disconnect(); autoEquipConn = nil end
    if autoEquipCharConn then autoEquipCharConn:Disconnect(); autoEquipCharConn = nil end
end

--=====================================================================
-- Auto Upgrades
--=====================================================================

local upgradeLoop  = nil
local upgradeState = { health_maxed = false, weapon_maxed = false }

pcall(function()
    RS.Remotes.UpgradeRemotes.UpgradeUpdate.OnClientEvent:Connect(function(data)
        if type(data) ~= "table" then return end
        if data.HealthPrice == nil or data.HealthPrice == 0 then
            if UFlags.auto_upgrade_health and not upgradeState.health_maxed then
                upgradeState.health_maxed  = true
                UFlags.auto_upgrade_health = false
                Library:Success("Upgrade", "Health maxed out.", 4)
            end
        else
            upgradeState.health_maxed = false
        end
        if data.IsMaxWeapon == true or data.NextWeapon == nil then
            if UFlags.auto_upgrade_weapon and not upgradeState.weapon_maxed then
                upgradeState.weapon_maxed  = true
                UFlags.auto_upgrade_weapon = false
                Library:Success("Upgrade", "Weapon maxed out.", 4)
            end
        else
            upgradeState.weapon_maxed = false
        end
    end)
end)

local function startUpgradeLoop()
    if upgradeLoop then return end
    upgradeLoop = task.spawn(function()
        while UFlags.auto_upgrade_health or UFlags.auto_upgrade_weapon do
            if UFlags.auto_upgrade_health and not upgradeState.health_maxed then
                pcall(function() RS.Remotes.UpgradeRemotes.PurchaseHealthUpgrade:FireServer() end)
                task.wait(0.4)
            end
            if UFlags.auto_upgrade_weapon and not upgradeState.weapon_maxed then
                pcall(function() RS.Remotes.UpgradeRemotes.PurchaseWeaponUpgrade:FireServer() end)
                task.wait(0.4)
            end
            task.wait(0.3)
        end
        upgradeLoop = nil
    end)
end

local function stopUpgradeLoop()
    upgradeLoop = nil
end

--=====================================================================
-- Auto Gear
--=====================================================================

local gearLoops = { nil, nil, nil }

local function getGearName(slot)
    local pg  = LocalPlayer:FindFirstChild("PlayerGui")
    local cp  = pg and pg:FindFirstChild("MainGui")
    cp = cp and cp:FindFirstChild("ControlPanel")
    local btn = cp and cp:FindFirstChild("Gear" .. slot)
    local lbl = btn and btn:FindFirstChild("GearName")
    if not lbl then return nil end
    return lbl.Text:gsub("%s+", "")
end

local function startGearLoop(slot)
    if gearLoops[slot] then return end
    gearLoops[slot] = task.spawn(function()
        while GearFlags["gear" .. slot] do
            local name = getGearName(slot)
            if name and name ~= "" then
                pcall(function() RS.Remotes.GearRemotes.GearPurchase:FireServer(name) end)
            end
            task.wait(GearFlags["interval" .. slot])
        end
        gearLoops[slot] = nil
    end)
end

local function stopGearLoop(slot)
    GearFlags["gear" .. slot] = false
    gearLoops[slot] = nil
end

--=====================================================================
-- Create Party
--=====================================================================

local function fireCreateParty()
    local isRaid   = QFlags.mode == "Raid"
    local map      = isRaid and QFlags.raid_map or QFlags.map
    local mutators = (isRaid or QFlags.mutator == "None") and {} or {QFlags.mutator}
    if not isSeated() then
        local ok = touchShip()
        if not ok then
            Library:Warn("Auto Farm", "No ship found in workspace.Queues.", 4)
            return false
        end
        task.wait(1)
    end
    local ok, e = pcall(function()
        RS.Remotes.QueueRemotes.CreateParty:FireServer(
            QFlags.party_size, QFlags.difficulty, map, mutators, QFlags.mode)
    end)
    if ok then
        local info = QFlags.mode .. " / " .. QFlags.difficulty .. " / " .. map
        if #mutators > 0 then info = info .. " / " .. mutators[1] end
        Library:Success("Auto Farm", info, 5)
        return true
    else
        Library:Error("Auto Farm", "CreateParty failed: " .. tostring(e), 5)
        return false
    end
end

local function fireLeaveQueue()
    pcall(function() RS.Remotes.QueueRemotes.LeaveQueue:FireServer() end)
end

--=====================================================================
-- Auto Replay
--=====================================================================

local suicideActive  = false
local replayAlwaysCD = false

local function fireReplay()
    if replayAlwaysCD then return end
    replayAlwaysCD = true
    task.wait(0.5)
    pcall(function() RS.Remotes.GameStateRemotes.VotePlayAgain:FireServer() end)
    Library:Success("Auto Farm", "Replay fired.", 3)
    task.wait(5)
    replayAlwaysCD = false
end

local function doSuicideReplay()
    if suicideActive then return end
    suicideActive = true
    task.spawn(function()
        task.wait(QFlags.suicide_delay or 3)
        local fired = false
        local conn
        conn = RS.Remotes.GameStateRemotes.CountdownUpdate.OnClientEvent:Connect(function()
            if fired then return end
            fired = true
            conn:Disconnect()
            fireReplay()
            task.wait(3)
            suicideActive = false
        end)
        task.delay(15, function()
            if not fired then
                conn:Disconnect()
                suicideActive = false
            end
        end)
        local char = LocalPlayer.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if hum and hum.Health > 0 then hum.Health = 0 end
    end)
end

--=====================================================================
-- Auto Salvage
--=====================================================================

local salvageLoop = nil

local function startSalvage()
    if salvageLoop then return end
    salvageLoop = task.spawn(function()
        while SFlags.auto_salvage do
            while safeRetreat and SFlags.auto_salvage do task.wait(0.5) end
            if not SFlags.auto_salvage then break end
            local ship = workspace:FindFirstChild("Geometry")
            ship = ship and ship:FindFirstChild("Map")
            ship = ship and ship:FindFirstChild("Ship")
            if ship then
                local hrp = getHRP()
                for _, obj in ipairs(ship:GetDescendants()) do
                    if not SFlags.auto_salvage then break end
                    while safeRetreat and SFlags.auto_salvage do task.wait(0.5) end
                    if not SFlags.auto_salvage then break end
                    if not (obj:IsA("ProximityPrompt") and obj.ActionText == "Salvage" and obj.Enabled) then continue end
                    local part = obj.Parent
                    if not part:IsA("BasePart") then continue end
                    if part.Transparency >= 0.5 then continue end
                    hrp = getHRP()
                    if hrp then
                        salvageTping = true
                        hrp.CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0))
                        task.wait(0.2)
                        pcall(fireproximityprompt, obj)
                        task.wait(SFlags.salvage_delay)
                        if SafeFlags.active and safePart and not safeRetreat then
                            hrp = getHRP()
                            if hrp then goToSafeHeight() end
                        end
                        salvageTping = false
                    end
                end
            end
            task.wait(1)
        end
        salvageLoop = nil
    end)
end

local function stopSalvage()
    SFlags.auto_salvage = false
    salvageTping        = false
    salvageLoop         = nil
end

--=====================================================================
-- Watcher
--=====================================================================

task.spawn(function()
    local WaveRemotes = nil
    local ok = pcall(function()
        WaveRemotes = RS:WaitForChild("Remotes", 10):WaitForChild("WaveRemotes", 10)
    end)
    if not ok or not WaveRemotes then return end

    local currentWave  = 0
    local autoCreateCD = false
    local wave1Sent    = false
    local gameEndCD    = false

    local waveUpdateRemote = WaveRemotes:WaitForChild("WaveUpdate", 10)
    if waveUpdateRemote then
        waveUpdateRemote.OnClientEvent:Connect(function(waveNumber)
            if type(waveNumber) ~= "number" then return end
            currentWave           = waveNumber
            currentWaveForWebhook = waveNumber
            if waveNumber == 1 and not wave1Sent then
                wave1Sent = true
                gameEndCD = false
                if WFlags.send_on_start then sendWebhookDirect("Game Started") end
            end
            if waveNumber ~= 1 then wave1Sent = false end
            if currentWave < getMaxWave() then return end
            if QFlags.auto_replay then doSuicideReplay() end
        end)
    end

    local gameStateRemote = WaveRemotes:WaitForChild("GameStateUpdate", 10)
    if gameStateRemote then
        gameStateRemote.OnClientEvent:Connect(function(state, waveNumber)
            if type(waveNumber) == "number" then
                currentWave           = waveNumber
                currentWaveForWebhook = waveNumber
            end
            if QFlags.auto_create and not autoCreateCD
               and (state == "GameOver" or state == "Victory") then
                autoCreateCD = true
                task.spawn(function()
                    task.wait(getAutoDelay())
                    if QFlags.auto_create then fireCreateParty() end
                    task.wait(2)
                    autoCreateCD = false
                end)
            end
        end)
    end

    RS.Remotes.GameStateRemotes.CountdownUpdate.OnClientEvent:Connect(function()
        if WFlags.send_on_end and not gameEndCD then
            gameEndCD = true
            sendWebhookDirect("Game Ended")
        end
        if not QFlags.auto_replay then return end
        if suicideActive then return end
        local pg  = LocalPlayer:FindFirstChild("PlayerGui")
        local go  = pg and pg:FindFirstChild("GameOver")
        local btn = go and go:FindFirstChild("PlayAgain")
        if not (btn and btn.Visible) then return end
        fireReplay()
    end)
end)

--=====================================================================
-- Kill Aura Loop
--=====================================================================

local auraLastHit     = {}
local AURA_HIT_CD     = 0.3
local PROJ_AUTH_DELAY = 0.05
local lastMeleeWarn   = 0
local MELEE_WARN_CD   = 5

task.spawn(function()
    local acc = 0
    RunService.Heartbeat:Connect(function(dt)
        if not Flags.kill_aura then return end
        acc = acc + dt
        if acc < Flags.aura_interval then return end
        acc = 0
        local charPos = getCharPos(); if not charPos then return end
        local zc      = getZC();      if not zc or not zc.Zombies then return end
        local gunName = getEquippedGunName(); if not gunName then return end
        if isMelee(gunName) then
            local now = tick()
            if now - lastMeleeWarn >= MELEE_WARN_CD then
                lastMeleeWarn = now
                Library:Warn("Kill Aura", gunName .. " is a melee weapon — not supported.", 4)
            end
            return
        end
        local gunHit, gunFire
        pcall(function() gunHit  = RS.Remotes.GunRemotes.GunHit end)
        pcall(function() gunFire = RS.Remotes.NetRemotes.GunFire end)
        if not gunHit then return end
        local needsAuth = needsProjectileAuth(gunName)
        if needsAuth and not gunFire then return end
        local now   = tick()
        local fired = 0
        for id, zombie in pairs(zc.Zombies) do
            if fired >= 5 then break end
            if zombie.IsDying then continue end
            local pos = zombie.CurrentPosition
            if not pos then continue end
            if (pos - charPos).Magnitude > Flags.aura_radius then continue end
            if auraLastHit[id] and (now - auraLastHit[id]) < AURA_HIT_CD then continue end
            auraLastHit[id] = now
            local hitPos = Vector3.new(pos.X, pos.Y + 2, pos.Z)
            fired = fired + 1
            if needsAuth then
                local dir = (hitPos - charPos).Unit
                task.spawn(function()
                    pcall(function() gunFire:FireServer(gunName, charPos, dir) end)
                    task.wait(PROJ_AUTH_DELAY)
                    pcall(function() gunHit:FireServer(gunName, id, hitPos) end)
                end)
            else
                task.spawn(function()
                    pcall(function() gunHit:FireServer(gunName, id, hitPos) end)
                end)
            end
        end
    end)
end)

--=====================================================================
-- Window + Tabs
--=====================================================================

local Window = Library:Window({
    Title        = "Facility",
    Suffix       = ".app",
    Width        = 650,
    Height       = 550,
    MinWidth     = 400,
    MinHeight    = 350,
    MobileButton = true,
    TabStyle     = "side",
    TabWidth     = 130,
    Cursor       = true,
})

local TabMain     = Window:Tab("Main",      "home")
local TabAura     = Window:Tab("Kill Aura", "crosshair")
local TabFarm     = Window:Tab("Auto Farm", "zap")
local TabWebhook  = Window:Tab("Webhooks",  "bell")
local TabSettings = Window:Tab("Settings",  "settings")

--=====================================================================
-- TAB : Main
--=====================================================================

local mainBox1 = TabMain:Section("Player", 1)

mainBox1:Toggle({
    Text     = "Walk Speed",
    Flag     = "m_walkspeed",
    Default  = false,
    Callback = function(state)
        MFlags.walkspeed = state
        if state then startWalkspeed() else stopWalkspeed() end
    end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Speed",
        Flag     = "m_walkspeed_v",
        Min      = 1,
        Max      = 500,
        Default  = 16,
        Suffix   = " studs/s",
        Callback = function(v)
            MFlags.walkspeed_v = v
            if MFlags.walkspeed then applyWalkspeed() end
        end,
    })
end)

mainBox1:Toggle({
    Text     = "Jump Power",
    Flag     = "m_jumppower",
    Default  = false,
    Callback = function(state)
        MFlags.jumppower = state
        if state then startJumpPower() else stopJumpPower() end
    end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Power",
        Flag     = "m_jumppower_v",
        Min      = 1,
        Max      = 500,
        Default  = 50,
        Suffix   = " units",
        Callback = function(v)
            MFlags.jumppower_v = v
            if MFlags.jumppower then applyJumpPower() end
        end,
    })
end)

mainBox1:Toggle({
    Text     = "Noclip",
    Flag     = "m_noclip",
    Default  = false,
    Callback = function(state)
        MFlags.noclip = state
        if state then startNoclip() else stopNoclip() end
    end,
})

mainBox1:Toggle({
    Text     = "Fly",
    Flag     = "m_fly",
    Default  = false,
    Callback = function(state)
        MFlags.fly = state
        if state then startFly() else stopFly() end
    end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Fly Speed",
        Flag     = "m_fly_speed",
        Min      = 1,
        Max      = 500,
        Default  = 50,
        Suffix   = " studs/s",
        Callback = function(v) MFlags.fly_speed = v end,
    })
end)

local mainBox2 = TabMain:Section("Misc", 2)

mainBox2:Toggle({
    Text     = "Anti AFK",
    Flag     = "m_anti_afk",
    Default  = false,
    Callback = function(state)
        MFlags.anti_afk = state
        if state then startAntiAfk() end
    end,
})

mainBox2:Toggle({
    Text     = "No Fog",
    Flag     = "m_no_fog",
    Default  = false,
    Callback = function(state)
        MFlags.no_fog = state
        if state then enableNoFog() else disableNoFog() end
    end,
})

mainBox2:Toggle({
    Text     = "Disable Rendering",
    Flag     = "m_disable_render",
    Default  = false,
    Callback = function(state)
        MFlags.disable_render = state
        if state then enableDisableRender() else disableDisableRender() end
    end,
})

mainBox2:Toggle({
    Text     = "Black Screen",
    Flag     = "m_black_screen",
    Default  = false,
    Callback = function(state)
        MFlags.black_screen = state
        if state then enableBlackScreen() else disableBlackScreen() end
    end,
})

mainBox2:Toggle({
    Text     = "Potato Mode",
    Flag     = "m_potato",
    Default  = false,
    Callback = function(state)
        MFlags.potato = state
        if state then enablePotato() else disablePotato() end
    end,
})

mainBox2:Toggle({
    Text     = "Anti Void",
    Flag     = "m_antivoid",
    Default  = false,
    Callback = function(state)
        MFlags.antivoid = state
        if state then startAntiVoid() else stopAntiVoid() end
    end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Void Threshold",
        Flag     = "m_antivoid_y",
        Min      = -2000,
        Max      = 0,
        Default  = -100,
        Suffix   = " Y",
        Callback = function(v) MFlags.antivoid_y = v end,
    })
end)

--=====================================================================
-- TAB : Kill Aura
--=====================================================================

local auraBox1 = TabAura:Section("Kill Aura", 1)

auraBox1:Toggle({
    Text     = "Enabled",
    Flag     = "kill_aura",
    Default  = false,
    Callback = function(state) Flags.kill_aura = state end,
}):Keybind({ Default = "F", Flag = "kill_aura_key" })

auraBox1:Toggle({
    Text     = "Auto Equip Weapon",
    Flag     = "auto_equip",
    Default  = false,
    Callback = function(state)
        AEFlags.auto_equip = state
        if state then startAutoEquip() else stopAutoEquip() end
    end,
})

auraBox1:Slider({
    Text     = "Radius",
    Flag     = "aura_radius",
    Min      = 10,
    Max      = 500,
    Default  = 60,
    Suffix   = " Studs",
    Callback = function(val) Flags.aura_radius = val end,
})

auraBox1:Slider({
    Text     = "Interval",
    Flag     = "aura_interval",
    Min      = 1,
    Max      = 100,
    Default  = 10,
    Suffix   = " ms",
    Callback = function(val) Flags.aura_interval = math.max(0.001, val / 1000) end,
})

auraBox1:Paragraph({
    Title   = "Unsupported Weapons",
    Content = "Kill Aura does not work with melee weapons or explosive weapons. Damage for these weapon types is calculated server-side.",
    Icon    = "alert-triangle",
    Style   = "warning",
})

local auraBox2 = TabAura:Section("Upgrades", 2)

auraBox2:Toggle({
    Text     = "Auto Upgrade Weapon",
    Flag     = "q_auto_upgrade_weapon",
    Default  = false,
    Callback = function(state)
        UFlags.auto_upgrade_weapon = state
        upgradeState.weapon_maxed  = false
        if state then startUpgradeLoop()
        elseif not UFlags.auto_upgrade_health then stopUpgradeLoop() end
    end,
})

auraBox2:Toggle({
    Text     = "Auto Upgrade Health",
    Flag     = "q_auto_upgrade_health",
    Default  = false,
    Callback = function(state)
        UFlags.auto_upgrade_health = state
        upgradeState.health_maxed  = false
        if state then startUpgradeLoop()
        elseif not UFlags.auto_upgrade_weapon then stopUpgradeLoop() end
    end,
})

local auraBox3 = TabAura:Section("Gears", 1)

auraBox3:Toggle({
    Text     = "Gear 1",
    Flag     = "gear1",
    Default  = false,
    Callback = function(state)
        GearFlags.gear1 = state
        if state then startGearLoop(1) else stopGearLoop(1) end
    end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Interval",
        Flag     = "gear1_interval",
        Min      = 1,
        Max      = 60,
        Default  = 1,
        Suffix   = " s",
        Callback = function(v) GearFlags.interval1 = v end,
    })
end)

auraBox3:Toggle({
    Text     = "Gear 2",
    Flag     = "gear2",
    Default  = false,
    Callback = function(state)
        GearFlags.gear2 = state
        if state then startGearLoop(2) else stopGearLoop(2) end
    end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Interval",
        Flag     = "gear2_interval",
        Min      = 1,
        Max      = 60,
        Default  = 1,
        Suffix   = " s",
        Callback = function(v) GearFlags.interval2 = v end,
    })
end)

auraBox3:Toggle({
    Text     = "Gear 3",
    Flag     = "gear3",
    Default  = false,
    Callback = function(state)
        GearFlags.gear3 = state
        if state then startGearLoop(3) else stopGearLoop(3) end
    end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Interval",
        Flag     = "gear3_interval",
        Min      = 1,
        Max      = 60,
        Default  = 1,
        Suffix   = " s",
        Callback = function(v) GearFlags.interval3 = v end,
    })
end)

local auraBox4 = TabAura:Section("Safe Place", 2)

auraBox4:Toggle({
    Text     = "Enabled",
    Flag     = "safe_place",
    Default  = false,
    Callback = function(state)
        SafeFlags.active = state
        if state then enableSafePlace() else disableSafePlace() end
    end,
}):Keybind({ Default = "P", Flag = "safe_place_key" })

auraBox4:Slider({
    Text     = "Height",
    Flag     = "safe_height",
    Min      = 0,
    Max      = 100,
    Default  = 5,
    Suffix   = " Studs",
    Callback = function(v)
        SAFE_HEIGHT = v
        if SafeFlags.active then disableSafePlace(); enableSafePlace() end
    end,
})

--=====================================================================
-- TAB : Auto Farm
--=====================================================================

local farmBox1 = TabFarm:Section("Game", 1)

farmBox1:Dropdown({
    Text     = "Mode",
    Flag     = "q_mode",
    Options  = {"Waves", "Raid"},
    Default  = "Waves",
    Callback = function(v) QFlags.mode = v end,
})

farmBox1:Dropdown({
    Text     = "Difficulty",
    Flag     = "q_difficulty",
    Options  = {"Normal", "Hardcore", "Nightmare"},
    Default  = "Normal",
    Callback = function(v) QFlags.difficulty = v end,
})

farmBox1:Dropdown({
    Text     = "Map",
    Flag     = "q_map",
    Options  = getWavesMaps(),
    Default  = getWavesMaps()[1],
    Callback = function(v) QFlags.map = v end,
})

farmBox1:Dropdown({
    Text     = "Mutator",
    Flag     = "q_mutator",
    Options  = MUTATOR_OPTS,
    Default  = "None",
    Callback = function(v) QFlags.mutator = v end,
})

farmBox1:Slider({
    Text     = "Party Size",
    Flag     = "q_size",
    Min      = 1,
    Max      = 4,
    Default  = 1,
    Suffix   = " Player(s)",
    Callback = function(v) QFlags.party_size = v end,
})

farmBox1:Toggle({
    Text     = "Auto Create Party",
    Flag     = "q_auto_create",
    Default  = false,
    Callback = function(state) QFlags.auto_create = state end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Delay Before Recreate",
        Flag     = "q_auto_delay",
        Min      = 1,
        Max      = 30,
        Default  = 5,
        Suffix   = " s",
        Callback = function(v) QFlags.auto_delay = v end,
    })
end)

farmBox1:Button({
    Text     = "Create Party",
    Callback = function() fireCreateParty() end,
})

farmBox1:Button({
    Text     = "Leave Queue",
    Style    = "danger",
    Callback = function()
        fireLeaveQueue()
        Library:Notify({ Title = "Auto Farm", Text = "Left queue.", Duration = 3 })
    end,
})

local farmBox2 = TabFarm:Section("Replay", 2)

farmBox2:Slider({
    Text     = "Max Wave",
    Flag     = "q_max_wave",
    Min      = 1,
    Max      = 200,
    Default  = 20,
    Suffix   = " Waves",
    Callback = function(v) QFlags.max_wave = v end,
})

farmBox2:Toggle({
    Text     = "Auto Replay",
    Flag     = "q_auto_replay",
    Default  = false,
    Callback = function(state)
        QFlags.auto_replay = state
        Library:Notify({
            Title    = "Auto Farm",
            Text     = state and "Auto Replay enabled." or "Auto Replay disabled.",
            Duration = 3
        })
    end,
}):Gear(function(panel)
    panel:Slider({
        Text     = "Suicide Delay",
        Flag     = "q_suicide_delay",
        Min      = 0,
        Max      = 15,
        Default  = 3,
        Suffix   = " s",
        Callback = function(v) QFlags.suicide_delay = v end,
    })
end)

local farmBox3 = TabFarm:Section("Farm Pirate", 2)

farmBox3:Toggle({
    Text     = "Auto Collect",
    Flag     = "q_auto_salvage",
    Default  = false,
    Callback = function(state)
        SFlags.auto_salvage = state
        if state then startSalvage() else stopSalvage() end
    end,
})

farmBox3:Slider({
    Text     = "Delay Between Collects",
    Flag     = "q_salvage_delay",
    Min      = 1,
    Max      = 50,
    Default  = 5,
    Suffix   = " x 100ms",
    Callback = function(v) SFlags.salvage_delay = v / 10 end,
})

--=====================================================================
-- TAB : Webhooks
--=====================================================================

local whBox1     = TabWebhook:Section("Config", 1)
local whDropdown = nil

whBox1:Input({
    Text        = "Webhook Name",
    Flag        = "wh_name",
    Default     = "",
    Placeholder = "My Webhook",
    Callback    = function(v) WFlags.current_name = v end,
})

whBox1:Input({
    Text        = "Webhook URL",
    Flag        = "wh_url",
    Default     = "",
    Placeholder = "https://discord.com/api/webhooks/...",
    Callback    = function(v) WFlags.url = v end,
})

whBox1:Button({
    Text     = "Save Webhook",
    Callback = function()
        local name = WFlags.current_name or ""
        local url  = WFlags.url or ""
        if name == "" or url == "" then
            Library:Warn("Webhooks", "Name and URL required.", 3)
            return
        end
        local updated = false
        for i, entry in ipairs(savedWebhooks) do
            if entry.name == name then
                savedWebhooks[i] = { name = name, url = url }
                updated = true
                break
            end
        end
        if not updated then
            table.insert(savedWebhooks, { name = name, url = url })
        end
        saveWebhooksToDisk()
        if whDropdown then
            pcall(function() whDropdown:SetOptions(getWebhookNames()) end)
        end
        Library:Success("Webhooks", (updated and "Updated: " or "Saved: ") .. name, 3)
    end,
})

whDropdown = whBox1:Dropdown({
    Text     = "Saved Webhooks",
    Flag     = "wh_saved_select",
    Options  = getWebhookNames(),
    Default  = "None",
    Callback = function(v)
        if v == "None" then return end
        for _, entry in ipairs(savedWebhooks) do
            if entry.name == v then
                WFlags.url          = entry.url
                WFlags.current_name = entry.name
                Library:Notify({ Title = "Webhooks", Text = "Loaded: " .. entry.name, Duration = 3 })
                return
            end
        end
    end,
})

whBox1:Button({
    Text     = "Set As Autoload",
    Callback = function()
        local name = WFlags.current_name or ""
        if name == "" then
            Library:Warn("Webhooks", "Select or save a webhook first.", 3)
            return
        end
        WFlags.autoload_name = name
        saveWebhooksToDisk()
        Library:Success("Webhooks", "Autoload set to: " .. name, 3)
    end,
})

whBox1:Button({
    Text     = "Clear Autoload",
    Callback = function()
        WFlags.autoload_name = ""
        saveWebhooksToDisk()
        Library:Notify({ Title = "Webhooks", Text = "Autoload cleared.", Duration = 3 })
    end,
})

whBox1:Button({
    Text     = "Delete Selected",
    Style    = "danger",
    Callback = function()
        local name = WFlags.current_name or ""
        if name == "" then
            Library:Warn("Webhooks", "Nothing selected.", 3)
            return
        end
        for i, entry in ipairs(savedWebhooks) do
            if entry.name == name then
                table.remove(savedWebhooks, i)
                saveWebhooksToDisk()
                if whDropdown then
                    pcall(function() whDropdown:SetOptions(getWebhookNames()) end)
                end
                if WFlags.autoload_name == name then
                    WFlags.autoload_name = ""
                end
                Library:Notify({ Title = "Webhooks", Text = "Deleted: " .. name, Duration = 3 })
                WFlags.current_name = ""
                WFlags.url          = ""
                return
            end
        end
    end,
})

whBox1:Toggle({
    Text     = "Enabled",
    Flag     = "wh_enabled",
    Default  = false,
    Callback = function(state)
        WFlags.enabled = state
        Library:Notify({
            Title    = "Webhooks",
            Text     = state and "Webhook enabled." or "Webhook disabled.",
            Duration = 3
        })
    end,
})

whBox1:Toggle({
    Text     = "Send On Game Start",
    Flag     = "wh_send_start",
    Default  = true,
    Callback = function(state) WFlags.send_on_start = state end,
})

whBox1:Toggle({
    Text     = "Send On Game End",
    Flag     = "wh_send_end",
    Default  = true,
    Callback = function(state) WFlags.send_on_end = state end,
})

whBox1:Button({
    Text     = "Send Test",
    Callback = function() sendWebhookDirect("Test") end,
})

local whBox2 = TabWebhook:Section("Stats To Include", 2)

whBox2:Toggle({ Text = "Class",               Flag = "wh_stat_class",         Default = true,  Callback = function(s) WFlags.stat_class        = s end })
whBox2:Toggle({ Text = "Wood",                Flag = "wh_stat_wood",          Default = true,  Callback = function(s) WFlags.stat_wood         = s end })
whBox2:Toggle({ Text = "Iron",                Flag = "wh_stat_iron",          Default = true,  Callback = function(s) WFlags.stat_iron         = s end })
whBox2:Toggle({ Text = "Bloodmoon Shards",    Flag = "wh_stat_bloodmoon",     Default = false, Callback = function(s) WFlags.stat_bloodmoon    = s end })
whBox2:Toggle({ Text = "Void Shards",         Flag = "wh_stat_voidshards",    Default = false, Callback = function(s) WFlags.stat_voidshards   = s end })
whBox2:Toggle({ Text = "Top Wave Hard",       Flag = "wh_stat_tophard",       Default = false, Callback = function(s) WFlags.stat_tophard      = s end })
whBox2:Toggle({ Text = "Top Wave Mutator",    Flag = "wh_stat_topmutator",    Default = false, Callback = function(s) WFlags.stat_topmutator   = s end })
whBox2:Toggle({ Text = "Top Wave Nightmare",  Flag = "wh_stat_topnightmare",  Default = false, Callback = function(s) WFlags.stat_topnightmare = s end })

--=====================================================================
-- TAB : Settings
--=====================================================================

SaveManager:SetLibrary(Library)
InterfaceManager:SetLibrary(Library)
InterfaceManager:SetWindow(Window)
ThemeManager:SetLibrary(Library)

SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({})

InterfaceManager:SetFolder("Facility")
ThemeManager:SetFolder("Facility")
ThemeManager:Load()
SaveManager:SetFolder("Facility/app")

InterfaceManager:BuildInterfaceSection(TabSettings, 1)
SaveManager:BuildConfigSection(TabSettings, 2)
ThemeManager:Mount(Window)

Window:SetTab(TabMain)

Window:Action("Discord", function()
    if setclipboard then
        setclipboard("https://discord.gg/jTuXv2Kcsn")
        Library:Success("Discord", "Link copied to clipboard.", 3)
    else
        Library:Notify({ Title = "Discord", Text = "https://discord.gg/jTuXv2Kcsn", Duration = 6 })
    end
end)

Library:Notify({ Title = "Facility", Text = "Loaded. v22", Duration = 4 })
SaveManager:LoadAutoloadConfig()
