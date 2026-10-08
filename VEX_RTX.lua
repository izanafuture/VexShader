--[[
    VEX RTX 5.0 / EVADE EDITION
    Repository: https://github.com/izanafuture/VexShader
    Client-only RTX-style visual effects for Roblox (Luau).

    CLIENT-SIDE VISUAL EXPERIMENT: 8 color presets, glossy surfaces,
    optional ViewportFrame floor overlays and raycast-sampled light probes.
    NOT hardware RTX, SSR, or true RTGI. A reflection proxy may be constructed
    without producing an accurate mirror image in live Evade. Experimental.
    No HTTP, no external files, no hooks, no anti-cheat bypass.

    HOTKEYS:
      RightShift  - show / hide menu
      F7          - turn VEX visuals on / off
      X in GUI    - unload: restores changed properties and removes VEX objects

    USE: execute as CLIENT Luau; in Studio, paste into a LocalScript under
    StarterPlayer > StarterPlayerScripts. No HTTP, assets, remotes or bypasses.
--]]

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
if not player then
    warn("[VEX RTX] This code must run on the client (LocalPlayer is nil).")
    return
end
local playerGui = player:WaitForChild("PlayerGui", 15)
if not playerGui then
    warn("[VEX RTX] PlayerGui not found.")
    return
end

-- Re-running unloads any previous v1 / v2 / v3 registered through either environment.
local globalEnv = _G
local runtime = globalEnv
if type(getgenv) == "function" then
    local ok, candidate = pcall(getgenv)
    if ok and type(candidate) == "table" then runtime = candidate end
end
local previous = globalEnv.VEX_RTX
if type(previous) == "table" and type(previous.Unload) == "function" then
    pcall(previous.Unload)
end
if runtime ~= globalEnv then
    previous = runtime.VEX_RTX
    if type(previous) == "table" and type(previous.Unload) == "function" then
        pcall(previous.Unload)
    end
end

local PREFIX = "VEX_RTX_v50_"
local GUI_NAME = PREFIX .. "GUI"
local connections = {}
local effects = {}
local lightingEdits = {}
local floorEdits = {}
local editedFloors = 0
local unloading = false
local enabled = true
local currentPreset = "RTX+"
local currentTab = "LOOK"
local lastFps = 60
local scanRunning = false
local scanQueued = false
local lastScan = -100

