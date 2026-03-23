-- TAS Runner GUI
-- Reads .json files saved by the TAS Creator script from: workspace/TAS_Recorder/
-- Loops playback until Stop is pressed.

local HttpService  = game:GetService("HttpService")
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")

local LocalPlayer      = Players.LocalPlayer
local Character        = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local Humanoid         = Character:WaitForChild("Humanoid")

-- ============================================================
-- FOLDER  (same folder the TAS Creator script uses)
-- ============================================================
local FOLDER = "TAS_Recorder"
if not isfolder(FOLDER) then
    makefolder(FOLDER)
    print("[TAS] Created folder: workspace/" .. FOLDER .. "/  — save your runs there with the TAS Creator script.")
end

-- ============================================================
-- STATE
-- ============================================================
local isRunning   = false
local playConn    = nil
local configs     = {}
local selectedIdx = 1
local dropOpen    = false

-- States that must NOT be disabled during playback
local KeepEnabledStates = {
    [Enum.HumanoidStateType.Dead]       = true,
    [Enum.HumanoidStateType.GettingUp]  = true,
    [Enum.HumanoidStateType.Landed]     = true,
    [Enum.HumanoidStateType.None]       = true,
}

local ValToStateName = {}
for _, s in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
    ValToStateName[s.Value] = s.Name
end

-- ============================================================
-- MATH  (identical to TAS Creator)
-- ============================================================
local function CFrameToQuat(cf)
    local axis, angle = cf:ToAxisAngle()
    local s = math.sin(angle / 2)
    return axis.X * s, axis.Y * s, axis.Z * s, math.cos(angle / 2)
end

local function QuatToCFrame(x, y, z, qX, qY, qZ, qW)
    return CFrame.new(x, y, z, qX, qY, qZ, qW)
end

-- Handle legacy CF formats (12-component matrix or 6-component euler)
local function normaliseCF(arr)
    if #arr == 7 then return arr end   -- already quaternion
    local cf
    if #arr == 12 then
        cf = CFrame.new(table.unpack(arr))
    elseif #arr == 6 then
        cf = CFrame.new(arr[1], arr[2], arr[3]) * CFrame.fromEulerAnglesYXZ(arr[4], arr[5], arr[6])
    else
        return arr  -- unknown, pass through
    end
    local qX, qY, qZ, qW = CFrameToQuat(cf)
    return {cf.X, cf.Y, cf.Z, qX, qY, qZ, qW}
end

-- ============================================================
-- FILE HELPERS
-- ============================================================
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
        warn("[TAS] Cannot read: " .. cfg.path)
        return nil
    end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or type(data) ~= "table" then
        warn("[TAS] JSON error in: " .. cfg.path)
        return nil
    end
    -- data = { [1]=Savestates, [2]=PlayerInfo }
    return data
end

-- Flatten savestates + playerinfo into one sorted frame list
local function flattenFrames(data)
    local flat = {}
    -- data[1] = array of savestate segments, data[2] = current segment
    for _, segment in ipairs(data[1] or {}) do
        for _, frame in ipairs(segment) do
            -- normalise legacy formats
            if frame.CF  then frame.CF  = normaliseCF(frame.CF)  end
            if frame.CCF then frame.CCF = normaliseCF(frame.CCF) end
            table.insert(flat, frame)
        end
    end
    for _, frame in ipairs(data[2] or {}) do
        if frame.CF  then frame.CF  = normaliseCF(frame.CF)  end
        if frame.CCF then frame.CCF = normaliseCF(frame.CCF) end
        table.insert(flat, frame)
    end
    table.sort(flat, function(a, b) return a.T < b.T end)
    return flat
end

-- ============================================================
-- PLAYBACK  (mirrors ViewTASPlayback from TAS Creator, with loop)
-- ============================================================
local function stopRun()
    isRunning = false
    if playConn then
        playConn:Disconnect()
        playConn = nil
    end
    -- re-enable humanoid states
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChild("Humanoid")
        if hum then
            for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
                pcall(function() hum:SetStateEnabled(state, true) end)
            end
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end
        local root = char:FindFirstChild("HumanoidRootPart")
        if root then root.Anchored = false end
    end
end

