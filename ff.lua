local table_insert = table.insert

local Maid = {}
Maid.__index = Maid

function Maid.new()
    return setmetatable({_tasks = {}, _destroyed = false}, Maid)
end

function Maid:GiveTask(task)
    if self._destroyed then
        self:_cleanupTask(task)
        return
    end
    table_insert(self._tasks, task)
    return task
end

function Maid:GiveTasks(...)
    for _, task in ipairs({...}) do
        self:GiveTask(task)
    end
end

function Maid:_cleanupTask(task)
    local taskType = typeof(task)
    if taskType == "RBXScriptConnection" then
        task:Disconnect()
    elseif taskType == "Instance" then
        task:Destroy()
    elseif taskType == "function" then
        task()
    elseif taskType == "table" and type(task.Destroy) == "function" then
        task:Destroy()
    end
end

function Maid:DoCleaning()
    if self._destroyed then return end
    self._destroyed = true
    for _, task in ipairs(self._tasks) do
        self:_cleanupTask(task)
    end
    self._tasks = {}
end

function Maid:Destroy()
    self:DoCleaning()
end

local RootMaid = Maid.new()
local shared = odh_shared_plugins
task.spawn(function()
    shared.load_from_github_url("/aux0on/CrashHandler/refs/heads/main/Prevention.lua")
end)

if shared.game_name ~= "Murder Mystery 2" then return end

local gp = shared.CreateTab("Firefly Shield", "/aux0on/GPIcon/refs/heads/main/Untitled163_20260919034104")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

--=========================================================
-- FIREFLY SLOT DEFINITIONS
--=========================================================
local slots = {
    { key = "TL", label = "Top-Left",      x = -1.0, y =  1.0, z = 0 },
    { key = "TC", label = "Top-Center",    x =  0.0, y =  1.0, z = 0 },
    { key = "TR", label = "Top-Right",     x =  1.0, y =  1.0, z = 0 },
    { key = "ML", label = "Middle-Left",   x = -1.0, y =  0.0, z = 0 },
    { key = "MC", label = "Middle-Center", x =  0.0, y =  0.0, z = 0 },
    { key = "MR", label = "Middle-Right",  x =  1.0, y =  0.0, z = 0 },
    { key = "BC", label = "Bottom-Center", x =  0.0, y = -1.0, z = 0 },
}

--=========================================================
-- CONFIG
--=========================================================
local config = {
    offset       = 1.5,
    height       = 0,
    followSpeed  = 12,
    maxFireflies = 50,
    rescanTime   = 0.2,

    -- Shared detection settings
    blockRange      = 50,
    threatTimeout   = 0.3,   -- Grace period after the knife is no longer detected

    -- Moving block settings
    lineLength      = 20,
    lineBackOffset  = 4,

    -- Static block settings
    staticStartOffset = 2,
    staticLineLength  = 25,
    staticTimeout     = 15,  -- Hard safety cap
}

local features = {
    enabled           = false,
    blockKnives       = false,
    blockKnivesStatic = false,
}

--=========================================================
-- STATE
--=========================================================
local fireflyList      = {}
local tracked          = {}
local smoothDir        = nil
local accumulator      = 0
local isRunning        = false
local loopMaid         = Maid.new()
local activeThreat     = nil
local activeStaticLine = nil

--=========================================================
-- HELPERS
--=========================================================
local function killMovers(part)
    for _, child in ipairs(part:GetChildren()) do
        if child:IsA("BodyVelocity") or child:IsA("BodyAngularVelocity")
            or child:IsA("BodyPosition") or child:IsA("BodyGyro")
            or child:IsA("AlignPosition") or child:IsA("AlignOrientation") then
            child:Destroy()
        end
    end
end

