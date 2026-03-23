-- TAS Runner GUI
-- Drop your .json config files into: <Executor>/workspace/TAS_Configs/
-- Compatible with Potassium and most executors

local HttpService    = game:GetService("HttpService")
local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")

local LocalPlayer      = Players.LocalPlayer
local Character        = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")

-- ============================================================
-- FOLDER SETUP
-- ============================================================
local FOLDER = "TAS_Configs"

if not isfolder(FOLDER) then
    makefolder(FOLDER)
    print("[TAS] Created folder: workspace/" .. FOLDER .. "  — drop your .json files in there!")
end

-- ============================================================
-- STATE
-- ============================================================
local isRunning   = false
local runThread   = nil
local configs     = {}   -- { name, path }
local selectedIdx = 1
local dropOpen    = false

-- ============================================================
-- HELPERS
-- ============================================================
local function arraytoCF(t)
    local pos = Vector3.new(t[1], t[2], t[3])
    return CFrame.new(pos) * CFrame.fromQuaternion(t[4], t[5], t[6], t[7])
end

local function scanConfigs()
    configs = {}
    local files = listfiles(FOLDER)
    for _, path in ipairs(files) do
        local name = path:match("([^/\\]+)%.json$")
        if name then
            table.insert(configs, { name = name, path = path })
        end
    end
    table.sort(configs, function(a, b) return a.name < b.name end)
end

local function loadConfig(cfg)
    local ok, raw = pcall(readfile, cfg.path)
    if not ok or not raw or raw == "" then
        warn("[TAS] Could not read file: " .. cfg.path)
        return nil
    end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 then
        warn("[TAS] JSON parse error in: " .. cfg.path)
        return nil
    end
    return data
end

-- ============================================================
-- TAS PLAYBACK
-- ============================================================
local function playback(frames)
    local allFrames = {}
    for _, segment in ipairs(frames) do
        for _, chunk in ipairs(segment) do
            for _, kf in ipairs(chunk) do
                table.insert(allFrames, kf)
            end
        end
    end
    table.sort(allFrames, function(a, b) return a.T < b.T end)

    local camera    = workspace.CurrentCamera
    local startTime = tick()

    for _, kf in ipairs(allFrames) do
        if not isRunning then break end

        local targetTime = startTime + kf.T
        while tick() < targetTime do
            if not isRunning then break end
            RunService.Heartbeat:Wait()
        end
        if not isRunning then break end

        if kf.CF  then HumanoidRootPart.CFrame                  = arraytoCF(kf.CF)                             end
        if kf.V   then HumanoidRootPart.AssemblyLinearVelocity   = Vector3.new(kf.V[1],  kf.V[2],  kf.V[3])   end
        if kf.RV  then HumanoidRootPart.AssemblyAngularVelocity  = Vector3.new(kf.RV[1], kf.RV[2], kf.RV[3])  end
        if kf.CCF then camera.CFrame                             = arraytoCF(kf.CCF)                            end
    end

    isRunning = false
end

local function startRun()
    if isRunning or #configs == 0 then return end
    local cfg  = configs[selectedIdx]
    local data = loadConfig(cfg)
    if not data then return end
    isRunning  = true
    runThread  = task.spawn(function()
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
ScreenGui.Name           = "TAS_GUI"
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent         = LocalPlayer:WaitForChild("PlayerGui")

local MainFrame = Instance.new("Frame")
MainFrame.Name             = "MainFrame"
MainFrame.Size             = UDim2.new(0, 260, 0, 165)
MainFrame.Position         = UDim2.new(0, 20, 0.5, -82)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
MainFrame.BorderSizePixel  = 0
MainFrame.Active           = true
MainFrame.Draggable        = true
MainFrame.Parent           = ScreenGui

local function addCorner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 8)
    c.Parent = parent
end

addCorner(MainFrame)

local stroke = Instance.new("UIStroke")
stroke.Color     = Color3.fromRGB(80, 80, 130)
stroke.Thickness = 1.5
stroke.Parent    = MainFrame

-- Title bar
local TitleBar = Instance.new("Frame")
TitleBar.Size             = UDim2.new(1, 0, 0, 32)
TitleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 58)
TitleBar.BorderSizePixel  = 0
TitleBar.Parent           = MainFrame
addCorner(TitleBar)