local function startPlaybackLoop(frames)
    if #frames == 0 then
        warn("[TAS] No frames to play.")
        isRunning = false
        return
    end

    local char  = LocalPlayer.Character
    local root  = char and char:FindFirstChild("HumanoidRootPart")
    local hum   = char and char:FindFirstChild("Humanoid")
    if not root then isRunning = false; return end

    root.Anchored = false

    -- Disable physics-conflicting humanoid states
    if hum then
        for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
            if not KeepEnabledStates[state] then
                pcall(function() hum:SetStateEnabled(state, false) end)
            end
        end
    end

    local startTime   = os.clock()
    local currentIdx  = 1

    if playConn then playConn:Disconnect() end

    playConn = RunService.Heartbeat:Connect(function()
        if not isRunning then return end

        char  = LocalPlayer.Character
        root  = char and char:FindFirstChild("HumanoidRootPart")
        hum   = char and char:FindFirstChild("Humanoid")
        if not root then return end

        local elapsed = os.clock() - startTime

        -- Advance index
        while currentIdx < #frames and frames[currentIdx + 1] and frames[currentIdx + 1].T <= elapsed do
            currentIdx = currentIdx + 1
        end

        local fA = frames[currentIdx]
        local fB = frames[currentIdx + 1]

        if fB and fA.CF and fB.CF and fA.V and fB.V and fA.RV and fB.RV then
            -- Interpolate
            local delta = fB.T - fA.T
            local alpha = delta > 0 and math.clamp((elapsed - fA.T) / delta, 0, 1) or 0

            local cfA = QuatToCFrame(table.unpack(fA.CF))
            local cfB = QuatToCFrame(table.unpack(fB.CF))
            root.CFrame = cfA:Lerp(cfB, alpha)

            local velA  = Vector3.new(table.unpack(fA.V))
            local velB  = Vector3.new(table.unpack(fB.V))
            local rvelA = Vector3.new(table.unpack(fA.RV))
            local rvelB = Vector3.new(table.unpack(fB.RV))
            local curV  = velA:Lerp(velB, alpha)
            local curRV = rvelA:Lerp(rvelB, alpha)

            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.Velocity    = curV
                    part.RotVelocity = curRV
                end
            end

            -- Humanoid state
            if hum and fA.HS then
                local targetName = type(fA.HS) == "number" and ValToStateName[fA.HS] or fA.HS
                if targetName and targetName ~= "None" then
                    if hum:GetState().Name ~= targetName then
                        local enum = Enum.HumanoidStateType[targetName]
                        if enum then pcall(function() hum:ChangeState(enum) end) end
                    end
                end
            end
        else
            -- End of frames reached → LOOP
            if not isRunning then return end
            startTime  = os.clock()
            currentIdx = 1

            -- Re-teleport to first frame so loop starts cleanly
            local f0 = frames[1]
            if f0 and f0.CF then
                root.CFrame = QuatToCFrame(table.unpack(f0.CF))
                if f0.V then
                    local v0 = Vector3.new(table.unpack(f0.V))
                    for _, part in ipairs(char:GetDescendants()) do
                        if part:IsA("BasePart") then
                            part.Velocity    = v0
                            part.RotVelocity = Vector3.zero
                        end
                    end
                end
            end
        end
    end)
end

local function startRun()
    if isRunning or #configs == 0 then return end
    local cfg  = configs[selectedIdx]
    local data = loadConfig(cfg)
    if not data then return end
    local frames = flattenFrames(data)
    if #frames == 0 then
        warn("[TAS] Config has no frames: " .. cfg.name)
        return
    end
    isRunning = true
    startPlaybackLoop(frames)
end

-- ============================================================
-- GUI
-- ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = "TAS_GUI"
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent         = LocalPlayer:WaitForChild("PlayerGui")

local BASE_H = 165

local MainFrame = Instance.new("Frame")
MainFrame.Name             = "MainFrame"
MainFrame.Size             = UDim2.new(0, 260, 0, BASE_H)
MainFrame.Position         = UDim2.new(0, 20, 0.5, -82)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
MainFrame.BorderSizePixel  = 0
MainFrame.Active           = true
MainFrame.Draggable        = true
MainFrame.Parent           = ScreenGui

