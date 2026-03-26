-- TAS Runner GUI
-- Reads .json files saved by TAS Creator from: workspace/TAS_Recorder/
-- Features: looping playback, pause/resume at exact frame, start delay countdown.

local HttpService  = game:GetService("HttpService")
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")

local LocalPlayer      = Players.LocalPlayer
local Character        = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")
local Humanoid         = Character:WaitForChild("Humanoid")

-- ============================================================
-- FOLDER
-- ============================================================
local FOLDER = "TAS_Recorder"
if not isfolder(FOLDER) then
    makefolder(FOLDER)
    print("[TAS] Created folder: workspace/" .. FOLDER .. "/")
end

-- ============================================================
-- STATE
-- ============================================================
local isRunning    = false
local isPaused     = false
local pausedIdx    = 1      -- frame index we froze at
local playConn     = nil
local configs      = {}
local selectedIdx  = 1
local dropOpen     = false
local delaySeconds = 0      -- countdown before playback starts

local KeepEnabledStates = {
    [Enum.HumanoidStateType.Dead]      = true,
    [Enum.HumanoidStateType.GettingUp] = true,
    [Enum.HumanoidStateType.Landed]    = true,
    [Enum.HumanoidStateType.None]      = true,
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

local function normaliseCF(arr)
    if #arr == 7 then return arr end
    local cf
    if #arr == 12 then
        cf = CFrame.new(table.unpack(arr))
    elseif #arr == 6 then
        cf = CFrame.new(arr[1], arr[2], arr[3]) * CFrame.fromEulerAnglesYXZ(arr[4], arr[5], arr[6])
    else
        return arr
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
        warn("[TAS] Cannot read: " .. cfg.path); return nil
    end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or type(data) ~= "table" then
        warn("[TAS] JSON error in: " .. cfg.path); return nil
    end
    return data
end

local function flattenFrames(data)
    local flat = {}
    for _, segment in ipairs(data[1] or {}) do
        for _, frame in ipairs(segment) do
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
-- APPLY A SINGLE FRAME  (used for freeze-on-pause)
-- ============================================================
local function applyFrame(frame)
    if not frame or not frame.CF then return end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    root.CFrame = QuatToCFrame(table.unpack(frame.CF))
    local vel = frame.V and Vector3.new(table.unpack(frame.V)) or Vector3.zero
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            part.Velocity    = vel
            part.RotVelocity = Vector3.zero
        end
    end
end

-- ============================================================
-- STOP
-- ============================================================
local function stopRun()
    isRunning = false
    isPaused  = false
    pausedIdx = 1
    if playConn then playConn:Disconnect(); playConn = nil end
    local char = LocalPlayer.Character
    if char then
        local hum  = char:FindFirstChild("Humanoid")
        local root = char:FindFirstChild("HumanoidRootPart")
        if hum then
            for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
                pcall(function() hum:SetStateEnabled(state, true) end)
            end
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end
        if root then root.Anchored = false end
    end
end

-- ============================================================
-- PLAYBACK LOOP  (starts from startIdx, loops when done)
-- ============================================================
local function startPlaybackLoop(frames, startIdx)
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum  = char and char:FindFirstChild("Humanoid")
    if not root then isRunning = false; return end

    root.Anchored = false
    if hum then
        for _, state in ipairs(Enum.HumanoidStateType:GetEnumItems()) do
            if not KeepEnabledStates[state] then
                pcall(function() hum:SetStateEnabled(state, false) end)
            end
        end
    end

    -- Offset startTime so elapsed matches frames[startIdx].T
    local startTime  = os.clock() - (frames[startIdx] and frames[startIdx].T or 0)
    local currentIdx = startIdx

    -- waitUntil > 0 means we are frozen at frame 1 waiting for the delay
    local waitUntil = (delaySeconds > 0) and (os.clock() + delaySeconds) or 0

    -- Freeze at frame 1 for the initial delay
    if waitUntil > 0 then
        applyFrame(frames[1])
        if root then root.Anchored = true end
    end

    if playConn then playConn:Disconnect() end

    playConn = RunService.Heartbeat:Connect(function()
        if not isRunning or isPaused then return end

        char = LocalPlayer.Character
        root = char and char:FindFirstChild("HumanoidRootPart")
        hum  = char and char:FindFirstChild("Humanoid")
        if not root then return end

        -- Sitting at frame 1 waiting for delay to expire
        if waitUntil > 0 then
            if os.clock() < waitUntil then return end
            -- Delay over: unanchor and sync the timer
            root.Anchored = false
            startTime     = os.clock() - (frames[1].T or 0)
            waitUntil     = 0
        end

        local elapsed = os.clock() - startTime

        while currentIdx < #frames and frames[currentIdx + 1] and frames[currentIdx + 1].T <= elapsed do
            currentIdx = currentIdx + 1
        end

        -- Store current index so pause can freeze here
        pausedIdx = currentIdx

        local fA = frames[currentIdx]
        local fB = frames[currentIdx + 1]

        if fB and fA.CF and fB.CF and fA.V and fB.V and fA.RV and fB.RV then
            local delta = fB.T - fA.T
            local alpha = delta > 0 and math.clamp((elapsed - fA.T) / delta, 0, 1) or 0

            root.CFrame = QuatToCFrame(table.unpack(fA.CF)):Lerp(QuatToCFrame(table.unpack(fB.CF)), alpha)

            local curV  = Vector3.new(table.unpack(fA.V)):Lerp(Vector3.new(table.unpack(fB.V)),   alpha)
            local curRV = Vector3.new(table.unpack(fA.RV)):Lerp(Vector3.new(table.unpack(fB.RV)), alpha)
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.Velocity    = curV
                    part.RotVelocity = curRV
                end
            end

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
            -- End of run → freeze at frame 1, wait delay, then loop
            if not isRunning then return end
            currentIdx = 1
            pausedIdx  = 1
            applyFrame(frames[1])
            if delaySeconds > 0 then
                if root then root.Anchored = true end
                waitUntil = os.clock() + delaySeconds
            else
                waitUntil = 0
                startTime = os.clock() - (frames[1].T or 0)
            end
        end
    end)
end

-- ============================================================
-- PAUSE / RESUME
-- ============================================================
local function togglePause(frames)
    if not isRunning then return end
    isPaused = not isPaused
    if isPaused then
        -- Freeze character at current frame
        applyFrame(frames[pausedIdx])
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then root.Anchored = true end
    else
        -- Resume: re-anchor off and re-sync startTime to current pausedIdx frame
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then root.Anchored = false end
        -- Restart loop from the frozen frame
        startPlaybackLoop(frames, pausedIdx)
    end
end

-- ============================================================
-- START  (with optional countdown)
-- ============================================================
local activeFrames = nil   -- keep reference for pause button

local function startRun(StatusLabel, PauseButton)
    if isRunning or #configs == 0 then return end
    local cfg  = configs[selectedIdx]
    local data = loadConfig(cfg)
    if not data then return end
    local frames = flattenFrames(data)
    if #frames == 0 then warn("[TAS] No frames in: " .. cfg.name); return end

    activeFrames = frames
    isRunning    = true
    isPaused     = false
    pausedIdx    = 1

    task.spawn(function()
        -- Countdown
        if delaySeconds > 0 then
            for i = delaySeconds, 1, -1 do
                if not isRunning then return end
                StatusLabel.Text       = "▶ Starting in " .. i .. "s..."
                StatusLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
                task.wait(1)
            end
        end
        if not isRunning then return end
        startPlaybackLoop(frames, 1)
    end)
end

-- ============================================================
-- GUI
-- ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = "TAS_GUI"
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent         = LocalPlayer:WaitForChild("PlayerGui")

local BASE_H = 200   -- taller to fit extra controls

local MainFrame = Instance.new("Frame")
MainFrame.Name             = "MainFrame"
MainFrame.Size             = UDim2.new(0, 260, 0, BASE_H)
MainFrame.Position         = UDim2.new(0, 20, 0.5, -100)
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
stroke.Color = Color3.fromRGB(80,80,130); stroke.Thickness = 1.5; stroke.Parent = MainFrame

-- Title bar
local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1,0,0,32); TitleBar.BackgroundColor3 = Color3.fromRGB(35,35,58)
TitleBar.BorderSizePixel = 0; TitleBar.Parent = MainFrame
corner(TitleBar)
local tf = Instance.new("Frame")
tf.Size = UDim2.new(1,0,0.5,0); tf.Position = UDim2.new(0,0,0.5,0)
tf.BackgroundColor3 = Color3.fromRGB(35,35,58); tf.BorderSizePixel = 0; tf.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Text = "⚡ TAS Runner"; TitleLabel.Size = UDim2.new(1,-10,1,0); TitleLabel.Position = UDim2.new(0,10,0,0)
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