local function getLayoutOffsets(count)
    local offsets = {}
    if count <= #slots then
        for i = 1, count do
            local s = slots[i]
            table.insert(offsets, Vector3.new(s.x, s.y, s.z))
        end
        return offsets
    end

    local cols = math.ceil(math.sqrt(count))
    local rows = math.ceil(count / cols)
    local stepX = (cols > 1) and (2 / (cols - 1)) or 0
    local stepY = (rows > 1) and (2 / (rows - 1)) or 0

    for i = 0, count - 1 do
        local row = math.floor(i / cols)
        local col = i % cols
        local x = -1 + (col * stepX)
        local y = -1 + (row * stepY)

        local itemsInLastRow = count % cols
        if row == rows - 1 and itemsInLastRow > 0 and itemsInLastRow < cols then
            local shift = (cols - itemsInLastRow) * stepX / 2
            x = x + shift
        end
        table.insert(offsets, Vector3.new(x, y, 0))
    end
    return offsets
end

local function hasKillerTool(container)
    if not container then return false end
    for _, item in ipairs(container:GetChildren()) do
        if item:IsA("Tool") and item.Name:lower():find("knife", 1, true) then
            return true
        end
    end
    return false
end

local function findThreatRoot(myRoot)
    local best, bestDist = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            if char then
                local root = char:FindFirstChild("HumanoidRootPart")
                local hum  = char:FindFirstChildOfClass("Humanoid")
                if root and hum and hum.Health > 0 then
                    if hasKillerTool(char) or hasKillerTool(plr:FindFirstChildOfClass("Backpack")) then
                        local dist = (root.Position - myRoot.Position).Magnitude
                        if dist < bestDist then
                            bestDist, best = dist, root
                        end
                    end
                end
            end
        end
    end
    return best
end

local function getThreatDir(myRoot)
    local threat = findThreatRoot(myRoot)
    if threat then
        local flat = Vector3.new(
            threat.Position.X - myRoot.Position.X,
            0,
            threat.Position.Z - myRoot.Position.Z
        )
        if flat.Magnitude > 0.05 then return flat.Unit end
    end
    local look   = myRoot.CFrame.LookVector
    local behind = Vector3.new(-look.X, 0, -look.Z)
    if behind.Magnitude < 0.05 then behind = Vector3.new(0, 0, 1) end
    return behind.Unit
end

--=========================================================
-- THROWN KNIFE DETECTION (shared by both modes)
--=========================================================
local function findNearestKnife(myRoot)
    local best, bestDist = nil, math.huge

    for _, obj in ipairs(Workspace:GetChildren()) do
        if obj.Name:lower() == "throwingknife" then
            local part = obj:IsA("BasePart") and obj or obj:FindFirstChildWhichIsA("BasePart")
            if part then
                local vel = part.AssemblyLinearVelocity
                local dir
                if vel.Magnitude > 1 then
                    dir = vel.Unit
                else
                    dir = part.CFrame.LookVector
                end

                local dist = (part.Position - myRoot.Position).Magnitude
                if dist <= config.blockRange and dist < bestDist then
                    bestDist = dist
                    best = {
                        part = part,
                        obj  = obj,
                        pos  = part.Position,
                        dir  = dir,
                    }
                end
            end
        end
    end

    return best
end

--=========================================================
-- MOVING BLOCK
--=========================================================
local function applyMovingBlock(threat)
    local count = #fireflyList
    if count == 0 then return end

    local dir       = threat.dir
    local lineStart = threat.pos - dir * config.lineBackOffset
    local lineEnd   = lineStart + dir * config.lineLength

    for i, obj in ipairs(fireflyList) do
        if obj and obj.Parent then
            local t = (count > 1) and ((i - 1) / (count - 1)) or 0.5
            obj.CFrame     = CFrame.new(lineStart:Lerp(lineEnd, t))
            obj.Anchored   = true
            obj.CanCollide = true
        end
    end
end

--=========================================================
-- STATIC BLOCK
--=========================================================
local function applyStaticLine(lineData)
    local count = #fireflyList
    if count == 0 then return end

    local startPos = lineData.start + lineData.dir * config.staticStartOffset
    local endPos   = startPos + lineData.dir * config.staticLineLength

    for i, obj in ipairs(fireflyList) do
        if obj and obj.Parent then
            local t = (count > 1) and ((i - 1) / (count - 1)) or 0.5
            obj.CFrame     = CFrame.new(startPos:Lerp(endPos, t))
            obj.Anchored   = true
            obj.CanCollide = true
        end
    end