local function corner(p, r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = p
end
corner(MainFrame)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(80, 80, 130); stroke.Thickness = 1.5; stroke.Parent = MainFrame

-- Title bar
local TitleBar = Instance.new("Frame")
TitleBar.Size             = UDim2.new(1, 0, 0, 32)
TitleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 58)
TitleBar.BorderSizePixel  = 0
TitleBar.Parent           = MainFrame
corner(TitleBar)
local tf = Instance.new("Frame")   -- patch bottom corners
tf.Size = UDim2.new(1,0,0.5,0); tf.Position = UDim2.new(0,0,0.5,0)
tf.BackgroundColor3 = Color3.fromRGB(35,35,58); tf.BorderSizePixel = 0; tf.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Text = "⚡ TAS Runner"
TitleLabel.Size = UDim2.new(1,-10,1,0); TitleLabel.Position = UDim2.new(0,10,0,0)
TitleLabel.BackgroundTransparency = 1; TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Font = Enum.Font.GothamBold; TitleLabel.TextSize = 13
TitleLabel.TextColor3 = Color3.fromRGB(200,200,255); TitleLabel.Parent = TitleBar

-- Status
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1,-20,0,20); StatusLabel.Position = UDim2.new(0,10,0,38)
StatusLabel.BackgroundTransparency = 1; StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
StatusLabel.Font = Enum.Font.Gotham; StatusLabel.TextSize = 11
StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
StatusLabel.Text = "● Scanning TAS_Recorder/..."; StatusLabel.Parent = MainFrame

-- Config label
local ConfigLabel = Instance.new("TextLabel")
ConfigLabel.Text = "Config"; ConfigLabel.Size = UDim2.new(1,-20,0,16); ConfigLabel.Position = UDim2.new(0,10,0,62)
ConfigLabel.BackgroundTransparency = 1; ConfigLabel.TextXAlignment = Enum.TextXAlignment.Left
ConfigLabel.Font = Enum.Font.Gotham; ConfigLabel.TextSize = 11
ConfigLabel.TextColor3 = Color3.fromRGB(160,160,200); ConfigLabel.Parent = MainFrame

-- Dropdown button
local DropButton = Instance.new("TextButton")
DropButton.Size = UDim2.new(1,-20,0,30); DropButton.Position = UDim2.new(0,10,0,80)
DropButton.BackgroundColor3 = Color3.fromRGB(40,40,65); DropButton.BorderSizePixel = 0
DropButton.Text = "No configs found"; DropButton.TextColor3 = Color3.fromRGB(220,220,255)
DropButton.Font = Enum.Font.Gotham; DropButton.TextSize = 12; DropButton.Parent = MainFrame
corner(DropButton, 6)

local DropArrow = Instance.new("TextLabel")
DropArrow.Text = "▼"; DropArrow.Size = UDim2.new(0,24,1,0); DropArrow.Position = UDim2.new(1,-28,0,0)
DropArrow.BackgroundTransparency = 1; DropArrow.TextColor3 = Color3.fromRGB(150,150,200)
DropArrow.Font = Enum.Font.Gotham; DropArrow.TextSize = 11; DropArrow.Parent = DropButton

-- Dropdown list
local DropList = Instance.new("Frame")
DropList.Size = UDim2.new(1,-20,0,0); DropList.Position = UDim2.new(0,10,0,112)
DropList.BackgroundColor3 = Color3.fromRGB(30,30,52); DropList.BorderSizePixel = 0
DropList.ClipsDescendants = true; DropList.ZIndex = 10; DropList.Visible = false; DropList.Parent = MainFrame
corner(DropList, 6)

local dll = Instance.new("UIListLayout"); dll.SortOrder = Enum.SortOrder.LayoutOrder
dll.Padding = UDim.new(0,2); dll.Parent = DropList
local dp = Instance.new("UIPadding")
dp.PaddingTop = UDim.new(0,2); dp.PaddingBottom = UDim.new(0,2)
dp.PaddingLeft = UDim.new(0,2); dp.PaddingRight = UDim.new(0,2); dp.Parent = DropList

-- Refresh + Run buttons
local RefreshButton = Instance.new("TextButton")
RefreshButton.Size = UDim2.new(0,32,0,32); RefreshButton.Position = UDim2.new(0,10,0,123)
RefreshButton.BackgroundColor3 = Color3.fromRGB(50,50,82); RefreshButton.BorderSizePixel = 0
RefreshButton.Text = "↻"; RefreshButton.TextColor3 = Color3.fromRGB(200,200,255)
RefreshButton.Font = Enum.Font.GothamBold; RefreshButton.TextSize = 18; RefreshButton.Parent = MainFrame
corner(RefreshButton, 6)