-- ── Delay row  (label + text box) ───────────────────────────
local DelayLabel = Instance.new("TextLabel")
DelayLabel.Text = "Start delay (sec):"
DelayLabel.Size = UDim2.new(0,110,0,26); DelayLabel.Position = UDim2.new(0,10,0,123)
DelayLabel.BackgroundTransparency = 1; DelayLabel.TextXAlignment = Enum.TextXAlignment.Left
DelayLabel.Font = Enum.Font.Gotham; DelayLabel.TextSize = 11
DelayLabel.TextColor3 = Color3.fromRGB(160,160,200); DelayLabel.Parent = MainFrame

local DelayBox = Instance.new("TextBox")
DelayBox.Size = UDim2.new(0,60,0,26); DelayBox.Position = UDim2.new(0,125,0,123)
DelayBox.BackgroundColor3 = Color3.fromRGB(40,40,65); DelayBox.BorderSizePixel = 0
DelayBox.Text = "0"; DelayBox.TextColor3 = Color3.fromRGB(220,220,255)
DelayBox.Font = Enum.Font.GothamBold; DelayBox.TextSize = 13
DelayBox.ClearTextOnFocus = false; DelayBox.Parent = MainFrame
corner(DelayBox, 6)

DelayBox.FocusLost:Connect(function()
    local n = tonumber(DelayBox.Text)
    if n and n >= 0 then
        delaySeconds = math.floor(n)
        DelayBox.Text = tostring(delaySeconds)
    else
        DelayBox.Text = tostring(delaySeconds)
    end
end)

