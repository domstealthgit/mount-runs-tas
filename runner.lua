-- TAS Runner GUI
-- Compatible with Potassium Executor
-- Auto-loads config list from GitHub repository

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local Humanoid = Character:WaitForChild("Humanoid")

-- ============================================================
-- CONFIG
-- ============================================================
-- Index file in your repo: a JSON array of config names (without .json extension)
-- e.g. ["skytopiabest1", "skytopiabest2"]
local CONFIG_INDEX = "https://raw.githubusercontent.com/domstealthgit/mount-runs-tas/refs/heads/main/configs.json"
local RAW_BASE     = "https://raw.githubusercontent.com/domstealthgit/mount-runs-tas/refs/heads/main/"

-- ============================================================
-- STATE
-- ============================================================
local isRunning    = false
local runThread    = nil
local configs      = {}        -- { name = "skytopiabest1", url = "..." }
local selectedIdx  = 1
local dropOpen     = false

-- ============================================================
-- HELPERS
-- ============================================================
local function arraytoCF(t)
    -- t = { x, y, z, qx, qy, qz, qw }
    local pos = Vector3.new(t[1], t[2], t[3])
    local rot = CFrame.new(pos) * CFrame.fromQuaternion(t[4], t[5], t[6], t[7])
    return rot
end

local function fetchConfigs()
    local ok, result = pcall(function()
        return HttpService:GetAsync(CONFIG_INDEX)
    end)
    if not ok then
        warn("[TAS] Could not fetch configs.json: " .. tostring(result))
        return
    end
    local names = HttpService:JSONDecode(result)
    configs = {}
    for _, name in ipairs(names) do
        table.insert(configs, {
            name = name,
            url  = RAW_BASE .. name .. ".json"
        })
    end
end

local function loadConfig(cfg)
    local ok, result = pcall(function()
        return HttpService:GetAsync(cfg.url)
    end)
    if not ok then
        warn("[TAS] Failed to load config: " .. tostring(result))
        return nil
    end
    return HttpService:JSONDecode(result)
end

-- ============================================================
-- TAS PLAYBACK
-- ============================================================
local function playback(frames)
    -- frames is the outer array; each element is an array of keyframes
    -- Each keyframe: { CF, RV, CCF, HS, T, V }
    -- Flatten all keyframes into one sorted list by T
    local allFrames = {}
    for _, segment in ipairs(frames) do
        for _, chunk in ipairs(segment) do
            for _, kf in ipairs(chunk) do
                table.insert(allFrames, kf)
            end
        end
    end
    table.sort(allFrames, function(a, b) return a.T < b.T end)

    local camera = workspace.CurrentCamera
    local startTime = tick()

    for _, kf in ipairs(allFrames) do
        if not isRunning then break end

        -- Wait until the right time
        local targetTime = startTime + kf.T
        while tick() < targetTime do
            if not isRunning then break end
            RunService.Heartbeat:Wait()
        end
        if not isRunning then break end

        -- Apply CFrame to character root
        if kf.CF then
            HumanoidRootPart.CFrame = arraytoCF(kf.CF)
        end

        -- Apply velocity
        if kf.V then
            HumanoidRootPart.AssemblyLinearVelocity = Vector3.new(kf.V[1], kf.V[2], kf.V[3])
        end

        -- Apply rotational velocity
        if kf.RV then
            HumanoidRootPart.AssemblyAngularVelocity = Vector3.new(kf.RV[1], kf.RV[2], kf.RV[3])
        end

        -- Apply camera CFrame
        if kf.CCF then
            camera.CFrame = arraytoCF(kf.CCF)
        end
    end

    isRunning = false
end

local function startRun()
    if isRunning then return end
    if #configs == 0 then
        warn("[TAS] No configs loaded.")
        return
    end
    local cfg = configs[selectedIdx]
    local data = loadConfig(cfg)
    if not data then return end

    isRunning = true
    runThread = task.spawn(function()
        playback(data)
        isRunning = false
    end)
end

local function stopRun()
    isRunning = false
    if runThread then
        task.cancel(runThread)
        runThread = nil
    end
end

-- ============================================================
-- GUI
-- ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "TAS_GUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

-- Main frame
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 260, 0, 160)
MainFrame.Position = UDim2.new(0, 20, 0.5, -80)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