end

--=========================================================
-- COLLECTION
--=========================================================
local function collectFireflies()
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name == "Firefly" and not tracked[obj] then
            if #fireflyList >= config.maxFireflies then break end

            tracked[obj] = true
            table.insert(fireflyList, obj)
            killMovers(obj)

            pcall(function()
                if obj:GetNetworkOwner() ~= LocalPlayer then
                    obj:SetNetworkOwner(LocalPlayer)
                end
                obj.Anchored   = true
                obj.CanCollide = false
            end)
        end
    end

    for i = #fireflyList, 1, -1 do
        local obj = fireflyList[i]
        if not obj or not obj.Parent then
            if obj then tracked[obj] = nil end
            table.remove(fireflyList, i)
        end
    end
end

--=========================================================
-- UPDATE
--=========================================================
local function updateFireflies(dt)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    --=====================================================
    -- STATIC KNIFE BLOCK (highest priority)
    -- Uses same findNearestKnife detection as moving block
    --=====================================================
    if features.blockKnivesStatic then
        local knife = findNearestKnife(root)

        if activeStaticLine then
            -- Already locked in -- keep holding until:
            --   a) no knife is detected AND grace period passed
            --   b) hard safety timeout
            local timedOut = (tick() - activeStaticLine.startTime) > config.staticTimeout
            local lostContact = not knife
                and (tick() - activeStaticLine.lastSeenTime) > config.threatTimeout

            if timedOut or lostContact then
                activeStaticLine = nil
                -- Fall through to normal shield below
            else
                -- Refresh lastSeenTime if a knife is still visible
                if knife then
                    activeStaticLine.lastSeenTime = tick()
                end
                applyStaticLine(activeStaticLine)
                return
            end
        else
            -- Look for a fresh knife and lock in once
            if knife then
                activeStaticLine = {
                    start         = knife.pos,
                    dir           = knife.dir,
                    startTime     = tick(),
                    lastSeenTime  = tick(),
                }
                applyStaticLine(activeStaticLine)
                return
            end
        end
    end

    --=====================================================
    -- MOVING KNIFE BLOCK (only if static is off)
    --=====================================================
    if not features.blockKnivesStatic and features.blockKnives then
        local threat = findNearestKnife(root)
        if threat then
            activeThreat = { time = tick() }
            applyMovingBlock(threat)
            return
        elseif activeThreat and (tick() - activeThreat.time) < config.threatTimeout then
            return
        else
            activeThreat = nil
        end
    end

    --=====================================================
    -- NORMAL SHIELD FORMATION
    --=====================================================
    local targetDir = getThreatDir(root)

    if smoothDir then
        local alpha   = math.clamp(config.followSpeed * dt, 0, 1)
        local blended = smoothDir:Lerp(targetDir, alpha)
        if blended.Magnitude > 0.001 then smoothDir = blended.Unit end
    else
        smoothDir = targetDir
    end

    local count = #fireflyList
    if count == 0 then return end

    local dir      = smoothDir
    local rotation = CFrame.lookAt(Vector3.zero, -dir)

    local center = root.Position
        + Vector3.new(0, config.height, 0)
        + dir * config.offset

    local offsets = getLayoutOffsets(count)

    for i, obj in ipairs(fireflyList) do
        if obj and obj.Parent then
            local offset3D = offsets[i]
            if offset3D then
                obj.CFrame     = CFrame.new(center + (rotation * offset3D))
                obj.CanCollide = false
            end
        end
    end
end

--=========================================================
-- START / STOP
--=========================================================
local function startFireflies()
    if isRunning then return end
    isRunning        = true
    smoothDir        = nil
    accumulator      = 0
    fireflyList      = {}
    tracked          = {}
    activeThreat     = nil
    activeStaticLine = nil

    loopMaid:GiveTask(RunService.Heartbeat:Connect(function(dt)
        accumulator = accumulator + dt
        if accumulator > config.rescanTime then
            accumulator = 0
            collectFireflies()
        end
        updateFireflies(dt)
    end))
end