-- ── Button row: Refresh | Pause | Start/Stop ────────────────
local RefreshButton = Instance.new("TextButton")
RefreshButton.Size = UDim2.new(0,32,0,32); RefreshButton.Position = UDim2.new(0,10,0,158)
RefreshButton.BackgroundColor3 = Color3.fromRGB(50,50,82); RefreshButton.BorderSizePixel = 0
RefreshButton.Text = "↻"; RefreshButton.TextColor3 = Color3.fromRGB(200,200,255)
RefreshButton.Font = Enum.Font.GothamBold; RefreshButton.TextSize = 18; RefreshButton.Parent = MainFrame
corner(RefreshButton, 6)

local PauseButton = Instance.new("TextButton")
PauseButton.Size = UDim2.new(0,32,0,32); PauseButton.Position = UDim2.new(0,48,0,158)
PauseButton.BackgroundColor3 = Color3.fromRGB(50,50,82); PauseButton.BorderSizePixel = 0
PauseButton.Text = "⏸"; PauseButton.TextColor3 = Color3.fromRGB(200,200,255)
PauseButton.Font = Enum.Font.GothamBold; PauseButton.TextSize = 14; PauseButton.Parent = MainFrame
corner(PauseButton, 6)

local RunButton = Instance.new("TextButton")
RunButton.Size = UDim2.new(1,-90,0,32); RunButton.Position = UDim2.new(0,86,0,158)
RunButton.BackgroundColor3 = Color3.fromRGB(60,180,100); RunButton.BorderSizePixel = 0
RunButton.Text = "▶  Start"; RunButton.TextColor3 = Color3.fromRGB(255,255,255)
RunButton.Font = Enum.Font.GothamBold; RunButton.TextSize = 13; RunButton.Parent = MainFrame
corner(RunButton, 6)

