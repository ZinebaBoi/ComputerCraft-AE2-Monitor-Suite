-- ME Network Energy Monitor
-- Uses the ME Bridge from Advanced Peripherals to display
-- energy usage history and stored capacity.

-- CONFIGURATION
local POLL_INTERVAL = 2.0  -- Update interval in seconds
local MONITOR_SCALE = 1.0  -- Text size on monitors (1.0 = normal, 1.5 or 2.0 = larger)

-- Connect to ME Bridge
local me
while not me do
    me = peripheral.find("meBridge")
    if not me then
        term.clear()
        term.setCursorPos(1, 1)
        print("Error: ME Bridge peripheral not found!")
        print("Please connect an ME Bridge and restart, or wait...")
        sleep(5)
    end
end

-- Active device tracking (monitor vs local terminal)
local activeDevice = nil
local activeDeviceName = nil

local function updateDisplayDevice()
    local monitor = peripheral.find("monitor")
    local dev = monitor or term
    local devName = monitor and peripheral.getName(monitor) or "terminal"
    
    if devName ~= activeDeviceName then
        if activeDevice then
            pcall(function()
                activeDevice.clear()
                activeDevice.setCursorPos(1, 1)
            end)
        end
        
        activeDevice = dev
        activeDeviceName = devName
        
        activeDevice.clear()
        activeDevice.setCursorPos(1, 1)
        if devName ~= "terminal" then
            pcall(function() activeDevice.setTextScale(MONITOR_SCALE) end)
        end
    end
    return activeDevice, (devName ~= "terminal")
end

-- Helper to format energy counts
local function formatEnergy(val, unit)
    if val >= 1000000000 then
        return string.format("%.2fG %s", val / 1000000000, unit)
    elseif val >= 1000000 then
        return string.format("%.2fM %s", val / 1000000, unit)
    elseif val >= 1000 then
        return string.format("%.1fk %s", val / 1000, unit)
    else
        return string.format("%.0f %s", val, unit)
    end
end

-- Generate hex character color map for blit drawing
local hexColorMap = {}
for i = 0, 15 do
    local val = 2^i
    hexColorMap[val] = string.format("%x", i)
end

