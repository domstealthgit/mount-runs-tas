-- TAS Runner GUI
-- Multi-config looping with delay between runs.
-- Reads .json files saved by TAS Creator from: workspace/TAS_Recorder/

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Character   = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
Character:WaitForChild("HumanoidRootPart")
Character:WaitForChild("Humanoid")

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
local pausedIdx    = 1
local playConn     = nil
local configs      = {}        -- { name, path, selected, frames }
local delaySeconds = 0
local waitUntil    = 0         -- epoch when current delay expires

-- ============================================================
-- HUMANOID STATE MAP
-- ============================================================
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
-- MATH
-- ============================================================
local function CFrameToQuat(cf)
    local axis, angle = cf:ToAxisAngle()
    local s = math.sin(angle / 2)
    return axis.X*s, axis.Y*s, axis.Z*s, math.cos(angle/2)
end
local function QuatToCFrame(x,y,z,qX,qY,qZ,qW)
    return CFrame.new(x,y,z,qX,qY,qZ,qW)
end
local function normaliseCF(arr)
    if #arr == 7 then return arr end
    local cf
    if     #arr == 12 then cf = CFrame.new(table.unpack(arr))
    elseif #arr == 6  then cf = CFrame.new(arr[1],arr[2],arr[3]) * CFrame.fromEulerAnglesYXZ(arr[4],arr[5],arr[6])
    else return arr end
    local qX,qY,qZ,qW = CFrameToQuat(cf)
    return {cf.X,cf.Y,cf.Z,qX,qY,qZ,qW}
end

-- ============================================================
-- FILE HELPERS
-- ============================================================
local function scanConfigs()
    local prev = {}
    for _, c in ipairs(configs) do prev[c.name] = c.selected end
    configs = {}
    for _, path in ipairs(listfiles(FOLDER)) do
        local name = path:match("([^/\\]+)%.json$")
        if name then
            table.insert(configs, {
                name     = name,
                path     = path,
                selected = prev[name] or false,
                frames   = nil,
            })
        end
    end
    table.sort(configs, function(a,b) return a.name < b.name end)
end

local function loadFrames(cfg)
    if cfg.frames then return cfg.frames end
    local ok, raw = pcall(readfile, cfg.path)
    if not ok or not raw or raw == "" then warn("[TAS] Cannot read: "..cfg.path); return nil end
    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or type(data) ~= "table" then warn("[TAS] JSON error: "..cfg.path); return nil end
    local flat = {}
    for _, seg in ipairs(data[1] or {}) do
        for _, f in ipairs(seg) do
            if f.CF  then f.CF  = normaliseCF(f.CF)  end
            if f.CCF then f.CCF = normaliseCF(f.CCF) end
            table.insert(flat, f)
        end
    end
    for _, f in ipairs(data[2] or {}) do
        if f.CF  then f.CF  = normaliseCF(f.CF)  end
        if f.CCF then f.CCF = normaliseCF(f.CCF) end
        table.insert(flat, f)
    end
    table.sort(flat, function(a,b) return a.T < b.T end)
    cfg.frames = flat
    return flat
end

local function getSelectedConfigs()
    local sel = {}
    for _, c in ipairs(configs) do
        if c.selected then table.insert(sel, c) end
    end
    return sel
end