local RunButton = Instance.new("TextButton")
RunButton.Size = UDim2.new(1,-52,0,32); RunButton.Position = UDim2.new(0,48,0,123)
RunButton.BackgroundColor3 = Color3.fromRGB(60,180,100); RunButton.BorderSizePixel = 0
RunButton.Text = "▶  Start"; RunButton.TextColor3 = Color3.fromRGB(255,255,255)
RunButton.Font = Enum.Font.GothamBold; RunButton.TextSize = 13; RunButton.Parent = MainFrame
corner(RunButton, 6)

-- ============================================================
-- DROPDOWN
-- ============================================================
local function closeDropdown()
    dropOpen = false; DropList.Visible = false; DropArrow.Text = "▼"
    MainFrame.Size         = UDim2.new(0,260,0,BASE_H)
    RefreshButton.Position = UDim2.new(0,10,0,123)
    RunButton.Position     = UDim2.new(0,48,0,123)
end

local function populateDropdown()
    for _, c in ipairs(DropList:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    if #configs == 0 then DropButton.Text = "No configs found"; return end

    for i, cfg in ipairs(configs) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1,0,0,28); item.BackgroundColor3 = Color3.fromRGB(40,40,65)
        item.BorderSizePixel = 0; item.Text = "  "..cfg.name
        item.TextColor3 = Color3.fromRGB(210,210,255); item.Font = Enum.Font.Gotham
        item.TextSize = 12; item.TextXAlignment = Enum.TextXAlignment.Left
        item.LayoutOrder = i; item.ZIndex = 11; item.Parent = DropList
        corner(item, 4)
        local idx = i
        item.MouseButton1Click:Connect(function()
            selectedIdx = idx; DropButton.Text = configs[idx].name; closeDropdown()
        end)
        item.MouseEnter:Connect(function() item.BackgroundColor3 = Color3.fromRGB(60,60,95) end)
        item.MouseLeave:Connect(function() item.BackgroundColor3 = Color3.fromRGB(40,40,65) end)
    end

    DropList.Size = UDim2.new(1,-20,0,#configs*30+4)
    selectedIdx = 1; DropButton.Text = configs[1].name
end

local function refreshConfigs()
    scanConfigs(); populateDropdown()
    if #configs == 0 then
        StatusLabel.Text = "● Drop .json TAS files into workspace/TAS_Recorder/"
        StatusLabel.TextColor3 = Color3.fromRGB(220,140,80)
    else
        StatusLabel.Text = "● Ready  ("..#configs.." config"..( #configs==1 and "" or "s")..")"
        StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
    end
end

DropButton.MouseButton1Click:Connect(function()
    if #configs == 0 then return end
    dropOpen = not dropOpen; DropList.Visible = dropOpen; DropArrow.Text = dropOpen and "▲" or "▼"
    local extra = dropOpen and (DropList.Size.Y.Offset+4) or 0
    MainFrame.Size         = UDim2.new(0,260,0,BASE_H+extra)
    RefreshButton.Position = UDim2.new(0,10,0,123+extra)
    RunButton.Position     = UDim2.new(0,48,0,123+extra)
end)

RefreshButton.MouseButton1Click:Connect(function()
    closeDropdown(); StatusLabel.Text = "● Refreshing..."; task.wait(0.05); refreshConfigs()
end)

-- ============================================================
-- START / STOP
-- ============================================================
local function updateUI()
    if isRunning then
        RunButton.Text             = "■  Stop"
        RunButton.BackgroundColor3 = Color3.fromRGB(200,60,60)
        StatusLabel.Text           = "↻ Looping: "..(configs[selectedIdx] and configs[selectedIdx].name or "?")
        StatusLabel.TextColor3     = Color3.fromRGB(100,220,120)
    else
        RunButton.Text             = "▶  Start"
        RunButton.BackgroundColor3 = Color3.fromRGB(60,180,100)
        if #configs > 0 then
            StatusLabel.Text       = "● Ready  ("..#configs.." config"..( #configs==1 and "" or "s")..")"
            StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
        end
    end
end

RunButton.MouseButton1Click:Connect(function()
    if isRunning then stopRun() else startRun() end
    updateUI()
end)

task.spawn(function()
    while true do task.wait(0.25); updateUI() end
end)

-- ============================================================
-- INIT
-- ============================================================
refreshConfigs()
print("[TAS] GUI ready. Folder: workspace/"..FOLDER.."/")