-- Rounded corners
local UICorner = Instance.new("UICorner")
UICorner.CornerRadius = UDim.new(0, 8)
UICorner.Parent = MainFrame

-- Stroke
local UIStroke = Instance.new("UIStroke")
UIStroke.Color = Color3.fromRGB(80, 80, 120)
UIStroke.Thickness = 1.5
UIStroke.Parent = MainFrame

-- Title bar
local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 32)
TitleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 55)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = MainFrame

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 8)
TitleCorner.Parent = TitleBar

-- Fix bottom corners of title bar
local TitleFix = Instance.new("Frame")
TitleFix.Size = UDim2.new(1, 0, 0.5, 0)
TitleFix.Position = UDim2.new(0, 0, 0.5, 0)
TitleFix.BackgroundColor3 = Color3.fromRGB(35, 35, 55)
TitleFix.BorderSizePixel = 0
TitleFix.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Text = "⚡ TAS Runner"
TitleLabel.Size = UDim2.new(1, -10, 1, 0)
TitleLabel.Position = UDim2.new(0, 10, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 13
TitleLabel.Parent = TitleBar

-- Status label
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Name = "Status"
StatusLabel.Text = "● Idle"
StatusLabel.Size = UDim2.new(1, -20, 0, 20)
StatusLabel.Position = UDim2.new(0, 10, 0, 38)
StatusLabel.BackgroundTransparency = 1
StatusLabel.TextColor3 = Color3.fromRGB(140, 140, 180)
StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.Font = Enum.Font.Gotham
StatusLabel.TextSize = 11
StatusLabel.Parent = MainFrame

-- Config label
local ConfigLabel = Instance.new("TextLabel")
ConfigLabel.Text = "Config"
ConfigLabel.Size = UDim2.new(1, -20, 0, 16)
ConfigLabel.Position = UDim2.new(0, 10, 0, 62)
ConfigLabel.BackgroundTransparency = 1
ConfigLabel.TextColor3 = Color3.fromRGB(160, 160, 200)
ConfigLabel.TextXAlignment = Enum.TextXAlignment.Left
ConfigLabel.Font = Enum.Font.Gotham
ConfigLabel.TextSize = 11
ConfigLabel.Parent = MainFrame

-- Dropdown button
local DropButton = Instance.new("TextButton")
DropButton.Name = "DropButton"
DropButton.Size = UDim2.new(1, -20, 0, 30)
DropButton.Position = UDim2.new(0, 10, 0, 80)
DropButton.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
DropButton.BorderSizePixel = 0
DropButton.Text = "Loading..."
DropButton.TextColor3 = Color3.fromRGB(220, 220, 255)
DropButton.Font = Enum.Font.Gotham
DropButton.TextSize = 12
DropButton.Parent = MainFrame

local DropCorner = Instance.new("UICorner")
DropCorner.CornerRadius = UDim.new(0, 6)
DropCorner.Parent = DropButton

local DropArrow = Instance.new("TextLabel")
DropArrow.Text = "▼"
DropArrow.Size = UDim2.new(0, 24, 1, 0)
DropArrow.Position = UDim2.new(1, -28, 0, 0)
DropArrow.BackgroundTransparency = 1
DropArrow.TextColor3 = Color3.fromRGB(150, 150, 200)
DropArrow.Font = Enum.Font.Gotham
DropArrow.TextSize = 11
DropArrow.Parent = DropButton

-- Dropdown list (hidden by default)
local DropList = Instance.new("Frame")
DropList.Name = "DropList"
DropList.Size = UDim2.new(1, -20, 0, 0)
DropList.Position = UDim2.new(0, 10, 0, 112)
DropList.BackgroundColor3 = Color3.fromRGB(30, 30, 50)
DropList.BorderSizePixel = 0
DropList.ClipsDescendants = true
DropList.ZIndex = 10
DropList.Visible = false
DropList.Parent = MainFrame

local DropListCorner = Instance.new("UICorner")
DropListCorner.CornerRadius = UDim.new(0, 6)
DropListCorner.Parent = DropList

local DropListLayout = Instance.new("UIListLayout")
DropListLayout.SortOrder = Enum.SortOrder.LayoutOrder
DropListLayout.Padding = UDim.new(0, 2)
DropListLayout.Parent = DropList

-- Start / Stop button
local RunButton = Instance.new("TextButton")
RunButton.Name = "RunButton"
RunButton.Size = UDim2.new(1, -20, 0, 32)
RunButton.Position = UDim2.new(0, 10, 0, 118)
RunButton.BackgroundColor3 = Color3.fromRGB(60, 180, 100)
RunButton.BorderSizePixel = 0
RunButton.Text = "▶  Start"
RunButton.TextColor3 = Color3.fromRGB(255, 255, 255)
RunButton.Font = Enum.Font.GothamBold
RunButton.TextSize = 13
RunButton.Parent = MainFrame

local RunCorner = Instance.new("UICorner")
RunCorner.CornerRadius = UDim.new(0, 6)
RunCorner.Parent = RunButton

-- ============================================================
-- DROPDOWN LOGIC
-- ============================================================
local function populateDropdown()
    -- Clear existing items
    for _, child in ipairs(DropList:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end

    if #configs == 0 then
        DropButton.Text = "No configs found"
        return
    end

    for i, cfg in ipairs(configs) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, 0, 0, 28)
        item.BackgroundColor3 = Color3.fromRGB(40, 40, 65)
        item.BorderSizePixel = 0
        item.Text = " " .. cfg.name
        item.TextColor3 = Color3.fromRGB(210, 210, 255)
        item.Font = Enum.Font.Gotham
        item.TextSize = 12
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.LayoutOrder = i
        item.ZIndex = 11
        item.Parent = DropList

        local ic = Instance.new("UICorner")
        ic.CornerRadius = UDim.new(0, 4)
        ic.Parent = item

        local idx = i
        item.MouseButton1Click:Connect(function()
            selectedIdx = idx
            DropButton.Text = configs[idx].name
            -- close dropdown
            dropOpen = false
            DropList.Visible = false
            DropArrow.Text = "▼"
        end)

        item.MouseEnter:Connect(function()
            item.BackgroundColor3 = Color3.fromRGB(60, 60, 90)
        end)
        item.MouseLeave:Connect(function()
            item.BackgroundColor3 = Color3.fromRGB(40, 40, 65)
        end)
    end

    -- Resize drop list to fit items
    local itemH = 28
    local pad = 4
    DropList.Size = UDim2.new(1, -20, 0, #configs * (itemH + 2) + pad)

    -- Select first by default
    selectedIdx = 1
    DropButton.Text = configs[1].name
end

DropButton.MouseButton1Click:Connect(function()
    if #configs == 0 then return end
    dropOpen = not dropOpen
    DropList.Visible = dropOpen
    DropArrow.Text = dropOpen and "▲" or "▼"

    if dropOpen then
        -- Push run button down
        RunButton.Position = UDim2.new(0, 10, 0, 118 + DropList.Size.Y.Offset + 4)
        MainFrame.Size = UDim2.new(0, 260, 0, 160 + DropList.Size.Y.Offset + 4)
    else
        RunButton.Position = UDim2.new(0, 10, 0, 118)
        MainFrame.Size = UDim2.new(0, 260, 0, 160)
    end
end)

-- ============================================================
-- RUN / STOP BUTTON LOGIC
-- ============================================================
local function updateUI()
    if isRunning then
        RunButton.Text = "■  Stop"
        RunButton.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
        StatusLabel.Text = "● Running: " .. (configs[selectedIdx] and configs[selectedIdx].name or "?")
        StatusLabel.TextColor3 = Color3.fromRGB(100, 220, 120)
    else
        RunButton.Text = "▶  Start"
        RunButton.BackgroundColor3 = Color3.fromRGB(60, 180, 100)
        StatusLabel.Text = "● Idle"
        StatusLabel.TextColor3 = Color3.fromRGB(140, 140, 180)
    end
end

RunButton.MouseButton1Click:Connect(function()
    if isRunning then
        stopRun()
    else
        startRun()
    end
    updateUI()
end)

-- Poll running state to keep button in sync
task.spawn(function()
    while true do
        task.wait(0.25)
        updateUI()
    end
end)

-- ============================================================
-- INIT: Fetch configs on load
-- ============================================================
task.spawn(function()
    StatusLabel.Text = "● Fetching configs..."
    fetchConfigs()
    populateDropdown()
    updateUI()
    if #configs == 0 then
        StatusLabel.Text = "● No configs found"
    else
        StatusLabel.Text = "● Ready  (" .. #configs .. " config" .. (#configs == 1 and "" or "s") .. ")"
    end
end)

print("[TAS] GUI loaded successfully.")