local TitleFix = Instance.new("Frame")
TitleFix.Size             = UDim2.new(1, 0, 0.5, 0)
TitleFix.Position         = UDim2.new(0, 0, 0.5, 0)
TitleFix.BackgroundColor3 = Color3.fromRGB(35, 35, 58)
TitleFix.BorderSizePixel  = 0
TitleFix.Parent           = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Text               = "⚡ TAS Runner"
TitleLabel.Size               = UDim2.new(1, -10, 1, 0)
TitleLabel.Position           = UDim2.new(0, 10, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.TextColor3         = Color3.fromRGB(200, 200, 255)
TitleLabel.TextXAlignment     = Enum.TextXAlignment.Left
TitleLabel.Font               = Enum.Font.GothamBold
TitleLabel.TextSize           = 13
TitleLabel.Parent             = TitleBar

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size               = UDim2.new(1, -20, 0, 20)
StatusLabel.Position           = UDim2.new(0, 10, 0, 38)
StatusLabel.BackgroundTransparency = 1
StatusLabel.TextColor3         = Color3.fromRGB(140, 140, 180)
StatusLabel.TextXAlignment     = Enum.TextXAlignment.Left
StatusLabel.Font               = Enum.Font.Gotham
StatusLabel.TextSize           = 11
StatusLabel.Text               = "● Scanning TAS_Configs/..."
StatusLabel.Parent             = MainFrame

local ConfigLabel = Instance.new("TextLabel")
ConfigLabel.Text               = "Config"
ConfigLabel.Size               = UDim2.new(1, -20, 0, 16)
ConfigLabel.Position           = UDim2.new(0, 10, 0, 62)
ConfigLabel.BackgroundTransparency = 1
ConfigLabel.TextColor3         = Color3.fromRGB(160, 160, 200)
ConfigLabel.TextXAlignment     = Enum.TextXAlignment.Left
ConfigLabel.Font               = Enum.Font.Gotham
ConfigLabel.TextSize           = 11
ConfigLabel.Parent             = MainFrame

local DropButton = Instance.new("TextButton")
DropButton.Size             = UDim2.new(1, -20, 0, 30)
DropButton.Position         = UDim2.new(0, 10, 0, 80)
DropButton.BackgroundColor3 = Color3.fromRGB(40, 40, 65)
DropButton.BorderSizePixel  = 0
DropButton.Text             = "No configs found"
DropButton.TextColor3       = Color3.fromRGB(220, 220, 255)
DropButton.Font             = Enum.Font.Gotham
DropButton.TextSize         = 12
DropButton.Parent           = MainFrame
addCorner(DropButton, 6)

local DropArrow = Instance.new("TextLabel")
DropArrow.Text               = "▼"
DropArrow.Size               = UDim2.new(0, 24, 1, 0)
DropArrow.Position           = UDim2.new(1, -28, 0, 0)
DropArrow.BackgroundTransparency = 1
DropArrow.TextColor3         = Color3.fromRGB(150, 150, 200)
DropArrow.Font               = Enum.Font.Gotham
DropArrow.TextSize           = 11
DropArrow.Parent             = DropButton

local DropList = Instance.new("Frame")
DropList.Size             = UDim2.new(1, -20, 0, 0)
DropList.Position         = UDim2.new(0, 10, 0, 112)
DropList.BackgroundColor3 = Color3.fromRGB(30, 30, 52)
DropList.BorderSizePixel  = 0
DropList.ClipsDescendants = true
DropList.ZIndex           = 10
DropList.Visible          = false
DropList.Parent           = MainFrame
addCorner(DropList, 6)

local DropListLayout = Instance.new("UIListLayout")
DropListLayout.SortOrder = Enum.SortOrder.LayoutOrder
DropListLayout.Padding   = UDim.new(0, 2)
DropListLayout.Parent    = DropList

local DropPad = Instance.new("UIPadding")
DropPad.PaddingTop    = UDim.new(0, 2)
DropPad.PaddingBottom = UDim.new(0, 2)
DropPad.PaddingLeft   = UDim.new(0, 2)
DropPad.PaddingRight  = UDim.new(0, 2)
DropPad.Parent        = DropList

local BASE_HEIGHT = 165

local RefreshButton = Instance.new("TextButton")
RefreshButton.Size             = UDim2.new(0, 32, 0, 32)
RefreshButton.Position         = UDim2.new(0, 10, 0, 123)
RefreshButton.BackgroundColor3 = Color3.fromRGB(50, 50, 82)
RefreshButton.BorderSizePixel  = 0
RefreshButton.Text             = "↻"
RefreshButton.TextColor3       = Color3.fromRGB(200, 200, 255)
RefreshButton.Font             = Enum.Font.GothamBold
RefreshButton.TextSize         = 18
RefreshButton.Parent           = MainFrame
addCorner(RefreshButton, 6)

local RunButton = Instance.new("TextButton")
RunButton.Size             = UDim2.new(1, -52, 0, 32)
RunButton.Position         = UDim2.new(0, 48, 0, 123)
RunButton.BackgroundColor3 = Color3.fromRGB(60, 180, 100)
RunButton.BorderSizePixel  = 0
RunButton.Text             = "▶  Start"
RunButton.TextColor3       = Color3.fromRGB(255, 255, 255)
RunButton.Font             = Enum.Font.GothamBold
RunButton.TextSize         = 13
RunButton.Parent           = MainFrame
addCorner(RunButton, 6)

-- ============================================================
-- DROPDOWN POPULATION
-- ============================================================
local function populateDropdown()
    for _, child in ipairs(DropList:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end

    if #configs == 0 then
        DropButton.Text = "No configs found"
        return
    end

    for i, cfg in ipairs(configs) do
        local item = Instance.new("TextButton")
        item.Size             = UDim2.new(1, 0, 0, 28)
        item.BackgroundColor3 = Color3.fromRGB(40, 40, 65)
        item.BorderSizePixel  = 0
        item.Text             = "  " .. cfg.name
        item.TextColor3       = Color3.fromRGB(210, 210, 255)
        item.Font             = Enum.Font.Gotham
        item.TextSize         = 12
        item.TextXAlignment   = Enum.TextXAlignment.Left
        item.LayoutOrder      = i
        item.ZIndex           = 11
        item.Parent           = DropList
        addCorner(item, 4)

        local idx = i
        item.MouseButton1Click:Connect(function()
            selectedIdx      = idx
            DropButton.Text  = configs[idx].name
            dropOpen         = false
            DropList.Visible = false
            DropArrow.Text   = "▼"
            MainFrame.Size         = UDim2.new(0, 260, 0, BASE_HEIGHT)
            RefreshButton.Position = UDim2.new(0, 10, 0, 123)
            RunButton.Position     = UDim2.new(0, 48, 0, 123)
        end)
        item.MouseEnter:Connect(function() item.BackgroundColor3 = Color3.fromRGB(60, 60, 95) end)
        item.MouseLeave:Connect(function() item.BackgroundColor3 = Color3.fromRGB(40, 40, 65) end)
    end

    DropList.Size   = UDim2.new(1, -20, 0, #configs * 30 + 4)
    selectedIdx     = 1
    DropButton.Text = configs[1].name
end

local function refreshConfigs()
    scanConfigs()
    populateDropdown()
    if #configs == 0 then
        StatusLabel.Text       = "● Drop .json files into workspace/TAS_Configs/"
        StatusLabel.TextColor3 = Color3.fromRGB(220, 140, 80)
    else
        StatusLabel.Text       = "● Ready  (" .. #configs .. " config" .. (#configs == 1 and "" or "s") .. ")"
        StatusLabel.TextColor3 = Color3.fromRGB(140, 140, 180)
    end
end

-- ============================================================
-- DROPDOWN TOGGLE
-- ============================================================
DropButton.MouseButton1Click:Connect(function()
    if #configs == 0 then return end
    dropOpen         = not dropOpen
    DropList.Visible = dropOpen
    DropArrow.Text   = dropOpen and "▲" or "▼"

    local extra = dropOpen and (DropList.Size.Y.Offset + 4) or 0
    MainFrame.Size         = UDim2.new(0, 260, 0, BASE_HEIGHT + extra)
    RefreshButton.Position = UDim2.new(0, 10, 0, 123 + extra)
    RunButton.Position     = UDim2.new(0, 48, 0, 123 + extra)
end)

-- ============================================================
-- REFRESH BUTTON
-- ============================================================
RefreshButton.MouseButton1Click:Connect(function()
    dropOpen         = false
    DropList.Visible = false
    DropArrow.Text   = "▼"
    MainFrame.Size         = UDim2.new(0, 260, 0, BASE_HEIGHT)
    RefreshButton.Position = UDim2.new(0, 10, 0, 123)
    RunButton.Position     = UDim2.new(0, 48, 0, 123)
    StatusLabel.Text       = "● Refreshing..."
    task.wait(0.05)
    refreshConfigs()
end)

-- ============================================================
-- START / STOP
-- ============================================================
local function updateUI()
    if isRunning then
        RunButton.Text             = "■  Stop"
        RunButton.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
        StatusLabel.Text           = "● Running: " .. (configs[selectedIdx] and configs[selectedIdx].name or "?")
        StatusLabel.TextColor3     = Color3.fromRGB(100, 220, 120)
    else
        RunButton.Text             = "▶  Start"
        RunButton.BackgroundColor3 = Color3.fromRGB(60, 180, 100)
    end
end

RunButton.MouseButton1Click:Connect(function()
    if isRunning then stopRun() else startRun() end
    updateUI()
end)

task.spawn(function()
    while true do
        task.wait(0.25)
        updateUI()
    end
end)

-- ============================================================
-- INIT
-- ============================================================
refreshConfigs()
print("[TAS] GUI ready. Folder: workspace/" .. FOLDER .. "/")