-- ============================================================
-- DROPDOWN LOGIC
-- ============================================================
local function closeDropdown()
    dropOpen = false; DropList.Visible = false; DropArrow.Text = "▼"
    MainFrame.Size         = UDim2.new(0,260,0,BASE_H)
    RefreshButton.Position = UDim2.new(0,10,0,158)
    PauseButton.Position   = UDim2.new(0,48,0,158)
    RunButton.Position     = UDim2.new(0,86,0,158)
    DelayLabel.Position    = UDim2.new(0,10,0,123)
    DelayBox.Position      = UDim2.new(0,125,0,123)
end

local function populateDropdown()
    for _, c in ipairs(DropList:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    if #configs == 0 then DropButton.Text = "No configs found"; return end

    for i, cfg in ipairs(configs) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1,0,0,28); item.BackgroundColor3 = Color3.fromRGB(40,40,65)
        item.BorderSizePixel = 0; item.Text = "  " .. cfg.name
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
        StatusLabel.Text = "● Ready  (" .. #configs .. " config" .. (#configs==1 and "" or "s") .. ")"
        StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
    end
end

DropButton.MouseButton1Click:Connect(function()
    if #configs == 0 then return end
    dropOpen = not dropOpen; DropList.Visible = dropOpen; DropArrow.Text = dropOpen and "▲" or "▼"
    local extra = dropOpen and (DropList.Size.Y.Offset + 4) or 0
    MainFrame.Size         = UDim2.new(0,260,0,BASE_H+extra)
    DelayLabel.Position    = UDim2.new(0,10,0,123+extra)
    DelayBox.Position      = UDim2.new(0,125,0,123+extra)
    RefreshButton.Position = UDim2.new(0,10,0,158+extra)
    PauseButton.Position   = UDim2.new(0,48,0,158+extra)
    RunButton.Position     = UDim2.new(0,86,0,158+extra)
end)

RefreshButton.MouseButton1Click:Connect(function()
    closeDropdown(); StatusLabel.Text = "● Refreshing..."; task.wait(0.05); refreshConfigs()
end)

-- ============================================================
-- UI UPDATE
-- ============================================================
local function updateUI()
    if not isRunning then
        RunButton.Text             = "▶  Start"
        RunButton.BackgroundColor3 = Color3.fromRGB(60,180,100)
        PauseButton.BackgroundColor3 = Color3.fromRGB(50,50,82)
        PauseButton.Text           = "⏸"
        if #configs > 0 then
            StatusLabel.Text       = "● Ready  (" .. #configs .. " config" .. (#configs==1 and "" or "s") .. ")"
            StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
        end
    elseif isPaused then
        RunButton.Text             = "■  Stop"
        RunButton.BackgroundColor3 = Color3.fromRGB(200,60,60)
        PauseButton.Text           = "▶"
        PauseButton.BackgroundColor3 = Color3.fromRGB(200,150,30)
        StatusLabel.Text           = "⏸ Paused  [frame " .. pausedIdx .. "]"
        StatusLabel.TextColor3     = Color3.fromRGB(255,200,80)
    else
        RunButton.Text             = "■  Stop"
        RunButton.BackgroundColor3 = Color3.fromRGB(200,60,60)
        PauseButton.Text           = "⏸"
        PauseButton.BackgroundColor3 = Color3.fromRGB(50,50,82)
        StatusLabel.Text           = "↻ Looping: " .. (configs[selectedIdx] and configs[selectedIdx].name or "?")
        StatusLabel.TextColor3     = Color3.fromRGB(100,220,120)
    end
end

-- ============================================================
-- BUTTON WIRING
-- ============================================================
PauseButton.MouseButton1Click:Connect(function()
    if not isRunning then return end
    togglePause(activeFrames)
    updateUI()
end)

RunButton.MouseButton1Click:Connect(function()
    if isRunning then
        stopRun()
    else
        startRun(StatusLabel, PauseButton)
    end
    updateUI()
end)

task.spawn(function()
    while true do task.wait(0.25); updateUI() end
end)

-- ============================================================
-- INIT
-- ============================================================
refreshConfigs()
print("[TAS] GUI ready. Folder: workspace/" .. FOLDER .. "/")