local function stopFireflies()
    isRunning = false
    loopMaid:DoCleaning()
    loopMaid = Maid.new()

    for _, obj in ipairs(fireflyList) do
        if obj and obj.Parent then
            pcall(function()
                obj.Anchored   = false
                obj.CanCollide = true
                obj:SetNetworkOwner(nil)
            end)
        end
    end

    fireflyList      = {}
    tracked          = {}
    smoothDir        = nil
    activeThreat     = nil
    activeStaticLine = nil
end

--=========================================================
-- UI
--=========================================================
local mainSection = gp:AddSection("Firefly Shield", "Main")

mainSection:AddToggle("Enable Firefly Shield", function(bool)
    features.enabled = bool
    if bool then
        startFireflies()
    else
        stopFireflies()
    end
end)

mainSection:AddToggle("Enable Block Thrown Knives", function(bool)
    features.blockKnives = bool
    if not bool then
        activeThreat = nil
    end
end)

mainSection:AddToggle("Block Throw Static", function(bool)
    features.blockKnivesStatic = bool
    if not bool then
        activeStaticLine = nil
    end
end)

local function addFireflySliders(section, slot)
    section:AddSlider(slot.label .. " X", -5, 5, slot.x, function(v) slot.x = v end)
    section:AddSlider(slot.label .. " Y", -5, 5, slot.y, function(v) slot.y = v end)
    section:AddSlider(slot.label .. " Z", -5, 5, slot.z, function(v) slot.z = v end)
end

local topSection = gp:AddSection("Top Row", "Fireflies")
addFireflySliders(topSection, slots[1])
addFireflySliders(topSection, slots[2])
addFireflySliders(topSection, slots[3])

local midSection = gp:AddSection("Middle Row", "Fireflies")
addFireflySliders(midSection, slots[4])
addFireflySliders(midSection, slots[5])
addFireflySliders(midSection, slots[6])

local bottomSection = gp:AddSection("Bottom Row", "Fireflies")
addFireflySliders(bottomSection, slots[7])

local globalSection = gp:AddSection("Global Settings", "Fireflies")
globalSection:AddSlider("Distance From Character", 0.5, 5.0, config.offset, function(v) config.offset = v end)
globalSection:AddSlider("Height Offset",          -4,   4,  config.height, function(v) config.height = v end)
globalSection:AddSlider("Follow Speed",            1,   30, config.followSpeed, function(v) config.followSpeed = v end)
globalSection:AddSlider("Max Fireflies",           1,  100, config.maxFireflies, function(v) config.maxFireflies = math.floor(v) end)

local movingBlockSection = gp:AddSection("Moving Knife Block", "Fireflies")
movingBlockSection:AddSlider("Trigger Range",      10, 120, config.blockRange,     function(v) config.blockRange = v end)
movingBlockSection:AddSlider("Line Length",         5,  60, config.lineLength,     function(v) config.lineLength = v end)
movingBlockSection:AddSlider("Line Back Offset",    0,  20, config.lineBackOffset, function(v) config.lineBackOffset = v end)
movingBlockSection:AddSlider("Return Delay (s)",    0,   1, config.threatTimeout,  function(v) config.threatTimeout = v end)

local staticBlockSection = gp:AddSection("Static Knife Block", "Fireflies")
staticBlockSection:AddSlider("Trigger Range",       10, 120, config.blockRange,        function(v) config.blockRange = v end)
staticBlockSection:AddSlider("Start Offset",         0,  15, config.staticStartOffset, function(v) config.staticStartOffset = v end)
staticBlockSection:AddSlider("Line Length",          5,  60, config.staticLineLength,  function(v) config.staticLineLength = v end)
staticBlockSection:AddSlider("Return Delay (s)",     0,   1, config.threatTimeout,     function(v) config.threatTimeout = v end)
staticBlockSection:AddSlider("Hard Timeout (s)",     1,  60, config.staticTimeout,     function(v) config.staticTimeout = v end)

--=========================================================
-- CLEANUP ON UNLOAD
--=========================================================
RootMaid:GiveTask(function()
    features.enabled           = false
    features.blockKnives       = false
    features.blockKnivesStatic = false
    stopFireflies()
end)