local function connect(signal, callback)
    local c = signal:Connect(callback)
    connections[#connections + 1] = c
    return c
end

local function make(className, props, parent)
    local inst = Instance.new(className)
    for k, v in pairs(props or {}) do inst[k] = v end
    inst.Parent = parent
    return inst
end

local function roundCorner(parent, radius)
    make("UICorner", {CornerRadius = UDim.new(0, radius)}, parent)
end

local function addStroke(parent, color, alpha)
    make("UIStroke", {Color = color, Thickness = 1, Transparency = alpha or 0}, parent)
end

local COLORS = {
    background = Color3.fromRGB(11, 15, 25),
    panel = Color3.fromRGB(19, 26, 39),
    panel2 = Color3.fromRGB(27, 37, 54),
    outline = Color3.fromRGB(48, 65, 84),
    accent = Color3.fromRGB(115, 208, 255),
    white = Color3.fromRGB(245, 250, 255),
    muted = Color3.fromRGB(153, 173, 191),
    green = Color3.fromRGB(90, 226, 170),
    red = Color3.fromRGB(247, 115, 132),
}

local function closeEnough(a, b)
    if type(a) == "number" and type(b) == "number" then
        return math.abs(a - b) < 0.0001
    end
    return a == b
end

local function setLighting(property, value)
    local ok, present = pcall(function() return Lighting[property] end)
    if not ok then return end
    local record = lightingEdits[property]
    if not record then
        record = {original = present}
        lightingEdits[property] = record
    elseif record.last ~= nil and not closeEnough(present, record.last) then
        -- Another game script modified this while VEX was active; rebase.
        record.original = present
    end
    local success = pcall(function() Lighting[property] = value end)
    if success then
        record.last = value
    elseif record.last == nil then
        lightingEdits[property] = nil
    end
end

local function restoreLighting()
    for property, record in pairs(lightingEdits) do
        pcall(function()
            if closeEnough(Lighting[property], record.last) then
                Lighting[property] = record.original
            end
        end)
        lightingEdits[property] = nil
    end
end

local function restoreFloor(part, data)
    if not data then return end
    pcall(function()
        if part and part.Parent then
            if data.lastMaterial and part.Material == data.lastMaterial then
                part.Material = data.material
            end
            if data.lastReflectance and closeEnough(part.Reflectance, data.lastReflectance) then
                part.Reflectance = data.reflectance
            end
            if data.modifiedPhysics and part.CustomPhysicalProperties == data.lastPhysics then
                part.CustomPhysicalProperties = data.originalPhysics
            end
        end
    end)
    floorEdits[part] = nil
    editedFloors = math.max(0, editedFloors - 1)
end

local function restoreFloors()
    for part, data in pairs(floorEdits) do restoreFloor(part, data) end
    editedFloors = 0
end

-- Clean only VEX objects from an interrupted older run; never touch Evade FX.
for _, name in ipairs({"VEX_RTX_v1_GUI", "VEX_RTX_v2_GUI", "VEX_RTX_v3_GUI", "VEX_RTX_v31_GUI", "VEX_RTX_v40_GUI", GUI_NAME}) do
    local orphan = playerGui:FindFirstChild(name)
    if orphan then orphan:Destroy() end
end
for _, oldName in ipairs({
    "VEX_RTX_v1_Bloom", "VEX_RTX_v1_Grade", "VEX_RTX_v1_Rays",
    "VEX_RTX_v1_Depth", "VEX_RTX_v2_Bloom", "VEX_RTX_v2_Grade",
    "VEX_RTX_v2_Rays", "VEX_RTX_v2_Depth", "VEX_RTX_v3_Bloom", "VEX_RTX_v3_Grade",
    "VEX_RTX_v3_Rays", "VEX_RTX_v3_Depth", "VEX_RTX_v31_Bloom", "VEX_RTX_v31_Grade",
    "VEX_RTX_v31_Rays", "VEX_RTX_v31_Depth", "VEX_RTX_v40_Bloom", "VEX_RTX_v40_Grade", "VEX_RTX_v40_Rays", "VEX_RTX_v40_Depth", PREFIX .. "Bloom", PREFIX .. "Grade",
    PREFIX .. "Rays", PREFIX .. "Depth",
}) do
    local orphan = Lighting:FindFirstChild(oldName)
    if orphan then orphan:Destroy() end
end

-- Clean stranded client-only mirror/bounce geometry from this v3 prefix.
for _, oldName in ipairs({"VEX_RTX_v3_MirrorWorld", "VEX_RTX_v3_BounceLights", "VEX_RTX_v31_MirrorWorld", "VEX_RTX_v31_BounceLights",
    "VEX_RTX_v40_MirrorWorld", "VEX_RTX_v40_BounceLights", PREFIX .. "MirrorWorld", PREFIX .. "BounceLights"}) do
    local orphan = Workspace:FindFirstChild(oldName)
    if orphan then orphan:Destroy() end
end

for _, child in ipairs(playerGui:GetChildren()) do
    if child.Name == "VEX_RTX_v40_MirrorSurface" or child.Name == GUI_NAME:gsub("GUI", "MirrorSurface") then
        pcall(function() child:Destroy() end)
    end
end

local bloom = make("BloomEffect", {Name = PREFIX .. "Bloom", Enabled = false}, Lighting)
local grade = make("ColorCorrectionEffect", {Name = PREFIX .. "Grade", Enabled = false}, Lighting)
local rays = make("SunRaysEffect", {Name = PREFIX .. "Rays", Enabled = false}, Lighting)
local depth = make("DepthOfFieldEffect", {Name = PREFIX .. "Depth", Enabled = false}, Lighting)
effects = {bloom, grade, rays, depth}

-- Sliders use a 0..100 UI scale. Neutral contrast/saturation/exposure = 50.
local settings = {
    power = 88,
    bloom = 54,
    contrast = 66,
    saturation = 58,
    sun = 30,
    exposure = 50,
    gloss = 54,
    softness = 57,
    mirrorStrength = 48,
    bounceStrength = 60,
    mirrorQuality = 55,
    cloudCover = 45,
    haze = 40,
}
local toggles = {
    lighting = true, floors = true, dof = false, mirror = false, bounce = true,
    sunset = false, clouds = false, atmosphere = false,
}
local presets = {
    ["RTX+"] = {
        power = 91, bloom = 53, contrast = 65, saturation = 63,
        sun = 58, exposure = 49, gloss = 69, softness = 35,
        mirrorStrength = 58, bounceStrength = 70, mirrorQuality = 58,
        cloudCover = 48, haze = 49,
        lighting = true, floors = true, dof = false, mirror = true, bounce = true,
        sunset = true, clouds = true, atmosphere = true,
        tint = Color3.fromRGB(255, 226, 205),
    },
    Realism = {
        power = 86, bloom = 43, contrast = 64, saturation = 56,
        sun = 30, exposure = 52, gloss = 48, softness = 55, mirrorStrength = 38, bounceStrength = 40, mirrorQuality = 55, cloudCover = 45, haze = 36,
        lighting = true, floors = true, dof = false, mirror = false, bounce = true,
        sunset = false, clouds = false, atmosphere = false,
        tint = Color3.fromRGB(255, 250, 244),
    },
    Neon = {
        power = 92, bloom = 72, contrast = 72, saturation = 78,
        sun = 42, exposure = 55, gloss = 74, softness = 43, mirrorStrength = 55, bounceStrength = 65, mirrorQuality = 55, cloudCover = 35, haze = 42,
        lighting = true, floors = true, dof = false, mirror = false, bounce = true,
        sunset = false, clouds = false, atmosphere = false,
        tint = Color3.fromRGB(249, 230, 255),
    },
    Cinema = {
        power = 84, bloom = 50, contrast = 75, saturation = 43,
        sun = 39, exposure = 46, gloss = 47, softness = 68, mirrorStrength = 30, bounceStrength = 45, mirrorQuality = 50, cloudCover = 30, haze = 48,
        lighting = true, floors = false, dof = false, mirror = false, bounce = true,
        sunset = false, clouds = false, atmosphere = false,
        tint = Color3.fromRGB(255, 242, 227),
    },
    Sunset = {
        power = 90, bloom = 50, contrast = 64, saturation = 63,
        sun = 67, exposure = 48, gloss = 54, softness = 31,
        mirrorStrength = 38, bounceStrength = 35, mirrorQuality = 50, cloudCover = 49, haze = 57,
        lighting = true, floors = false, dof = false, mirror = false, bounce = true,
        sunset = true, clouds = true, atmosphere = true,
        tint = Color3.fromRGB(255, 219, 191),
    },
    Storm = {
        power = 82, bloom = 37, contrast = 70, saturation = 44,
        sun = 8, exposure = 43, gloss = 62, softness = 79,
        mirrorStrength = 48, bounceStrength = 40, mirrorQuality = 42,
        cloudCover = 84, haze = 78,
        lighting = true, floors = true, dof = false, mirror = false, bounce = true,
        sunset = false, clouds = true, atmosphere = true,
        tint = Color3.fromRGB(194, 217, 255),
    },
    Dream = {
        power = 90, bloom = 82, contrast = 54, saturation = 68,
        sun = 28, exposure = 57, gloss = 58, softness = 64,
        mirrorStrength = 50, bounceStrength = 35, mirrorQuality = 50,
        cloudCover = 66, haze = 66,
        lighting = true, floors = true, dof = false, mirror = false, bounce = true,
        sunset = false, clouds = true, atmosphere = true,
        tint = Color3.fromRGB(250, 224, 255),
    },
    FPS = {
        power = 69, bloom = 16, contrast = 58, saturation = 59,
        sun = 0, exposure = 50, gloss = 0, softness = 30, mirrorStrength = 0, bounceStrength = 0, mirrorQuality = 0, cloudCover = 0, haze = 0,
        lighting = false, floors = false, dof = false, mirror = false, bounce = false,
        sunset = false, clouds = false, atmosphere = false,
        tint = Color3.fromRGB(255, 255, 255),
    },
}
local tint = presets.Realism.tint

local function getViewOrigin()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then return root.Position end
    local camera = Workspace.CurrentCamera
    return camera and camera.CFrame.Position or Vector3.zero
end

local EXCLUDE_MATERIAL = {
    [Enum.Material.Neon] = true,
    [Enum.Material.Glass] = true,
    [Enum.Material.ForceField] = true,
    [Enum.Material.Metal] = true,
    [Enum.Material.Grass] = true,
    [Enum.Material.Sand] = true,
    [Enum.Material.Ice] = true,
}

local function isFloor(part)
    if not part:IsA("Part") then return false end
    if not part.Anchored or not part.CanCollide then return false end
    if part.Transparency > 0.05 or EXCLUDE_MATERIAL[part.Material] then return false end
    if part.Shape ~= Enum.PartType.Block then return false end
    local s = part.Size
    if s.X < 7 or s.Z < 7 or s.Y > 8 or s.X * s.Z < 100 then return false end
    if part.CFrame.UpVector.Y < 0.94 then return false end
    if s.Y > math.min(s.X, s.Z) * 0.3 then return false end
    local ok, variant = pcall(function() return part.MaterialVariant end)
    if ok and variant ~= "" then return false end
    if player.Character and part:IsDescendantOf(player.Character) then return false end
    local model = part:FindFirstAncestorOfClass("Model")
    if model and model:FindFirstChildOfClass("Humanoid") then return false end
    local name = string.lower(part.Name)
    local matchesName = name:find("floor", 1, true)
        or name:find("ground", 1, true)
        or name:find("tile", 1, true)
        or name:find("path", 1, true)
        or name:find("road", 1, true)
        or name:find("street", 1, true)
        or name:find("platform", 1, true)
        or name:find("baseplate", 1, true)
        or name:find("sidewalk", 1, true)
    return matchesName or (s.X * s.Z >= 230 and s.Y <= 3)
end

local function targetReflectance()
    return math.clamp(0.035 + (settings.gloss / 100) * 0.20, 0, 0.25)
end

local function polishFloor(part)
    local data = floorEdits[part]
    local desired = targetReflectance()
    if data then
        -- Respect updates from the game; never re-apply over a changed part.
        if (data.lastMaterial and part.Material ~= data.lastMaterial)
            or (data.lastReflectance and not closeEnough(part.Reflectance, data.lastReflectance)) then
            -- Restore our remaining properties, but keep external edits intact.
            restoreFloor(part, data)
            return
        end
        pcall(function()
            part.Reflectance = math.max(data.reflectance, desired)
            data.lastReflectance = part.Reflectance
        end)
        return
    end
    if editedFloors >= 100 or not isFloor(part) then return end

    -- Changing Material alone changes physical friction. Preserve the current
    -- material physics on a per-part basis before changing visual material.
    local before = nil
    local ok, record = pcall(function()
        local originalPhysics = part.CustomPhysicalProperties
        local originalMaterial = part.Material
        local originalReflectance = part.Reflectance
        before = {physics = originalPhysics, material = originalMaterial, reflectance = originalReflectance}
        local livePhysics = part.CurrentPhysicalProperties
        if not livePhysics then return nil end
        local savedPhysics = PhysicalProperties.new(
            livePhysics.Density, livePhysics.Friction, livePhysics.Elasticity,
            livePhysics.FrictionWeight, livePhysics.ElasticityWeight
        )
        part.CustomPhysicalProperties = savedPhysics
        if part.CustomPhysicalProperties ~= savedPhysics then return nil end
        local desiredReflectance = math.max(originalReflectance, desired)
        local newMaterial = Enum.Material.SmoothPlastic
        part.Material = newMaterial
        part.Reflectance = desiredReflectance
        return {
            material = originalMaterial,
            reflectance = originalReflectance,
            originalPhysics = originalPhysics,
            lastPhysics = savedPhysics,
            modifiedPhysics = true,
            lastMaterial = newMaterial,
            lastReflectance = desiredReflectance,
        }
    end)
    if ok and record then
        floorEdits[part] = record
        editedFloors = editedFloors + 1
    elseif before then
        -- Never leave a half-applied physics/material edit on a failed part.
        pcall(function()
            part.Material = before.material
            part.Reflectance = before.reflectance
            part.CustomPhysicalProperties = before.physics
        end)
    end
end

local function refreshFloorSet()
    if unloading then return end
    if not enabled or not toggles.floors or settings.gloss <= 0 then
        restoreFloors()
        return
    end
    local origin = getViewOrigin()
    for part, data in pairs(floorEdits) do
        if not part.Parent or (part.Position - origin).Magnitude > 200 then
            restoreFloor(part, data)
        else
            polishFloor(part)
        end
    end
end

local floorCounter = nil
local function updateFloorCounter()
    if floorCounter and floorCounter.Parent then
        floorCounter.Text = "Polished surfaces: " .. tostring(editedFloors) .. " / 100"
    end
end

local function performScan()
    refreshFloorSet()
    if not enabled or not toggles.floors or settings.gloss <= 0 or unloading then
        updateFloorCounter()
        return
    end
    local parameters = OverlapParams.new()
    parameters.MaxParts = 1800
    local found = nil
    local ok = pcall(function()
        found = Workspace:GetPartBoundsInRadius(getViewOrigin(), 195, parameters)
    end)
    if not ok or not found then
        -- Spatial query unavailable: leave post FX working; avoid costly full-map scans.
        updateFloorCounter()
        return
    end
    for index, part in ipairs(found) do
        if unloading or not enabled or not toggles.floors then break end
        if editedFloors >= 100 then break end
        if isFloor(part) then polishFloor(part) end
        if index % 100 == 0 then task.wait() end
    end
    updateFloorCounter()
end

local function requestScan()
    if unloading then return end
    if scanRunning then
        scanQueued = true
        return
    end
    scanRunning = true
    task.spawn(function()
        repeat
            scanQueued = false
            local ok, err = pcall(performScan)
            if not ok then warn("[VEX RTX] Floor scan error: " .. tostring(err)) end
        until not scanQueued or unloading
        scanRunning = false
    end)
end


--[[ REFLECTION VIEWPORT ---------------------------------------------------
    A floor-mounted SurfaceGui + GPU-rendered ViewportFrame containing local
    visual copies of nearby parts.  The camera is mirrored across the flat
    floor.  This is a planar REFLECTION APPROXIMATION, not RTX/SSR/path tracing.
    No floor transparency edits, no clone physics, no external assets.
    All viewport objects are client-only and cleaned up on unload.
---------------------------------------------------------------------------]]
local mirrorFolder = make("Folder", {Name = PREFIX .. "MirrorWorld"}, Workspace)
local bounceFolder = make("Folder", {Name = PREFIX .. "BounceLights"}, Workspace)
local mirrorGui, mirrorFrame, mirrorCamera, mirrorWorld = nil, nil, nil, nil
local mirrorFloor, mirrorPlaneY = nil, nil
local mirrorCopies = {}
local mirrorCount = 0
local mirrorLastPosition = nil
local mirrorLastBuild = -999
local mirrorStatus = "OFF"
local mirrorBusy = false
local mirrorBuildEpoch = 0

local function rayParams()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local excluded = {mirrorFolder, bounceFolder}
    if player.Character then table.insert(excluded, player.Character) end
    params.FilterDescendantsInstances = excluded
    params.IgnoreWater = true
    return params
end

local function clearMirrorCopies()
    for original, clone in pairs(mirrorCopies) do
        mirrorCopies[original] = nil
        pcall(function() clone:Destroy() end)
    end
    mirrorCount = 0
end

local function clearMirror()
    mirrorBuildEpoch = mirrorBuildEpoch + 1
    mirrorBusy = false
    clearMirrorCopies()
    if mirrorGui then pcall(function() mirrorGui:Destroy() end) end
    mirrorGui, mirrorFrame, mirrorCamera, mirrorWorld = nil, nil, nil, nil
    mirrorFloor, mirrorPlaneY, mirrorLastPosition = nil, nil, nil
    mirrorStatus = "OFF"
end

local function mirrorEligible(part, normal)
    if not part or not part:IsA("BasePart") then return false end
    if not part.Anchored or not part.CanCollide then return false end
    if normal.Y < 0.97 or part.CFrame.UpVector.Y < 0.97 then return false end
    if part.Transparency > 0.65 then return false end
    local size = part.Size
    if size.X < 5 or size.Z < 5 or size.X * size.Z < 35 then return false end
    if size.Y > math.min(size.X, size.Z) * 0.8 then return false end
    return true
end

local function findMirrorFloor()
    local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
    local cam = Workspace.CurrentCamera
    local origin = root and root.Position or (cam and cam.CFrame.Position)
    if not origin then return nil end
    local params = rayParams()
    local excluded = params.FilterDescendantsInstances
    for _ = 1, 5 do
        local hit = Workspace:Raycast(origin + Vector3.new(0, 3, 0), Vector3.new(0, -42, 0), params)
        if not hit or not hit.Instance then return nil end
        if mirrorEligible(hit.Instance, hit.Normal) then
            return hit.Instance, hit.Position.Y
        end
        table.insert(excluded, hit.Instance)
        params.FilterDescendantsInstances = excluded
    end
    return nil
end

local function opacityUpdate()
    if mirrorFrame then
        -- At 60% visibility the overlay remains semi-transparent.
        mirrorFrame.ImageTransparency = math.clamp(0.80 - settings.mirrorStrength * 0.010, 0.04, 0.90)
    end
end

local function createMirrorSurface(floor, height)
    local surface = Instance.new("SurfaceGui")
    surface.Name = PREFIX .. "MirrorSurface"
    surface.Adornee = floor
    surface.Face = Enum.NormalId.Top
    surface.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
    surface.CanvasSize = Vector2.new(640, 640)
    surface.AlwaysOnTop = false
    surface.LightInfluence = 0
    surface.Brightness = 1
    surface.MaxDistance = 190
    surface.Enabled = true
    surface.Parent = playerGui -- important: ViewportFrame inside SurfaceGui needs PlayerGui

    local frame = make("ViewportFrame", {
        Name = "ReflectionViewport",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Ambient = Color3.fromRGB(190, 195, 214),
        LightColor = Color3.fromRGB(255, 237, 216),
        LightDirection = Vector3.new(-0.45, -1, -0.55),
    }, surface)
    local world = make("WorldModel", {Name = "ReflectionObjects"}, frame)
    local camera = make("Camera", {Name = "ReflectionCamera"}, frame)
    frame.CurrentCamera = camera
    mirrorGui, mirrorFrame, mirrorCamera, mirrorWorld = surface, frame, camera, world
    mirrorFloor, mirrorPlaneY = floor, height
    mirrorStatus = "SURFACE READY"
    opacityUpdate()
end

local function updateMirrorCamera()
    if not mirrorCamera or not mirrorPlaneY then return end
    local cam = Workspace.CurrentCamera
    if not cam then return end
    local cf = cam.CFrame
    local pos, look, up = cf.Position, cf.LookVector, cf.UpVector
    local reflectedPos = Vector3.new(pos.X, 2 * mirrorPlaneY - pos.Y, pos.Z)
    local reflectedLook = Vector3.new(look.X, -look.Y, look.Z)
    local reflectedUp = Vector3.new(up.X, -up.Y, up.Z)
    mirrorCamera.CFrame = CFrame.lookAt(reflectedPos, reflectedPos + reflectedLook, reflectedUp)
    mirrorCamera.FieldOfView = cam.FieldOfView
end

local function makeViewClone(source)
    local clone
    local ok, result = pcall(function() return source:Clone() end)
    if ok then clone = result end
    if not clone then
        clone = Instance.new("Part")
        clone.Size = source.Size
        clone.Color = source.Color
        clone.Material = source.Material
    end
    -- Sanitize BEFORE parenting. Only render-related children are retained.
    for _, child in ipairs(clone:GetDescendants()) do
        if not (child:IsA("SpecialMesh") or child:IsA("DataModelMesh")
            or child:IsA("Decal") or child:IsA("Texture")
            or child:IsA("SurfaceAppearance")) then
            pcall(function() child:Destroy() end)
        end
    end
    clone.Name = "VEX_ReflectionVisual"
    clone.Anchored = true
    clone.CanCollide, clone.CanTouch, clone.CanQuery = false, false, false
    clone.CastShadow = false
    clone.Reflectance = 0
    clone.CFrame = source.CFrame
    clone.Parent = mirrorWorld
    return clone
end

local function syncMirrorObjects()
    if not mirrorWorld then return end
    for source, clone in pairs(mirrorCopies) do
        if not source.Parent or not clone.Parent then
            mirrorCopies[source] = nil
            if clone.Parent then clone:Destroy() end
            mirrorCount = math.max(0, mirrorCount - 1)
        elseif not source.Anchored then
            pcall(function()
                clone.CFrame = source.CFrame
                clone.Transparency = source.Transparency
            end)
        end
    end
end

local function rebuildMirrorCopies()
    if mirrorBusy or not mirrorWorld or not mirrorFloor then return end
    mirrorBusy = true
    local buildEpoch = mirrorBuildEpoch
    local ok, err = pcall(function()
        clearMirrorCopies()
        local pos = getViewOrigin()
        local radius = 58 + settings.mirrorQuality * 0.72
        local limit = math.floor(30 + settings.mirrorQuality * 1.06)
        local options = OverlapParams.new()
        options.FilterType = Enum.RaycastFilterType.Exclude
        options.FilterDescendantsInstances = {mirrorFolder, bounceFolder}
        options.MaxParts = 1400
        local parts = Workspace:GetPartBoundsInRadius(pos, radius, options)
        local ranked = {}
        for _, part in ipairs(parts) do
            if part:IsA("BasePart") and part ~= mirrorFloor
                and part.Transparency < 0.80 and part.Size.Magnitude < 320
                and part.Position.Y + part.Size.Y / 2 > mirrorPlaneY - 1
                and part.Size.Magnitude > 0.4 then
                local m = part:FindFirstAncestorOfClass("Model")
                local isCharacter = m and m:FindFirstChildOfClass("Humanoid") ~= nil
                local distance = (part.Position - pos).Magnitude
                ranked[#ranked + 1] = {
                    part = part, score = distance + (isCharacter and -100 or 0)
                }
            end
        end
        table.sort(ranked, function(a, b) return a.score < b.score end)
        for i = 1, math.min(limit, #ranked) do
            if unloading or not enabled or not toggles.mirror or not mirrorWorld
                or buildEpoch ~= mirrorBuildEpoch then break end
            local src = ranked[i].part
            local success, clone = pcall(makeViewClone, src)
            if success and clone then
                mirrorCopies[src] = clone
                mirrorCount = mirrorCount + 1
            end
            if i % 25 == 0 then task.wait() end
        end
        mirrorLastPosition, mirrorLastBuild = pos, os.clock()
        mirrorStatus = mirrorCount > 0 and "PROXIES READY" or "NO PROXY PARTS"
    end)
    mirrorBusy = false
    if not ok then
        mirrorStatus = "RENDER ERROR"
        warn("[VEX RTX] Reflection viewport: " .. tostring(err))
    end
end

local function updateMirrorFloor()
    if unloading or not enabled or not toggles.mirror or settings.mirrorStrength == 0 then
        if mirrorGui then clearMirror() end
        return
    end
    local floor, height = findMirrorFloor()
    if not floor then
        if mirrorGui then clearMirror() end
        mirrorStatus = "NO SUITABLE FLAT FLOOR"
        return
    end
    if floor ~= mirrorFloor or not mirrorGui or not mirrorGui.Parent then
        clearMirror()
        local ok, err = pcall(createMirrorSurface, floor, height)
        if not ok then
            mirrorStatus = "SURFACE ERROR"
            warn("[VEX RTX] SurfaceGui creation: " .. tostring(err))
            clearMirror()
            mirrorStatus = "SURFACE ERROR"
            return
        end
    end
    opacityUpdate()
    updateMirrorCamera()
    if not mirrorLastPosition or (getViewOrigin() - mirrorLastPosition).Magnitude > 24
        or os.clock() - mirrorLastBuild > 7 then
        rebuildMirrorCopies()
    end
end

local function moveMirrorCopies()
    syncMirrorObjects()
    updateMirrorCamera()
end

-- Raycast-assisted *bounce-light approximation*, not true global illumination.
-- Samples surrounding floor colors and sunlight visibility to tint up to
-- three small client-only point lights. Off / unload destroys all emitters.
local bounceNodes = {}
local function clearBounce()
    for _, part in ipairs(bounceNodes) do
        if part then pcall(function() part:Destroy() end) end
    end
    table.clear(bounceNodes)
end

local function updateBounce()
    if unloading or not enabled or not toggles.bounce or settings.bounceStrength <= 0 then
        if #bounceNodes > 0 then clearBounce() end
        return
    end
    local origin = getViewOrigin()
    local params = rayParams()
    local offsets = {
        Vector3.new(0, 0, 0), Vector3.new(11, 0, 0), Vector3.new(-11, 0, 0),
        Vector3.new(0, 0, 11), Vector3.new(0, 0, -11)
    }
    local sunDirection = Lighting:GetSunDirection()
    for index, offset in ipairs(offsets) do
        local hit = Workspace:Raycast(origin + offset + Vector3.new(0, 5, 0), Vector3.new(0, -24, 0), params)
        local node = bounceNodes[index]
        if hit and hit.Instance and hit.Instance:IsA("BasePart") and hit.Normal.Y > 0.3 then
            if not node then
                node = make("Part", {
                    Name = "BounceProbe", Size = Vector3.new(0.2, 0.2, 0.2),
                    Transparency = 1, Anchored = true, CanCollide = false,
                    CanTouch = false, CanQuery = false, CastShadow = false,
                }, bounceFolder)
                make("PointLight", {Range = 19, Shadows = false}, node)
                bounceNodes[index] = node
            end
            local sunBlocked = Workspace:Raycast(hit.Position + hit.Normal * 0.35,
                sunDirection * 160, params) ~= nil
            node.Position = hit.Position + hit.Normal * 2
            local light = node:FindFirstChildOfClass("PointLight")
            if light then
                light.Color = hit.Instance.Color:Lerp(Color3.new(1, 1, 1), 0.28)
                light.Brightness = (sunBlocked and 0.18 or 0.78) * settings.bounceStrength / 100
                light.Enabled = true
            end
        elseif node then
            local light = node:FindFirstChildOfClass("PointLight")
            if light then light.Enabled = false end
        end
    end
end

-- Reversible sky edits: modify only while a sky setting is on.
-- If the game changes a touched property while VEX runs, preserve the game change.
local skyEdits = {}
local skyCreated = {}
local function skySet(inst, prop, target)
    if not inst or not inst.Parent then return end
    local ok, before = pcall(function() return inst[prop] end)
    if not ok then return end
    local record = skyEdits[inst]
    if not record then
        record = {}
        skyEdits[inst] = record
    end
    local entry = record[prop]
    if not entry then
        entry = {before = before}
        record[prop] = entry
    elseif entry.last ~= nil and not closeEnough(before, entry.last) then
        entry.before = before
    end
    local success = pcall(function() inst[prop] = target end)
    if success then entry.last = target end
end

local function skyRestore(inst)
    local record = skyEdits[inst]
    if not record then return end
    for prop, entry in pairs(record) do
        pcall(function()
            if inst and inst.Parent and entry.last ~= nil
                and closeEnough(inst[prop], entry.last) then
                inst[prop] = entry.before
            end
        end)
    end
    skyEdits[inst] = nil
end

local function getSkyObject(parent, className)
    local obj = parent:FindFirstChildOfClass(className)
    if obj then return obj end
    local created = nil
    local ok, result = pcall(function()
        local newObj = Instance.new(className)
        newObj.Name = PREFIX .. className
        newObj.Parent = parent
        return newObj
    end)
    if ok then created = result end
    if created then skyCreated[className] = created end
    return created
end

local function stopSkyObject(parent, className)
    local obj = parent:FindFirstChildOfClass(className)
    if obj then skyRestore(obj) end
    local created = skyCreated[className]
    if created then
        pcall(function() created:Destroy() end)
        skyCreated[className] = nil
    end
end

local SUNSET_KEYS = {
    "ClockTime", "Brightness", "Ambient", "OutdoorAmbient",
    "ColorShift_Top", "ColorShift_Bottom", "ExposureCompensation",
}
local function restoreSunsetKeys()
    for _, key in ipairs(SUNSET_KEYS) do
        local record = lightingEdits[key]
        if record then
            pcall(function()
                if record.last ~= nil and closeEnough(Lighting[key], record.last) then
                    Lighting[key] = record.original
                end
            end)
            lightingEdits[key] = nil
        end
    end
end

local function applySky(on)
    local activeSunset = on and toggles.sunset
    if activeSunset then
        -- Low sun = long native Roblox shadows. Video-inspired, NOT RT shadows.
        setLighting("ClockTime", 17.45)
        setLighting("Brightness", 2.25)
        setLighting("Ambient", Color3.fromRGB(65, 59, 69))
        setLighting("OutdoorAmbient", Color3.fromRGB(153, 141, 140))
        setLighting("ColorShift_Top", Color3.fromRGB(255, 214, 179))
        setLighting("ColorShift_Bottom", Color3.fromRGB(89, 88, 112))
        setLighting("ExposureCompensation", -0.065)
    else
        restoreSunsetKeys()
    end

    -- Atmospheric scattering works independently of changing the world time.
    -- Soft neutral haze when Golden Hour is OFF, preserving Evade's time of day.
    if on and (toggles.atmosphere or activeSunset) then
        local atmo = getSkyObject(Lighting, "Atmosphere")
        if atmo then
            skySet(atmo, "Density", activeSunset and (0.17 + settings.haze / 100 * 0.17)
                or (0.10 + settings.haze / 100 * 0.18))
            skySet(atmo, "Haze", 0.35 + settings.haze / 100 * 1.85)
            skySet(atmo, "Glare", activeSunset and (0.22 + settings.sun / 100 * 1.15)
                or (0.04 + settings.sun / 100 * 0.46))
            skySet(atmo, "Offset", 0.09)
            skySet(atmo, "Color", activeSunset and Color3.fromRGB(244, 206, 177)
                or tint:Lerp(Color3.fromRGB(225, 231, 242), 0.55))
            skySet(atmo, "Decay", activeSunset and Color3.fromRGB(196, 149, 132)
                or Color3.fromRGB(174, 181, 196))
        end
    else
        stopSkyObject(Lighting, "Atmosphere")
    end

    local terrain = Workspace:FindFirstChildOfClass("Terrain")
    if terrain and on and toggles.clouds then
        local clouds = getSkyObject(terrain, "Clouds")
        if clouds then
            skySet(clouds, "Enabled", true)
            skySet(clouds, "Cover", math.clamp(0.12 + settings.cloudCover / 100 * 0.66, 0, 1))
            skySet(clouds, "Density", activeSunset and 0.48 or 0.40)
            skySet(clouds, "Color", activeSunset and Color3.fromRGB(255, 222, 191)
                or Color3.fromRGB(235, 240, 255))
        end
    elseif terrain then
        stopSkyObject(terrain, "Clouds")
    end
end

local function apply()
    if unloading then return end
    local factor = settings.power / 100
    local on = enabled and factor > 0
    bloom.Intensity = math.clamp(settings.bloom / 100 * 0.75 * factor, 0, 1)
    bloom.Size = math.floor(22 + settings.bloom / 100 * 34)
    bloom.Threshold = 0.95
    bloom.Enabled = on and settings.bloom > 0

    grade.Contrast = (settings.contrast - 50) / 50 * 0.37 * factor
    grade.Saturation = (settings.saturation - 50) / 50 * 0.48 * factor
    grade.Brightness = (settings.exposure - 50) / 50 * 0.075 * factor
    grade.TintColor = Color3.new(1, 1, 1):Lerp(tint, factor)
    grade.Enabled = on

    rays.Intensity = settings.sun / 100 * 0.14 * factor
    rays.Spread = 0.80
    rays.Enabled = on and settings.sun > 0

    depth.FocusDistance = 70
    depth.InFocusRadius = 62
    depth.NearIntensity = 0
    depth.FarIntensity = 0.075 * factor
    depth.Enabled = on and toggles.dof

    if on and toggles.lighting then
        setLighting("EnvironmentSpecularScale", math.clamp(0.38 + settings.gloss / 100 * 0.55 * factor, 0, 1))
        setLighting("EnvironmentDiffuseScale", math.clamp(0.24 + 0.38 * factor, 0, 1))
        setLighting("ShadowSoftness", math.clamp(0.13 + settings.softness / 100 * 0.60, 0, 1))
        setLighting("GlobalShadows", true)
        -- On clients where this property is writable, use advanced lighting.
        pcall(function()
            if Enum.LightingStyle and Enum.LightingStyle.Realistic then
                setLighting("LightingStyle", Enum.LightingStyle.Realistic)
            end
        end)
    else
        restoreLighting()
    end

    if not on or not toggles.floors or settings.gloss <= 0 then
        restoreFloors()
        updateFloorCounter()
    else
        requestScan()
    end
    applySky(on)
    if not on or not toggles.mirror then
        clearMirror()
    elseif mirrorFrame then
        opacityUpdate()
    end
    if not on or not toggles.bounce then clearBounce() end
end

-- UI: fixed designer canvas with a UIScale for smaller Roblox windows.
local gui = make("ScreenGui", {
    Name = GUI_NAME,
    ResetOnSpawn = false,
    IgnoreGuiInset = false,
    DisplayOrder = 400,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)
local panel = make("Frame", {
    Name = "VEXWindow",
    Size = UDim2.fromOffset(470, 600),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundColor3 = COLORS.background,
    BorderSizePixel = 0,
    Active = true,
}, gui)
roundCorner(panel, 15)
addStroke(panel, COLORS.outline, 0.10)
local panelScale = make("UIScale", {Scale = 1}, panel)

local function adjustScale()
    local camera = Workspace.CurrentCamera
    if not camera then return end
    local v = camera.ViewportSize
    panelScale.Scale = math.clamp(math.min(v.X / 505, v.Y / 655), 0.55, 1)
end
adjustScale()
local cameraConn = nil
local function bindCamera()
    if cameraConn then cameraConn:Disconnect() end
    local camera = Workspace.CurrentCamera
    if camera then
        cameraConn = connect(camera:GetPropertyChangedSignal("ViewportSize"), adjustScale)
    end
    adjustScale()
end
bindCamera()
connect(Workspace:GetPropertyChangedSignal("CurrentCamera"), bindCamera)

local function textLabel(parent, value, x, y, w, h, size, color, bold)
    return make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(x, y),
        Size = UDim2.fromOffset(w, h),
        Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham,
        Text = value,
        TextColor3 = color or COLORS.white,
        TextSize = size or 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    }, parent)
end

local function clickable(parent, value, x, y, w, h)
    local btn = make("TextButton", {
        Position = UDim2.fromOffset(x, y),
        Size = UDim2.fromOffset(w, h),
        BackgroundColor3 = COLORS.panel2,
        BorderSizePixel = 0,
        Text = value,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = COLORS.white,
        AutoButtonColor = true,
    }, parent)
    roundCorner(btn, 8)
    return btn
end

textLabel(panel, "VEX", 18, 12, 54, 27, 23, COLORS.accent, true)
textLabel(panel, "RTX", 74, 12, 57, 27, 23, COLORS.white, true)
textLabel(panel, "EVADE EDITION  /  5.0  |  GITHUB RELEASE", 19, 40, 260, 15, 10, COLORS.muted, true)
local onButton = clickable(panel, "ON", 332, 17, 72, 32)
local hideButton = clickable(panel, "_", 413, 17, 20, 32)
local exitButton = clickable(panel, "X", 440, 17, 20, 32)
exitButton.TextColor3 = COLORS.red

make("Frame", {Position = UDim2.fromOffset(18, 61), Size = UDim2.fromOffset(434, 1), BackgroundColor3 = COLORS.outline, BorderSizePixel = 0}, panel)
local tabButtons = {}
local tabs = {"LOOK", "WORLD", "RTX LAB", "ABOUT"}
local tabWidth = 102
for i, name in ipairs(tabs) do
    local btn = clickable(panel, name, 18 + (i - 1) * 110, 71, tabWidth, 34)
    tabButtons[name] = btn
end

local statusPanel = make("Frame", {
    Position = UDim2.fromOffset(18, 114), Size = UDim2.fromOffset(434, 35),
    BackgroundColor3 = COLORS.panel, BorderSizePixel = 0,
}, panel)
roundCorner(statusPanel, 8)
local dot = make("Frame", {Position = UDim2.fromOffset(12, 13), Size = UDim2.fromOffset(9, 9), BackgroundColor3 = COLORS.green, BorderSizePixel = 0}, statusPanel)
roundCorner(dot, 5)
local statusText = textLabel(statusPanel, "", 30, 4, 392, 27, 12, COLORS.muted)

local content = make("Frame", {
    Position = UDim2.fromOffset(18, 158), Size = UDim2.fromOffset(434, 375),
    BackgroundTransparency = 1,
}, panel)
local pages = {}
for _, name in ipairs(tabs) do
    local page = make("ScrollingFrame", {
        Name = name,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromScale(1, 1),
        CanvasSize = UDim2.fromOffset(0, name == "LOOK" and 625 or 385),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COLORS.outline,
        Visible = name == "LOOK",
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, content)
    pages[name] = page
end

local footLine = make("Frame", {Position = UDim2.fromOffset(18, 546), Size = UDim2.fromOffset(434, 1), BackgroundColor3 = COLORS.outline, BorderSizePixel = 0}, panel)
local fpsText = textLabel(panel, "FPS: --", 19, 553, 110, 20, 11, COLORS.muted)
textLabel(panel, "RightShift: GUI  |  F7: FX  |  X: Unload", 130, 552, 321, 21, 10, COLORS.muted)
local eventStatus = textLabel(panel, "UI ready | Press a tab to check input", 19, 573, 420, 16, 10, COLORS.muted)

local presetButtons = {}
local sliderUis = {}
local toggleUis = {}
local activeSlider = nil
local activePointer = nil
local windowDragging = false
local dragPointer = nil
local dragMouse = nil
local dragFrom = nil

local function refreshUI()
    onButton.Text = enabled and "ON" or "OFF"
    onButton.BackgroundColor3 = enabled and COLORS.green or COLORS.panel2
    onButton.TextColor3 = enabled and COLORS.background or COLORS.red
    dot.BackgroundColor3 = enabled and COLORS.green or COLORS.red
    statusText.Text = enabled
        and ("ACTIVE  |  " .. string.upper(currentPreset) .. "  |  " .. tostring(editedFloors) .. " polished")
        or "PAUSED  |  original Evade visuals restored"
    for name, btn in pairs(presetButtons) do
        local selected = name == currentPreset
        btn.BackgroundColor3 = selected and COLORS.accent or COLORS.panel2
        btn.TextColor3 = selected and COLORS.background or COLORS.white
    end
    for key, u in pairs(sliderUis) do
        local amount = settings[key]
        u.fill.Size = UDim2.fromScale(amount / 100, 1)
        u.value.Text = tostring(amount) .. "%"
    end
    for key, u in pairs(toggleUis) do
        local state = toggles[key]
        u.button.Text = state and "ON" or "OFF"
        u.button.BackgroundColor3 = state and COLORS.accent or COLORS.panel2
        u.button.TextColor3 = state and COLORS.background or COLORS.muted
    end
    for name, btn in pairs(tabButtons) do
        local isCurrent = name == currentTab
        btn.BackgroundColor3 = isCurrent and COLORS.accent or COLORS.panel
        btn.TextColor3 = isCurrent and COLORS.background or COLORS.muted
        pages[name].Visible = isCurrent
    end
    updateFloorCounter()
end

-- Register critical controls BEFORE building detailed page contents.
-- An error in one page must not leave the whole visible GUI without handlers.
local guiClicks = 0
local function bindButton(button, action)
    local lastTap = -100
    local function onTap()
        if unloading then return end
        local now = os.clock()
        if now - lastTap < 0.14 then return end
        lastTap = now
        guiClicks = guiClicks + 1
        eventStatus.Text = "UI input OK  #" .. tostring(guiClicks) .. "  |  " .. button.Text
        local success, err = pcall(action)
        if not success then
            eventStatus.Text = "UI handler error: " .. string.sub(tostring(err), 1, 56)
            warn("[VEX RTX] GUI: " .. tostring(err))
        end
    end
    connect(button.Activated, onTap)
    connect(button.MouseButton1Click, onTap)
end

for _, name in ipairs(tabs) do
    bindButton(tabButtons[name], function()
        currentTab = name
        refreshUI()
    end)
end
bindButton(onButton, function()
    enabled = not enabled
    apply()
    refreshUI()
end)
bindButton(hideButton, function() gui.Enabled = false end)
local unload  -- assigned after the remaining components are constructed
bindButton(exitButton, function()
    if unload then unload() else gui:Destroy() end
end)

local function selectPreset(name)
    if unloading then return end
    local p = presets[name]
    if not p then return end
    currentPreset = name
    for key, old in pairs(settings) do
        if p[key] ~= nil then settings[key] = p[key] end
    end
    for key in pairs(toggles) do toggles[key] = p[key] end
    tint = p.tint
    apply()
    refreshUI()
    if toggles.mirror and enabled then
        task.spawn(function()
            if not unloading then pcall(updateMirrorFloor) end
        end)
    end
end

local function setSliderValue(key, amount)
    if unloading then return end
    local n = math.clamp(math.floor(amount + 0.5), 0, 100)
    if settings[key] == n then return end
    settings[key] = n
    currentPreset = "Custom"
    apply()
    refreshUI()
end

local function slider(page, key, title, y)
    textLabel(page, title, 3, y, 310, 20, 13, COLORS.white, false)
    local readout = textLabel(page, "0%", 357, y, 60, 20, 12, COLORS.accent, true)
    readout.TextXAlignment = Enum.TextXAlignment.Right
    local bar = make("Frame", {
        Position = UDim2.fromOffset(4, y + 30),
        Size = UDim2.fromOffset(414, 7),
        BackgroundColor3 = COLORS.panel2,
        BorderSizePixel = 0,
    }, page)
    roundCorner(bar, 4)
    local fill = make("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = COLORS.accent, BorderSizePixel = 0}, bar)
    roundCorner(fill, 4)
    local thumb = make("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(1, 0.5),
        Size = UDim2.fromOffset(13, 13), BackgroundColor3 = COLORS.white,
        BorderSizePixel = 0,
    }, fill)
    roundCorner(thumb, 7)
    local hit = make("TextButton", {
        Position = UDim2.fromOffset(0, y + 21), Size = UDim2.fromOffset(424, 26),
        BackgroundTransparency = 1, BorderSizePixel = 0, Text = "",
        AutoButtonColor = false,
    }, page)
    local u = {value = readout, fill = fill, bar = bar, key = key}
    sliderUis[key] = u
    connect(hit.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            activeSlider = u
            activePointer = input
            local x = input.Position.X
            local width = bar.AbsoluteSize.X
            if width > 0 then
                setSliderValue(key, (x - bar.AbsolutePosition.X) / width * 100)
            end
        end
    end)
end

local mirrorReport = nil
local pageBuildOK, pageBuildError = pcall(function()
local lookPage = pages.LOOK
textLabel(lookPage, "VISUAL PRESETS", 3, 4, 275, 22, 11, COLORS.muted, true)
for i, name in ipairs({"RTX+", "Realism", "Neon", "Cinema", "Sunset", "Storm", "Dream", "FPS"}) do
    local column = (i - 1) % 4
    local row = math.floor((i - 1) / 4)
    local b = clickable(lookPage, string.upper(name), 3 + column * 105, 32 + row * 43, 100, 36)
    presetButtons[name] = b
    bindButton(b, function() selectPreset(name) end)
end
textLabel(lookPage, "Color, glow and sunlight. No third-party code is downloaded.", 4, 126, 418, 21, 11, COLORS.muted)
slider(lookPage, "power", "Overall intensity", 160)
slider(lookPage, "bloom", "Bloom / light glow", 224)
slider(lookPage, "contrast", "Contrast (50 = neutral)", 288)
slider(lookPage, "saturation", "Saturation (50 = neutral)", 352)
slider(lookPage, "sun", "Sun rays", 416)
slider(lookPage, "exposure", "Exposure (50 = neutral)", 480)
lookPage.CanvasSize = UDim2.fromOffset(0, 600)

local worldPage = pages.WORLD
textLabel(worldPage, "WORLD & SURFACE SETTINGS", 3, 4, 380, 21, 11, COLORS.muted, true)

local function toggleRow(targetPage, key, title, description, y)
    local bg = make("Frame", {
        Position = UDim2.fromOffset(2, y), Size = UDim2.fromOffset(416, 68),
        BackgroundColor3 = COLORS.panel, BorderSizePixel = 0,
    }, targetPage)
    roundCorner(bg, 8)
    textLabel(bg, title, 12, 8, 298, 24, 13, COLORS.white, true)
    textLabel(bg, description, 12, 34, 295, 21, 10, COLORS.muted)
    local btn = clickable(bg, "OFF", 332, 18, 70, 30)
    toggleUis[key] = {button = btn}
    bindButton(btn, function()
        toggles[key] = not toggles[key]
        currentPreset = "Custom"
        apply()
        refreshUI()
        if key == "mirror" and toggles.mirror then
            task.spawn(function()
                if not unloading then pcall(updateMirrorFloor) end
            end)
        end
    end)
end

toggleRow(worldPage, "lighting", "Enhanced lighting", "Environment highlights and softer shadows", 29)
toggleRow(worldPage, "floors", "Glossy floor [TEST]", "Surface shine, not screen-space reflection", 108)
toggleRow(worldPage, "dof", "Distance blur", "Leave OFF for fast gameplay", 187)
toggleRow(worldPage, "sunset", "Golden hour lighting", "Low sun, warm tone, longer real game shadows", 266)
toggleRow(worldPage, "clouds", "Dynamic clouds", "Roblox clouds; map support varies", 345)
toggleRow(worldPage, "atmosphere", "Atmospheric scattering", "Fog, haze and subtle light diffusion", 424)
slider(worldPage, "gloss", "Gloss intensity", 518)
slider(worldPage, "softness", "Shadow softness", 582)
slider(worldPage, "cloudCover", "Cloud coverage", 646)
slider(worldPage, "haze", "Atmosphere / haze", 710)
worldPage.CanvasSize = UDim2.fromOffset(0, 932)
floorCounter = textLabel(worldPage, "Polished surfaces: 0 / 100", 3, 780, 280, 24, 11, COLORS.muted)
local rescanButton = clickable(worldPage, "SCAN NEARBY", 296, 780, 123, 29)
bindButton(rescanButton, requestScan)
textLabel(worldPage, "Use RTX+ or Sunset for the warm look from the video.", 4, 820, 417, 20, 11, COLORS.muted)
textLabel(worldPage, "Evade can override its lighting during gameplay.", 4, 846, 417, 20, 11, COLORS.muted)
textLabel(worldPage, "Changed properties restored when possible on unload.", 4, 873, 417, 20, 11, COLORS.muted)

local labPage = pages["RTX LAB"]
textLabel(labPage, "EXPERIMENTAL REFLECTION / LIGHT PROBES", 3, 3, 413, 24, 12, COLORS.accent, true)
textLabel(labPage, "Experimental overlay, not shader-level ray tracing.", 3, 26, 416, 21, 11, COLORS.muted)
toggleRow(labPage, "mirror", "Viewport reflections [BETA]", "Renders nearby objects on floor (not true RTX)", 55)
toggleRow(labPage, "bounce", "Raycast bounce lights", "Small colored lights sampled from nearby surfaces", 132)
slider(labPage, "mirrorStrength", "Mirror visibility", 216)
slider(labPage, "bounceStrength", "Bounce light strength", 282)
slider(labPage, "mirrorQuality", "Reflection scene detail", 348)
mirrorReport = textLabel(labPage, "Reflection: OFF", 3, 422, 267, 23, 11, COLORS.muted)
local refreshMirrorButton = clickable(labPage, "REFRESH MIRROR", 275, 419, 140, 29)
bindButton(refreshMirrorButton, function()
    task.spawn(function()
        if unloading then return end
        clearMirror()
        local success, err = pcall(updateMirrorFloor)
        if not success then mirrorStatus = "REFRESH ERROR"; warn("[VEX RTX] Refresh: " .. tostring(err)) end
        if eventStatus and eventStatus.Parent then
            eventStatus.Text = "Reflection: " .. mirrorStatus
        end
    end)
end)
textLabel(labPage, "Builds local 3D proxies of nearby visible objects.", 3, 450, 417, 20, 11, COLORS.muted)
textLabel(labPage, "Overlaid mirror view may be skewed, blank or distorted.", 3, 475, 417, 20, 11, COLORS.muted)
textLabel(labPage, "Use Refresh Mirror after changing locations in Evade.", 3, 500, 417, 20, 11, COLORS.muted)
labPage.CanvasSize = UDim2.fromOffset(0, 550)

local aboutPage = pages.ABOUT
textLabel(aboutPage, "VEX RTX / EVADE EDITION", 4, 4, 415, 36, 19, COLORS.accent, true)
textLabel(aboutPage, "Version 5.0  |  eight looks + atmospheric scattering", 4, 39, 408, 22, 12, COLORS.white)
textLabel(aboutPage, "What you get:", 4, 84, 408, 24, 14, COLORS.white, true)
textLabel(aboutPage, "Bloom, color grading, sunsets, clouds, atmospheric haze.", 4, 110, 417, 24, 12, COLORS.muted)
textLabel(aboutPage, "Gloss, experimental mirror overlays and raycast light probes.", 4, 135, 417, 24, 12, COLORS.muted)
textLabel(aboutPage, "What you do NOT get:", 4, 183, 409, 24, 14, COLORS.white, true)
textLabel(aboutPage, "No hardware ray tracing, SSR or accurate global illumination.", 4, 211, 418, 24, 12, COLORS.muted)
textLabel(aboutPage, "No anti-cheat bypass or injected rendering DLL.", 4, 237, 418, 24, 12, COLORS.muted)
textLabel(aboutPage, "Controls:", 4, 286, 407, 24, 14, COLORS.white, true)
textLabel(aboutPage, "RightShift = menu  |  F7 = all VEX effects", 4, 313, 413, 22, 12, COLORS.muted)
textLabel(aboutPage, "X = restore original visuals and unload", 4, 338, 415, 22, 12, COLORS.muted)

end) -- detailed page construction guarded by pcall
if not pageBuildOK then
    warn("[VEX RTX] Page construction failed; navigation remains operational: " .. tostring(pageBuildError))
    eventStatus.Text = "Page error: " .. string.sub(tostring(pageBuildError), 1, 62)
end

unload = function()
    if unloading then return end
    unloading = true
    for _, c in ipairs(connections) do
        if c.Connected then c:Disconnect() end
    end
    clearMirror()
    clearBounce()
    if mirrorFolder and mirrorFolder.Parent then mirrorFolder:Destroy() end
    if bounceFolder and bounceFolder.Parent then bounceFolder:Destroy() end
    restoreFloors()
    applySky(false)
    restoreSunsetKeys()
    for inst in pairs(skyEdits) do skyRestore(inst) end
    for className, obj in pairs(skyCreated) do
        pcall(function() obj:Destroy() end)
        skyCreated[className] = nil
    end
    restoreLighting()
    for _, fx in ipairs(effects) do
        if fx and fx.Parent then fx:Destroy() end
    end
    if gui and gui.Parent then gui:Destroy() end
    if runtime.VEX_RTX and runtime.VEX_RTX.Unload == unload then
        runtime.VEX_RTX = nil
    end
    if globalEnv.VEX_RTX and globalEnv.VEX_RTX.Unload == unload then
        globalEnv.VEX_RTX = nil
    end
    print("[VEX RTX] v5.0 unloaded; touched properties restored when unchanged by game.")
end

local api = {
    Version = "5.0",
    Unload = unload,
    SetPreset = selectPreset,
    SetFeature = function(key, value)
        if unloading or toggles[key] == nil or type(value) ~= "boolean" then return false end
        toggles[key] = value
        currentPreset = "Custom"
        apply()
        refreshUI()
        if key == "mirror" and value then task.spawn(function() pcall(updateMirrorFloor) end) end
        return true
    end,
    SetValue = function(key, value)
        if unloading or settings[key] == nil or type(value) ~= "number" then return false end
        setSliderValue(key, value)
        return true
    end,
    SetTab = function(name)
        if pages[name] then
            currentTab = name
            refreshUI()
            return true
        end
        return false
    end,
    GetState = function()
        return {enabled = enabled, tab = currentTab, preset = currentPreset,
            guiClicks = guiClicks, mirrorStatus = mirrorStatus, proxies = mirrorCount,
            mirror = toggles.mirror, bounce = toggles.bounce,
            reflectionRenderer = "ViewportFrame", mirrorQuality = settings.mirrorQuality,
            sunset = toggles.sunset, clouds = toggles.clouds,
            atmosphere = toggles.atmosphere, lookSettings = settings}
    end,
    Show = function() if not unloading then gui.Enabled = true end end,
    Hide = function() if not unloading then gui.Enabled = false end end,
    UpdateReflection = function()
        local ok, err = pcall(updateMirrorFloor)
        return ok, err, mirrorStatus
    end,
    Toggle = function()
        if unloading then return end
        enabled = not enabled
        apply()
        refreshUI()
    end,
}
runtime.VEX_RTX = api
globalEnv.VEX_RTX = api

-- Exit button bound immediately after core UI creation.

-- Drag only by the left side of the header (never over control buttons).
local dragHandle = make("TextButton", {
    Position = UDim2.fromOffset(0, 0), Size = UDim2.fromOffset(310, 60),
    BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
}, panel)
connect(dragHandle.InputBegan, function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
    windowDragging = true
    dragPointer = input
    dragMouse = input.Position
    dragFrom = panel.Position
end)

connect(UserInputService.InputChanged, function(input)
    if unloading then return end
    local isMouse = input.UserInputType == Enum.UserInputType.MouseMovement
    local isTouch = input.UserInputType == Enum.UserInputType.Touch
    if not isMouse and not isTouch then return end
    if activeSlider and (isMouse or input == activePointer) then
        local bar = activeSlider.bar
        if bar.AbsoluteSize.X > 0 then
            local ratio = (input.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X
            setSliderValue(activeSlider.key, ratio * 100)
        end
    elseif windowDragging and dragMouse and dragFrom and (isMouse or input == dragPointer) then
        local delta = input.Position - dragMouse
        local scale = math.max(panelScale.Scale, 0.01)
        panel.Position = UDim2.new(
            dragFrom.X.Scale, dragFrom.X.Offset + delta.X / scale,
            dragFrom.Y.Scale, dragFrom.Y.Offset + delta.Y / scale
        )
    end
end)
connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input == activePointer then
            activeSlider = nil
            activePointer = nil
        end
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input == dragPointer then
            windowDragging = false
            dragPointer = nil
            dragMouse = nil
            dragFrom = nil
        end
    end
end)
connect(UserInputService.InputBegan, function(input, processed)
    if processed or unloading then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        gui.Enabled = not gui.Enabled
    elseif input.KeyCode == Enum.KeyCode.F7 then
        api.Toggle()
    end
end)

local frameTicks, frameDuration = 0, 0
connect(RunService.RenderStepped, function(dt)
    if unloading then return end
    frameTicks = frameTicks + 1
    frameDuration = frameDuration + dt
    if frameDuration >= 1 then
        lastFps = math.floor(frameTicks / frameDuration + 0.5)
        fpsText.Text = "FPS: " .. tostring(lastFps)
        if mirrorReport then
            mirrorReport.Text = "Reflection: " .. mirrorStatus .. " | " .. tostring(mirrorCount) .. " proxies"
        end
        frameTicks, frameDuration = 0, 0
    end
end)

-- Move only existing mirror proxies at a bounded cadence (~10Hz).
-- This attempts an approximate floor overlay and is not a raster-pixel
-- ray tracing pipeline. The surface may legitimately show no reflection.
task.spawn(function()
    while not unloading do
        task.wait(lastFps < 45 and 0.22 or 0.10)
        if unloading then break end
        if enabled and toggles.mirror then
            local ok, err = pcall(moveMirrorCopies)
            if not ok then mirrorStatus = "CAMERA ERROR"; warn("[VEX RTX] mirror camera " .. tostring(err)) end
        end
    end
end)

-- Scan floor / relocate mirror proxies periodically, never render a full scene.
task.spawn(function()
    while not unloading do
        task.wait(1.6)
        if unloading then break end
        if enabled and toggles.mirror then
            local ok, err = pcall(updateMirrorFloor)
            if not ok then
                mirrorStatus = "MIRROR ERROR"
                warn("[VEX RTX] Mirror update: " .. tostring(err))
            end
        end
        if enabled and toggles.bounce then
            local ok, err = pcall(updateBounce)
            if not ok then warn("[VEX RTX] Bounce probe: " .. tostring(err)) end
        end
    end
end)

-- Periodically update glossy floors around the player; never scan all Workspace.
task.spawn(function()
    while not unloading do
        task.wait(8)
        if unloading then break end
        if enabled and toggles.floors then requestScan() end
        refreshUI()
    end
end)

local bootOK, bootError = pcall(function() selectPreset("RTX+") end)
if not bootOK then
    eventStatus.Text = "Start error: " .. string.sub(tostring(bootError), 1, 60)
    warn("[VEX RTX] Startup error: " .. tostring(bootError))
end
print("[VEX RTX] v5.0 active. 8 presets, RTX Lab beta, RightShift GUI, F7 FX.")