-- Write a full-width line via blit (zero flicker)
-- text: the visible string, padded to width w
-- fgColor / bgColor: single color value applied to the whole line
local function blitLine(device, y, w, text, fgColor, bgColor)
    local padded = text .. string.rep(" ", w - #text)
    padded = padded:sub(1, w)
    local fg = string.rep(hexColorMap[fgColor], w)
    local bg = string.rep(hexColorMap[bgColor], w)
    device.setCursorPos(1, y)
    device.blit(padded, fg, bg)
end

-- Write a full-width line with two colored segments via blit (zero flicker)
-- seg1/seg2: text strings; col1/col2: fg colors for each segment
local function blitTwoColor(device, y, w, seg1, col1, seg2, col2, bgColor)
    local full = seg1 .. seg2
    local padded = full .. string.rep(" ", w - #full)
    padded = padded:sub(1, w)
    local fgStr = string.rep(hexColorMap[col1], #seg1)
              .. string.rep(hexColorMap[col2], w - #seg1)
    local bgStr = string.rep(hexColorMap[bgColor], w)
    device.setCursorPos(1, y)
    device.blit(padded, fgStr, bgStr)
end

-- Build a full-width storage bar as a blit triple (text, fg, bg)
local function buildStorageBarBlit(w, stored, maxVal, isColor)
    local percent = 0.0
    if maxVal > 0 then percent = stored / maxVal end
    if percent > 1.0 then percent = 1.0 end
    if percent < 0.0 then percent = 0.0 end
    
    local label = "Stored: "
    local pctStr = string.format(" %.1f%%", percent * 100)
    local barW = w - (#label + #pctStr)
    
    if barW < 5 then
        local line = label .. formatEnergy(stored, "AE") .. pctStr
        line = line .. string.rep(" ", w - #line)
        line = line:sub(1, w)
        return line, string.rep(hexColorMap[colors.white], w), string.rep(hexColorMap[colors.black], w)
    end
    
    local innerW = barW - 2
    local fillW = math.floor(innerW * percent + 0.5)
    local emptyW = innerW - fillW
    
    -- Build text
    local text = label .. "[" .. string.rep(" ", fillW) .. string.rep(" ", emptyW) .. "]" .. pctStr
    text = text .. string.rep(" ", w - #text)
    text = text:sub(1, w)
    
    -- Build fg colors
    local fgStr = string.rep(hexColorMap[colors.white], #label + 1) -- "Stored: ["
    if isColor then
        fgStr = fgStr .. string.rep(hexColorMap[colors.white], fillW + emptyW)
    else
        fgStr = fgStr .. string.rep(hexColorMap[colors.yellow], fillW)
        fgStr = fgStr .. string.rep(hexColorMap[colors.white], emptyW)
    end
    fgStr = fgStr .. string.rep(hexColorMap[colors.white], w - #fgStr)
    fgStr = fgStr:sub(1, w)
    
    -- Build bg colors
    local bgStr = string.rep(hexColorMap[colors.black], #label + 1) -- "Stored: ["
    if isColor then
        local barColor = colors.lime
        if percent < 0.2 then barColor = colors.red
        elseif percent < 0.5 then barColor = colors.orange end
        bgStr = bgStr .. string.rep(hexColorMap[barColor], fillW)
        bgStr = bgStr .. string.rep(hexColorMap[colors.gray], emptyW)
    else
        bgStr = bgStr .. string.rep(hexColorMap[colors.black], fillW + emptyW)
    end
    bgStr = bgStr .. string.rep(hexColorMap[colors.black], w - #bgStr)
    bgStr = bgStr:sub(1, w)
    
    -- For non-color, put = signs in the fill area
    if not isColor then
        local before = label .. "["
        local chars = {}
        for ci = 1, #text do chars[ci] = text:sub(ci, ci) end
        for ci = #before + 1, #before + fillW do
            chars[ci] = "="
        end
        text = table.concat(chars)
    end
    
    return text, fgStr, bgStr
end

-- History array of energy usage
local usageHistory = {}

-- Main Loop
term.clear()
term.setCursorPos(1, 1)
print("ME Energy Monitor running...")
print("Updating display in the background...")

while true do
    local device, isMon = updateDisplayDevice()
    local w, h = device.getSize()
    local isColor = device.isColor()
    
    -- Row 1: Title
    local title = "ME ENERGY NETWORK"
    local pad = math.floor((w - #title) / 2)
    local titleLine = string.rep(" ", pad) .. title .. string.rep(" ", w - #title - pad)
    local titleFg = isColor and colors.cyan or colors.white
    blitLine(device, 1, w, titleLine, titleFg, colors.black)
    
    -- Row 2: blank spacer
    blitLine(device, 2, w, "", colors.white, colors.black)
    
    -- Fetch current energy stats
    local currentUsage, err1 = me.getEnergyUsage()
    local storedEnergy, err2 = me.getEnergyStorage()
    local maxEnergy, err3 = me.getMaxEnergyStorage()
    
    if not currentUsage or not storedEnergy or not maxEnergy then
        local errMsg = "ME Error: " .. tostring(err1 or err2 or err3 or "Unknown")
        blitLine(device, 3, w, errMsg, colors.red, colors.black)
        sleep(5)
    else
        -- Layout
        local barY, graphTitleY, topY, bottomY
        if h >= 18 then
            -- Row 3: Usage, Row 4: Stored, Row 5: Max, Row 6: blank, Row 7: bar, Row 8: blank, Row 9: graph title
            barY = 7
            graphTitleY = 9
            topY = 11
            bottomY = h - 1
        else
            barY = 4
            graphTitleY = 5
            topY = 7
            bottomY = h - 1
        end
        
        local graphH = bottomY - topY + 1
        local graphLeftX = 3
        local graphRightX = w - 2
        local graphW = graphRightX - graphLeftX + 1
        
        table.insert(usageHistory, currentUsage)
        while #usageHistory > graphW do
            table.remove(usageHistory, 1)
        end
        
        -- Draw stats
        if h >= 18 then
            local lbl1 = "Current Usage: "
            local val1 = formatEnergy(currentUsage, "AE/t")
            blitTwoColor(device, 3, w, lbl1, colors.white, val1, colors.lime, colors.black)
            
            local lbl2 = "Stored Energy: "
            local val2 = formatEnergy(storedEnergy, "AE")
            blitTwoColor(device, 4, w, lbl2, colors.white, val2, colors.yellow, colors.black)
            
            local lbl3 = "Max Capacity:  "
            local val3 = formatEnergy(maxEnergy, "AE")
            blitTwoColor(device, 5, w, lbl3, colors.white, val3, colors.lightGray, colors.black)
            
            blitLine(device, 6, w, "", colors.white, colors.black)
        else
            local lbl = "Usage: "
            local val = formatEnergy(currentUsage, "AE/t")
            local extra = ""
            local extraCol = colors.white
            if w >= 32 then
                extra = "  Stored: " .. formatEnergy(storedEnergy, "AE")
                extraCol = colors.yellow
            end
            -- Build a three-segment blit
            local full = lbl .. val .. extra
            local padded = full .. string.rep(" ", w - #full)
            padded = padded:sub(1, w)
            local fgStr = string.rep(hexColorMap[colors.white], #lbl)
                       .. string.rep(hexColorMap[colors.lime], #val)
                       .. string.rep(hexColorMap[extraCol], w - #lbl - #val)
            fgStr = fgStr:sub(1, w)
            local bgStr = string.rep(hexColorMap[colors.black], w)
            device.setCursorPos(1, 3)
            device.blit(padded, fgStr, bgStr)
        end
        
        -- Storage bar
        local barText, barFg, barBg = buildStorageBarBlit(w, storedEnergy, maxEnergy, isColor)
        device.setCursorPos(1, barY)
        device.blit(barText, barFg, barBg)
        
        -- Blank row after bar (if large layout)
        if h >= 18 then
            blitLine(device, 8, w, "", colors.white, colors.black)
        end
        
        -- Blank row before graph title (if small layout uses row 5 for title, row 6 is blank)
        if h < 18 then
            blitLine(device, 6, w, "", colors.white, colors.black)
        end
        
        -- Calculate min and max for graph scaling
        local minVal = math.huge
        local maxVal = -math.huge
        for _, val in ipairs(usageHistory) do
            if val < minVal then minVal = val end
            if val > maxVal then maxVal = val end
        end
        if minVal == math.huge then
            minVal = 0
            maxVal = 100
        elseif maxVal == minVal then
            local v = minVal
            minVal = math.max(0, v - 10)
            maxVal = v + 10
        end
        
        -- Graph title row with max label (single blit)
        local maxLabel = "Max: " .. formatEnergy(maxVal, "AE/t")
        local titleText = w >= 35 and "Usage History" or "Usage"
        -- Build the line: "  Max: xxxx          Usage History"
        local titlePad = w - 2 - #maxLabel - #titleText
        if titlePad < 1 then titlePad = 1 end
        local graphTitleFull = "  " .. maxLabel .. string.rep(" ", titlePad) .. titleText
        graphTitleFull = graphTitleFull .. string.rep(" ", w - #graphTitleFull)
        graphTitleFull = graphTitleFull:sub(1, w)
        -- Build fg: spaces=gray, "Max: "=gray, value=red, spaces=gray, title=gray
        local gtFg = string.rep(hexColorMap[colors.lightGray], 2)   -- leading spaces
                  .. string.rep(hexColorMap[colors.lightGray], 5)   -- "Max: "
                  .. string.rep(hexColorMap[colors.red], #maxLabel - 5)  -- value
                  .. string.rep(hexColorMap[colors.lightGray], w - 2 - #maxLabel)
        gtFg = gtFg:sub(1, w)
        local gtBg = string.rep(hexColorMap[colors.black], w)
        device.setCursorPos(1, graphTitleY)
        device.blit(graphTitleFull, gtFg, gtBg)
        
        -- Blank row between title and graph if needed
        if graphTitleY + 1 < topY then
            for blankY = graphTitleY + 1, topY - 1 do
                blitLine(device, blankY, w, "", colors.white, colors.black)
            end
        end
        
        -- Draw Graph Area (full-width blit per row, zero flicker)
        if graphH >= 3 then
            local bgHexBlack = hexColorMap[colors.black]
            local fgHexWhite = hexColorMap[colors.white]
            local fgHexLightGray = hexColorMap[colors.lightGray]
            local bgHexLine = hexColorMap[colors.cyan]
            local bgHexFill = hexColorMap[colors.blue]
            
            for y = topY, bottomY do
                local textTbl = {}
                local fgTbl = {}
                local bgTbl = {}
                
                -- Left margin (columns 1 to graphLeftX-1)
                for c = 1, graphLeftX - 1 do
                    textTbl[c] = " "
                    fgTbl[c] = bgHexBlack
                    bgTbl[c] = bgHexBlack
                end
                
                -- Graph columns
                for i = 1, graphW do
                    local idx = graphLeftX - 1 + i
                    local valIdx = i - (graphW - #usageHistory)
                    
                    if valIdx > 0 and valIdx <= #usageHistory then
                        local val = usageHistory[valIdx]
                        local pct = (val - minVal) / (maxVal - minVal)
                        if pct > 1.0 then pct = 1.0 end
                        if pct < 0.0 then pct = 0.0 end
                        
                        local fillHeight = math.floor((graphH - 1) * pct + 0.5)
                        local lineY = bottomY - fillHeight
                        
                        if y == lineY then
                            if isColor then
                                textTbl[idx] = " "
                                fgTbl[idx] = bgHexBlack
                                bgTbl[idx] = bgHexLine
                            else
                                textTbl[idx] = "*"
                                fgTbl[idx] = fgHexWhite
                                bgTbl[idx] = bgHexBlack
                            end
                        elseif y > lineY then
                            if isColor then
                                textTbl[idx] = " "
                                fgTbl[idx] = bgHexBlack
                                bgTbl[idx] = bgHexFill
                            else
                                textTbl[idx] = "."
                                fgTbl[idx] = fgHexLightGray
                                bgTbl[idx] = bgHexBlack
                            end
                        else
                            textTbl[idx] = " "
                            fgTbl[idx] = bgHexBlack
                            bgTbl[idx] = bgHexBlack
                        end
                    else
                        textTbl[idx] = " "
                        fgTbl[idx] = bgHexBlack
                        bgTbl[idx] = bgHexBlack
                    end
                end
                
                -- Right margin (columns graphRightX+1 to w)
                for c = graphRightX + 1, w do
                    textTbl[c] = " "
                    fgTbl[c] = bgHexBlack
                    bgTbl[c] = bgHexBlack
                end
                
                -- Single blit for the entire row
                device.setCursorPos(1, y)
                device.blit(table.concat(textTbl), table.concat(fgTbl), table.concat(bgTbl))
            end
        else
            blitLine(device, topY, w, "Screen too short for graph", colors.red, colors.black)
        end
        
        -- Min Label row (bottom of screen, single blit)
        local minLabel = "  Min: " .. formatEnergy(minVal, "AE/t")
        local minFull = minLabel .. string.rep(" ", w - #minLabel)
        minFull = minFull:sub(1, w)
        local minFg = string.rep(hexColorMap[colors.lightGray], 7)  -- "  Min: "
                    .. string.rep(hexColorMap[colors.cyan], w - 7)
        minFg = minFg:sub(1, w)
        local minBg = string.rep(hexColorMap[colors.black], w)
        device.setCursorPos(1, h)
        device.blit(minFull, minFg, minBg)
    end
    
    sleep(POLL_INTERVAL)
end