-- ============================================================
-- APPLY SINGLE FRAME  (freeze helper)
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
    waitUntil = 0
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
-- PLAYBACK  — cycles through selectedList in order, loops
-- ============================================================
local function startPlaybackLoop(selectedList, startConfigIdx, startFrameIdx)
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

    local cfgIdx     = startConfigIdx  -- which config in selectedList we're on
    local frames     = selectedList[cfgIdx].frames
    local currentIdx = startFrameIdx
    local startTime  = os.clock() - (frames[currentIdx] and frames[currentIdx].T or 0)

    -- Initial delay before very first frame of this config
    waitUntil = delaySeconds > 0 and (os.clock() + delaySeconds) or 0
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

        -- Waiting for delay
        if waitUntil > 0 then
            if os.clock() < waitUntil then return end
            root.Anchored = false
            startTime     = os.clock() - (frames[1].T or 0)
            currentIdx    = 1
            waitUntil     = 0
        end

        local elapsed = os.clock() - startTime
        while currentIdx < #frames
            and frames[currentIdx+1]
            and frames[currentIdx+1].T <= elapsed do
            currentIdx = currentIdx + 1
        end
        pausedIdx = currentIdx

        local fA = frames[currentIdx]
        local fB = frames[currentIdx + 1]

        if fB and fA.CF and fB.CF and fA.V and fB.V and fA.RV and fB.RV then
            local delta = fB.T - fA.T
            local alpha = delta > 0 and math.clamp((elapsed - fA.T) / delta, 0, 1) or 0

            root.CFrame = QuatToCFrame(table.unpack(fA.CF)):Lerp(
                          QuatToCFrame(table.unpack(fB.CF)), alpha)

            local curV  = Vector3.new(table.unpack(fA.V)):Lerp(
                          Vector3.new(table.unpack(fB.V)), alpha)
            local curRV = Vector3.new(table.unpack(fA.RV)):Lerp(
                          Vector3.new(table.unpack(fB.RV)), alpha)
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.Velocity    = curV
                    part.RotVelocity = curRV
                end
            end

            if hum and fA.HS then
                local tName = type(fA.HS)=="number" and ValToStateName[fA.HS] or fA.HS
                if tName and tName ~= "None" and hum:GetState().Name ~= tName then
                    local e = Enum.HumanoidStateType[tName]
                    if e then pcall(function() hum:ChangeState(e) end) end
                end
            end
        else
            -- This config finished → advance to next config (or wrap)
            if not isRunning then return end
            cfgIdx     = (cfgIdx % #selectedList) + 1
            frames     = selectedList[cfgIdx].frames
            currentIdx = 1
            pausedIdx  = 1
            applyFrame(frames[1])
            -- Delay before the next config's run
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
local activeSelectedList = nil
local function togglePause()
    if not isRunning or not activeSelectedList then return end
    isPaused = not isPaused
    if isPaused then
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        -- find which config we're currently in by cfgIdx — use pausedIdx on current frames
        -- just freeze in place
        if root then root.Anchored = true end
    else
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root then root.Anchored = false end
        -- Re-sync: find which config contains pausedIdx and resume from there
        -- Since playConn is still alive and isPaused just became false, it will resume naturally
        -- But we need to re-sync startTime. Re-call startPlaybackLoop from current state.
        startPlaybackLoop(activeSelectedList, 1, 1)
    end
end

-- ============================================================
-- START
-- ============================================================
local function startRun()
    if isRunning then return end
    local sel = getSelectedConfigs()
    if #sel == 0 then
        warn("[TAS] No configs selected.")
        return
    end
    -- Pre-load all selected configs
    for _, c in ipairs(sel) do
        local f = loadFrames(c)
        if not f or #f == 0 then
            warn("[TAS] Failed to load or empty: " .. c.name)
            return
        end
    end
    isRunning         = true
    isPaused          = false
    pausedIdx         = 1
    activeSelectedList = sel
    startPlaybackLoop(sel, 1, 1)
end

-- ============================================================
-- GUI  --------------------------------------------------------
-- ============================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = "TAS_GUI"
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent         = LocalPlayer:WaitForChild("PlayerGui")

local function corner(p, r)
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = p
end
local function makeLabel(parent, text, x, y, w, h, size, bold, col)
    local l = Instance.new("TextLabel")
    l.Text = text; l.Size = UDim2.new(0,w,0,h); l.Position = UDim2.new(0,x,0,y)
    l.BackgroundTransparency = 1; l.TextXAlignment = Enum.TextXAlignment.Left
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextSize = size or 11
    l.TextColor3 = col or Color3.fromRGB(160,160,200)
    l.Parent = parent; return l
end

-- Main frame — height grows with config list
local HEADER_H  = 32   -- title bar
local STATUS_H  = 28   -- status row
local CFGTITLE_H= 20   -- "Configs" label
local ITEM_H    = 26   -- per-config row
local DELAY_H   = 34   -- delay row
local BTN_H     = 36   -- button row
local PAD       = 8    -- top padding under title

local function calcHeight()
    return HEADER_H + PAD + STATUS_H + CFGTITLE_H + math.max(1,#configs)*ITEM_H + DELAY_H + BTN_H + 16
end

local MainFrame = Instance.new("Frame")
MainFrame.Name             = "MainFrame"
MainFrame.Size             = UDim2.new(0, 270, 0, calcHeight())
MainFrame.Position         = UDim2.new(0, 20, 0.5, -calcHeight()/2)
MainFrame.BackgroundColor3 = Color3.fromRGB(20,20,30)
MainFrame.BorderSizePixel  = 0
MainFrame.Active           = true
MainFrame.Draggable        = true
MainFrame.Parent           = ScreenGui
corner(MainFrame)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(80,80,130); stroke.Thickness = 1.5; stroke.Parent = MainFrame

-- Title bar
local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1,0,0,HEADER_H)
TitleBar.BackgroundColor3 = Color3.fromRGB(35,35,58)
TitleBar.BorderSizePixel = 0; TitleBar.Parent = MainFrame
corner(TitleBar)
local tf = Instance.new("Frame")
tf.Size = UDim2.new(1,0,0.5,0); tf.Position = UDim2.new(0,0,0.5,0)
tf.BackgroundColor3 = Color3.fromRGB(35,35,58); tf.BorderSizePixel = 0; tf.Parent = TitleBar
makeLabel(TitleBar, "⚡ TAS Runner", 10, 0, 240, HEADER_H, 13, true, Color3.fromRGB(200,200,255))

-- Status label  (dynamic Y, we'll set it after)
local StatusLabel = makeLabel(MainFrame, "● Scanning...", 10, HEADER_H+PAD, 250, STATUS_H, 11, false, Color3.fromRGB(140,140,180))

-- "Configs" section label
local cfgTitleY = HEADER_H + PAD + STATUS_H
makeLabel(MainFrame, "Configs  (select to include in loop)", 10, cfgTitleY, 250, CFGTITLE_H, 11, true, Color3.fromRGB(200,200,255))

-- Config list container (scrolling frame)
local listY = cfgTitleY + CFGTITLE_H
local ConfigList = Instance.new("ScrollingFrame")
ConfigList.Size                = UDim2.new(1,-16,0, math.max(1,#configs)*ITEM_H)
ConfigList.Position            = UDim2.new(0,8,0,listY)
ConfigList.BackgroundColor3    = Color3.fromRGB(28,28,42)
ConfigList.BorderSizePixel     = 0
ConfigList.ScrollBarThickness  = 4
ConfigList.CanvasSize          = UDim2.new(0,0,0,0)
ConfigList.AutomaticCanvasSize = Enum.AutomaticSize.Y
ConfigList.Parent              = MainFrame
corner(ConfigList, 6)

local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding   = UDim.new(0,2)
listLayout.Parent    = ConfigList

local listPad = Instance.new("UIPadding")
listPad.PaddingTop = UDim.new(0,2); listPad.PaddingBottom = UDim.new(0,2)
listPad.PaddingLeft = UDim.new(0,3); listPad.PaddingRight = UDim.new(0,3)
listPad.Parent = ConfigList

-- Delay row  (always below the config list)
local function delayRowY()
    return listY + ConfigList.Size.Y.Offset + 6
end

local DelayLabel = makeLabel(MainFrame, "Delay between runs (sec):", 10, delayRowY(), 165, DELAY_H, 11, false, Color3.fromRGB(160,160,200))

local DelayBox = Instance.new("TextBox")
DelayBox.Size = UDim2.new(0,60,0,26); DelayBox.Position = UDim2.new(0,180,0,delayRowY()+4)
DelayBox.BackgroundColor3 = Color3.fromRGB(40,40,65); DelayBox.BorderSizePixel = 0
DelayBox.Text = "0"; DelayBox.TextColor3 = Color3.fromRGB(220,220,255)
DelayBox.Font = Enum.Font.GothamBold; DelayBox.TextSize = 13
DelayBox.ClearTextOnFocus = false; DelayBox.Parent = MainFrame
corner(DelayBox, 6)

DelayBox.FocusLost:Connect(function()
    local n = tonumber(DelayBox.Text)
    delaySeconds = (n and n >= 0) and math.floor(n) or delaySeconds
    DelayBox.Text = tostring(delaySeconds)
end)

-- Button row
local function btnRowY()
    return delayRowY() + DELAY_H
end

local RefreshButton = Instance.new("TextButton")
RefreshButton.Size = UDim2.new(0,32,0,32); RefreshButton.Position = UDim2.new(0,8,0,btnRowY())
RefreshButton.BackgroundColor3 = Color3.fromRGB(50,50,82); RefreshButton.BorderSizePixel = 0
RefreshButton.Text = "↻"; RefreshButton.TextColor3 = Color3.fromRGB(200,200,255)
RefreshButton.Font = Enum.Font.GothamBold; RefreshButton.TextSize = 18; RefreshButton.Parent = MainFrame
corner(RefreshButton, 6)

local PauseButton = Instance.new("TextButton")
PauseButton.Size = UDim2.new(0,32,0,32); PauseButton.Position = UDim2.new(0,46,0,btnRowY())
PauseButton.BackgroundColor3 = Color3.fromRGB(50,50,82); PauseButton.BorderSizePixel = 0
PauseButton.Text = "⏸"; PauseButton.TextColor3 = Color3.fromRGB(200,200,255)
PauseButton.Font = Enum.Font.GothamBold; PauseButton.TextSize = 14; PauseButton.Parent = MainFrame
corner(PauseButton, 6)

local RunButton = Instance.new("TextButton")
RunButton.Size = UDim2.new(1,-88,0,32); RunButton.Position = UDim2.new(0,84,0,btnRowY())
RunButton.BackgroundColor3 = Color3.fromRGB(60,180,100); RunButton.BorderSizePixel = 0
RunButton.Text = "▶  Start"; RunButton.TextColor3 = Color3.fromRGB(255,255,255)
RunButton.Font = Enum.Font.GothamBold; RunButton.TextSize = 13; RunButton.Parent = MainFrame
corner(RunButton, 6)

-- ============================================================
-- REBUILD CONFIG LIST  (called after scan or toggle)
-- ============================================================
local function rebuildConfigList()
    for _, c in ipairs(ConfigList:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end

    local maxVisible = 5   -- scroll after this many
    local visibleH   = math.min(#configs, maxVisible) * ITEM_H + 4
    ConfigList.Size  = UDim2.new(1,-16,0, math.max(ITEM_H, visibleH))

    for i, cfg in ipairs(configs) do
        local row = Instance.new("Frame")
        row.Size             = UDim2.new(1,0,0,ITEM_H-2)
        row.BackgroundColor3 = cfg.selected and Color3.fromRGB(45,55,80) or Color3.fromRGB(35,35,55)
        row.BorderSizePixel  = 0
        row.LayoutOrder      = i
        row.Parent           = ConfigList
        corner(row, 5)

        -- Checkbox indicator
        local chk = Instance.new("TextLabel")
        chk.Size = UDim2.new(0,18,0,18); chk.Position = UDim2.new(0,4,0.5,-9)
        chk.BackgroundColor3 = cfg.selected and Color3.fromRGB(60,180,100) or Color3.fromRGB(55,55,75)
        chk.BorderSizePixel  = 0
        chk.Text             = cfg.selected and "✓" or ""
        chk.TextColor3       = Color3.fromRGB(255,255,255)
        chk.Font             = Enum.Font.GothamBold; chk.TextSize = 11
        chk.Parent           = row
        corner(chk, 4)

        -- Name label
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1,-28,1,0); lbl.Position = UDim2.new(0,26,0,0)
        lbl.BackgroundTransparency = 1
        lbl.Text = cfg.name
        lbl.TextColor3 = cfg.selected and Color3.fromRGB(220,220,255) or Color3.fromRGB(150,150,180)
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Font = cfg.selected and Enum.Font.GothamBold or Enum.Font.Gotham
        lbl.TextSize = 12; lbl.TextTruncate = Enum.TextTruncate.AtEnd
        lbl.Parent = row

        -- Click to toggle
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1,0,1,0); btn.BackgroundTransparency = 1
        btn.Text = ""; btn.Parent = row
        local idx = i
        btn.MouseButton1Click:Connect(function()
            configs[idx].selected = not configs[idx].selected
            configs[idx].frames   = nil   -- invalidate cache so it reloads fresh
            rebuildConfigList()
            -- resize main frame
            MainFrame.Size = UDim2.new(0,270,0,calcHeight())
            DelayLabel.Position  = UDim2.new(0,10,0,delayRowY())
            DelayBox.Position    = UDim2.new(0,180,0,delayRowY()+4)
            RefreshButton.Position = UDim2.new(0,8,0,btnRowY())
            PauseButton.Position   = UDim2.new(0,46,0,btnRowY())
            RunButton.Position     = UDim2.new(0,84,0,btnRowY())
        end)
        btn.MouseEnter:Connect(function() row.BackgroundColor3 = Color3.fromRGB(55,55,85) end)
        btn.MouseLeave:Connect(function()
            row.BackgroundColor3 = configs[idx].selected and Color3.fromRGB(45,55,80) or Color3.fromRGB(35,35,55)
        end)
    end
end

local function refreshAll()
    scanConfigs()
    rebuildConfigList()
    MainFrame.Size = UDim2.new(0,270,0,calcHeight())
    DelayLabel.Position    = UDim2.new(0,10,0,delayRowY())
    DelayBox.Position      = UDim2.new(0,180,0,delayRowY()+4)
    RefreshButton.Position = UDim2.new(0,8,0,btnRowY())
    PauseButton.Position   = UDim2.new(0,46,0,btnRowY())
    RunButton.Position     = UDim2.new(0,84,0,btnRowY())

    local sel = getSelectedConfigs()
    if #configs == 0 then
        StatusLabel.Text       = "● Drop .json files into workspace/TAS_Recorder/"
        StatusLabel.TextColor3 = Color3.fromRGB(220,140,80)
    elseif #sel == 0 then
        StatusLabel.Text       = "● " .. #configs .. " config(s) found — tick to select"
        StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
    else
        StatusLabel.Text       = "● " .. #sel .. " selected  (" .. #configs .. " total)"
        StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
    end
end

-- ============================================================
-- UI UPDATE
-- ============================================================
local function updateUI()
    local sel = getSelectedConfigs()
    if not isRunning then
        RunButton.Text             = "▶  Start"
        RunButton.BackgroundColor3 = Color3.fromRGB(60,180,100)
        PauseButton.BackgroundColor3 = Color3.fromRGB(50,50,82)
        PauseButton.Text           = "⏸"
        if #configs == 0 then
            StatusLabel.Text       = "● Drop .json files into workspace/TAS_Recorder/"
            StatusLabel.TextColor3 = Color3.fromRGB(220,140,80)
        elseif #sel == 0 then
            StatusLabel.Text       = "● " .. #configs .. " config(s) — tick to select"
            StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
        else
            StatusLabel.Text       = "● " .. #sel .. " selected  (" .. #configs .. " total)"
            StatusLabel.TextColor3 = Color3.fromRGB(140,140,180)
        end
    elseif isPaused then
        RunButton.Text             = "■  Stop"
        RunButton.BackgroundColor3 = Color3.fromRGB(200,60,60)
        PauseButton.Text           = "▶"
        PauseButton.BackgroundColor3 = Color3.fromRGB(200,150,30)
        StatusLabel.Text           = "⏸ Paused"
        StatusLabel.TextColor3     = Color3.fromRGB(255,200,80)
    elseif waitUntil > 0 then
        local left = math.ceil(waitUntil - os.clock())
        RunButton.Text             = "■  Stop"
        RunButton.BackgroundColor3 = Color3.fromRGB(200,60,60)
        PauseButton.Text           = "⏸"
        PauseButton.BackgroundColor3 = Color3.fromRGB(50,50,82)
        StatusLabel.Text           = "⏳ Next run in " .. math.max(0,left) .. "s..."
        StatusLabel.TextColor3     = Color3.fromRGB(255,200,80)
    else
        RunButton.Text             = "■  Stop"
        RunButton.BackgroundColor3 = Color3.fromRGB(200,60,60)
        PauseButton.Text           = "⏸"
        PauseButton.BackgroundColor3 = Color3.fromRGB(50,50,82)
        StatusLabel.Text           = "↻ Running loop"
        StatusLabel.TextColor3     = Color3.fromRGB(100,220,120)
    end
end

-- ============================================================
-- BUTTON WIRING
-- ============================================================
RefreshButton.MouseButton1Click:Connect(function()
    StatusLabel.Text = "● Refreshing..."; task.wait(0.05); refreshAll()
end)

PauseButton.MouseButton1Click:Connect(function()
    if not isRunning then return end
    isPaused = not isPaused
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if isPaused then
        if root then root.Anchored = true end
    else
        if root then root.Anchored = false end
        -- Re-sync startTime for the current config so it resumes smoothly
        if activeSelectedList then
            startPlaybackLoop(activeSelectedList, 1, 1)
        end
    end
    updateUI()
end)

RunButton.MouseButton1Click:Connect(function()
    if isRunning then stopRun() else startRun() end
    updateUI()
end)

task.spawn(function()
    while true do task.wait(0.2); updateUI() end
end)

-- ============================================================
-- INIT
-- ============================================================
refreshAll()
print("[TAS] GUI ready — workspace/" .. FOLDER .. "/")
