-- ME Network Storage Cell & I/O Monitor
-- Uses the ME Bridge from Advanced Peripherals to display
-- storage capacity, stored types counts, Mekanism gas, and a real-time transaction rate graph.

-- CONFIGURATION
local POLL_INTERVAL = 1.0       -- Update interval in seconds (shorter for responsive I/O!)
local MONITOR_SCALE = 1.0       -- Text size on monitors (1.0 = normal, 1.5 or 2.0 = larger)

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

-- Helper to format storage counts (e.g. bytes or items) with custom decimal precision
local function formatStorage(val, unit, dec)
    dec = dec or 2
    local fmt = "%." .. tostring(dec) .. "f"
    if val >= 1073741824 then
        return string.format(fmt .. " G%s", val / 1073741824, unit)
    elseif val >= 1048576 then
        return string.format(fmt .. " M%s", val / 1048576, unit)
    elseif val >= 1024 then
        return string.format(fmt .. " k%s", val / 1024, unit)
    else
        return string.format(fmt .. " %s", val, unit)
    end
end

-- Compact storage formatting for narrow widths with custom decimal precision
local function formatStorageCompact(val, dec)
    dec = dec or 2
    local fmt = "%." .. tostring(dec) .. "f"
    if val >= 1073741824 then
        return string.format(fmt .. "G", val / 1073741824)
    elseif val >= 1048576 then
        return string.format(fmt .. "M", val / 1048576)
    elseif val >= 1024 then
        return string.format(fmt .. "k", val / 1024)
    else
        return string.format(fmt, val)
    end
end

-- Super compact storage formatting for extremely narrow widths (w < 30)
local function formatStorageSuperCompact(val)
    if val >= 1073741824 then
        return string.format("%.1fG", val / 1073741824)
    elseif val >= 1048576 then
        return string.format("%.1fM", val / 1048576)
    elseif val >= 1024 then
        return string.format("%.0fk", val / 1024)
    else
        return string.format("%.0f", val)
    end
end

-- Format I/O rate
local function formatRate(val)
    if val >= 1000000 then
        return string.format("%.2fM/s", val / 1000000)
    elseif val >= 1000 then
        return string.format("%.2fk/s", val / 1000)
    else
        return string.format("%.2f/s", val)
    end
end

-- Generate hex character color map for blit drawing
local hexColorMap = {}
for i = 0, 15 do
    local val = 2^i
    hexColorMap[val] = string.format("%x", i)
end

-- Write a full-width line via blit (zero flicker)
local function blitLine(device, y, w, text, fgColor, bgColor)
    local padded = text .. string.rep(" ", w - #text)
    padded = padded:sub(1, w)
    local fg = string.rep(hexColorMap[fgColor], w)
    local bg = string.rep(hexColorMap[bgColor], w)
    device.setCursorPos(1, y)
    device.blit(padded, fg, bg)
end

-- Write a full-width line with two colored segments via blit (zero flicker)
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

-- Clear a range of lines
local function clearLines(device, startY, endY, w)
    if startY > endY then return end
    device.setBackgroundColor(colors.black)
    for y = startY, endY do
        device.setCursorPos(1, y)
        device.write(string.rep(" ", w))
    end
end

-- Build progress bar for storage
local function buildProgressBarBlit(w, label, used, total, isColor, barColor)
    local percent = 0.0
    if total > 0 then percent = used / total end
    if percent > 1.0 then percent = 1.0 end
    if percent < 0.0 then percent = 0.0 end
    
    local pctStr = string.format(" %.1f%%", percent * 100)
    local barW = w - (#label + #pctStr)
    
    if barW < 5 then
        local line = label .. formatStorage(used, "B") .. pctStr
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
    local fgStr = string.rep(hexColorMap[colors.white], #label + 1)
    if isColor then
        fgStr = fgStr .. string.rep(hexColorMap[colors.white], fillW + emptyW)
    else
        fgStr = fgStr .. string.rep(hexColorMap[barColor], fillW)
        fgStr = fgStr .. string.rep(hexColorMap[colors.white], emptyW)
    end
    fgStr = fgStr .. string.rep(hexColorMap[colors.white], w - #fgStr)
    fgStr = fgStr:sub(1, w)
    
    -- Build bg colors
    local bgStr = string.rep(hexColorMap[colors.black], #label + 1)
    if isColor then
        bgStr = bgStr .. string.rep(hexColorMap[barColor], fillW)
        bgStr = bgStr .. string.rep(hexColorMap[colors.gray], emptyW)
    else
        bgStr = bgStr .. string.rep(hexColorMap[colors.black], fillW + emptyW)
    end
    bgStr = bgStr .. string.rep(hexColorMap[colors.black], w - #bgStr)
    bgStr = bgStr:sub(1, w)
    
    -- Non-color fallback character
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

-- Quantities tracker for rate computation
local prevQuantities = {}
local prevTime = os.epoch("utc") / 1000

-- Rolling history of cell I/O rate
local ioHistory = {}

-- Main Loop
term.clear()
term.setCursorPos(1, 1)
print("ME Disk Monitor running...")
print("Updating display in the background...")

while true do
    local device, isMon = updateDisplayDevice()
    local w, h = device.getSize()
    local isColor = device.isColor()
    
    -- Row 1: Title Header
    local title = "ME CELL MONITOR"
    local pad = math.floor((w - #title) / 2)
    local titleLine = string.rep(" ", pad) .. title .. string.rep(" ", w - #title - pad)
    local titleFg = isColor and colors.cyan or colors.white
    blitLine(device, 1, w, titleLine, titleFg, colors.black)
    
    -- Row 2: blank spacer
    blitLine(device, 2, w, "", colors.white, colors.black)
    
    -- Fetch storage quantities, cells, and Mekanism gases
    local cells, errC = me.listCells()
    local items, errI = me.listItems()
    local fluids, errF = me.listFluid()
    
    local gases, errG
    pcall(function() gases, errG = me.listGas() end)
    
    -- Storage capacity stats
    local usedItems = me.getUsedItemStorage() or 0
    local maxItems = me.getTotalItemStorage() or 0
    local usedFluid = me.getUsedFluidStorage() or 0
    local maxFluid = me.getTotalFluidStorage() or 0
    
    -- Sum Mekanism Gases
    local usedGas = 0
    local gasTypes = 0
    if gases then
        gasTypes = #gases
        for _, gas in ipairs(gases) do
            usedGas = usedGas + (gas.amount or gas.count or 0)
        end
    end
    
    -- Analyze cells and calculate capacities
    local totalCells = 0
    local itemCells = 0
    local fluidCells = 0
    local gasCells = 0
    local maxGas = 0
    local sizeCounts = {}
    if cells then
        totalCells = #cells
        for _, cell in ipairs(cells) do
            local isGas = cell.cellType == "gas" or cell.cellType == "chemical" or 
                          (cell.item and (cell.item:find("appmek") or cell.item:find("chemical") or cell.item:find("gas")))
            if isGas then
                maxGas = maxGas + (cell.totalBytes or 0)
                gasCells = gasCells + 1
            elseif cell.cellType == "fluid" then
                fluidCells = fluidCells + 1
            else
                itemCells = itemCells + 1
            end
            
            local size = cell.item:match("([0-9]+[kKmMgG])") or "other"
            size = size:lower()
            sizeCounts[size] = (sizeCounts[size] or 0) + 1
        end
    end
    
    -- Calculate I/O rate (Items + Fluids + Gases)
    local currentTime = os.epoch("utc") / 1000
    local elapsed = currentTime - prevTime
    if elapsed <= 0 then elapsed = 0.1 end
    prevTime = currentTime
    
    local currentQuantities = {}
    if items then
        for _, item in ipairs(items) do
            local name = item.name or ""
            local count = item.amount or item.count or 0
            currentQuantities["item:" .. name] = count
        end
    end
    if fluids then
        for _, fluid in ipairs(fluids) do
            local name = fluid.name or ""
            local count = fluid.amount or fluid.count or 0
            currentQuantities["fluid:" .. name] = count
        end
    end
    if gases then
        for _, gas in ipairs(gases) do
            local name = gas.name or ""
            local count = gas.amount or gas.count or 0
            currentQuantities["gas:" .. name] = count
        end
    end
    
    local totalChange = 0
    if next(prevQuantities) then
        for name, count in pairs(currentQuantities) do
            local prev = prevQuantities[name] or 0
            totalChange = totalChange + math.abs(count - prev)
        end
        for name, prev in pairs(prevQuantities) do
            if not currentQuantities[name] then
                totalChange = totalChange + prev
            end
        end
    end
    prevQuantities = currentQuantities
    
    local ioRate = totalChange / elapsed
    
    if not cells then
        local errMsg = "ME Error: " .. tostring(errC or "No Cells Detected")
        blitLine(device, 3, w, errMsg, colors.red, colors.black)
        sleep(5)
    else
        -- Stored types counts
        local itemTypes = items and #items or 0
        local fluidTypes = fluids and #fluids or 0
        
        -- Layout budgeting
        local itemBarY, fluidBarY, gasBarY, graphTitleY, topY, bottomY
        if h >= 18 then
            itemBarY = 8
            fluidBarY = 9
            if maxGas > 0 then
                gasBarY = 10
                graphTitleY = 12
                topY = 14
            else
                gasBarY = 0
                graphTitleY = 11
                topY = 13
            end
            bottomY = h - 1
        else
            itemBarY = 4
            fluidBarY = 0
            gasBarY = 0
            graphTitleY = 5
            topY = 7
            bottomY = h - 1
        end
        
        local graphH = bottomY - topY + 1
        local graphLeftX = 3
        local graphRightX = w - 2
        local graphW = graphRightX - graphLeftX + 1
        
        -- Add to I/O history
        table.insert(ioHistory, ioRate)
        while #ioHistory > graphW do
            table.remove(ioHistory, 1)
        end
        
        -- Draw Summary Stats
        if h >= 10 then
            -- Row 3: Cells count with sizes breakdown
            local parts = {}
            local sizes = {"64m", "16m", "4m", "1m", "256k", "64k", "16k", "4k", "1k"}
            for _, sz in ipairs(sizes) do
                local cnt = sizeCounts[sz]
                if cnt and cnt > 0 then
                    local formattedSz = sz .. "B"
                    table.insert(parts, tostring(cnt) .. "x " .. formattedSz)
                end
            end
            if sizeCounts["other"] and sizeCounts["other"] > 0 then
                table.insert(parts, tostring(sizeCounts["other"]) .. "x other")
            end
            
            local cellText
            if w >= 20 then
                local breakdown = table.concat(parts, ", ")
                cellText = "Cells: " .. breakdown
                if #cellText > w - 2 then
                    -- Try keeping only top 2 sizes to prevent overflow
                    local shortParts = {}
                    for idx = 1, math.min(#parts, 2) do
                        table.insert(shortParts, parts[idx])
                    end
                    cellText = "Cells: " .. table.concat(shortParts, ", ") .. "..."
                    if #cellText > w - 2 then
                        cellText = string.format("Cells: %d", totalCells)
                    end
                end
            else
                cellText = string.format("Cells: %d", totalCells)
            end
            
            local fg3 = string.rep(hexColorMap[colors.white], 7)
                     .. string.rep(hexColorMap[colors.cyan], #cellText - 7)
            fg3 = fg3 .. string.rep(hexColorMap[colors.white], w - #fg3)
            fg3 = fg3:sub(1, w)
            local bg3 = string.rep(hexColorMap[colors.black], w)
            device.setCursorPos(1, 3)
            device.blit(cellText .. string.rep(" ", w - #cellText), fg3, bg3)
            
            -- Row 4: Items Stats with types (usedItems formatted to 0 decimals)
            local lbl2 = "Items: "
            local val2
            if w >= 40 then
                val2 = string.format("%d (%s / %s)", itemTypes, formatStorage(usedItems, "Bytes", 0), formatStorage(maxItems, "Bytes", 2))
            elseif w >= 30 then
                val2 = string.format("%d (%s / %s)", itemTypes, formatStorageCompact(usedItems, 0) .. "B", formatStorageCompact(maxItems, 2) .. "B")
            else
                val2 = string.format("%d (%s / %s)", itemTypes, formatStorageCompact(usedItems, 0) .. "B", formatStorageSuperCompact(maxItems) .. "B")
            end
            blitTwoColor(device, 4, w, lbl2, colors.white, val2, colors.lime, colors.black)
            
            -- Row 5: Fluids Stats with types
            local lbl3 = "Fluids: "
            local val3
            if w >= 40 then
                val3 = string.format("%d (%s / %s)", fluidTypes, formatStorage(usedFluid, "Bytes"), formatStorage(maxFluid, "Bytes"))
            elseif w >= 30 then
                val3 = string.format("%d (%s / %s)", fluidTypes, formatStorageCompact(usedFluid) .. "B", formatStorageCompact(maxFluid) .. "B")
            else
                val3 = string.format("%d (%s / %s)", fluidTypes, formatStorageSuperCompact(usedFluid) .. "B", formatStorageSuperCompact(maxFluid) .. "B")
            end
            blitTwoColor(device, 5, w, lbl3, colors.white, val3, colors.blue, colors.black)
            
            -- Row 6: Gases Stats with types
            local lbl4 = "Gases: "
            local val4
            if maxGas > 0 then
                if w >= 40 then
                    val4 = string.format("%d (%s / %s)", gasTypes, formatStorage(usedGas, "Bytes"), formatStorage(maxGas, "Bytes"))
                elseif w >= 30 then
                    val4 = string.format("%d (%s / %s)", gasTypes, formatStorageCompact(usedGas) .. "B", formatStorageCompact(maxGas) .. "B")
                else
                    val4 = string.format("%d (%s / %s)", gasTypes, formatStorageSuperCompact(usedGas) .. "B", formatStorageSuperCompact(maxGas) .. "B")
                end
            else
                if w >= 40 then
                    val4 = string.format("%d (%s)", gasTypes, formatStorage(usedGas, "Bytes"))
                elseif w >= 30 then
                    val4 = string.format("%d (%s)", gasTypes, formatStorageCompact(usedGas) .. "B")
                else
                    val4 = string.format("%d (%s)", gasTypes, formatStorageSuperCompact(usedGas) .. "B")
                end
            end
            blitTwoColor(device, 6, w, lbl4, colors.white, val4, colors.magenta, colors.black)
            
            -- Row 7: Cell I/O Rate
            local lbl5 = "Cell I/O: "
            local val5 = formatRate(ioRate)
            if ioRate <= 0 then val5 = "0.00/s (Idle)" end
            blitTwoColor(device, 7, w, lbl5, colors.white, val5, colors.yellow, colors.black)
        else
            -- Small screen compact layout
            local lbl = string.format("Types: %dItems/%dFluids/%dGases I/O: ", itemTypes, fluidTypes, gasTypes)
            local val = formatRate(ioRate)
            if ioRate <= 0 then val = "Idle" end
            
            local full = lbl .. val
            local padded = full .. string.rep(" ", w - #full)
            padded = padded:sub(1, w)
            local fgStr = string.rep(hexColorMap[colors.white], #lbl)
                       .. string.rep(hexColorMap[colors.yellow], w - #lbl)
            fgStr = fgStr:sub(1, w)
            local bgStr = string.rep(hexColorMap[colors.black], w)
            device.setCursorPos(1, 3)
            device.blit(padded, fgStr, bgStr)
        end
        
        -- Draw progress bar(s)
        if itemBarY > 0 then
            local pText, pFg, pBg = buildProgressBarBlit(w, "Items:  ", usedItems, maxItems, isColor, colors.lime)
            device.setCursorPos(1, itemBarY)
            device.blit(pText, pFg, pBg)
        end
        if fluidBarY > 0 then
            local pText, pFg, pBg = buildProgressBarBlit(w, "Fluids: ", usedFluid, maxFluid, isColor, colors.blue)
            device.setCursorPos(1, fluidBarY)
            device.blit(pText, pFg, pBg)
        end
        if gasBarY > 0 and maxGas > 0 then
            local pText, pFg, pBg = buildProgressBarBlit(w, "Gases:  ", usedGas, maxGas, isColor, colors.magenta)
            device.setCursorPos(1, gasBarY)
            device.blit(pText, pFg, pBg)
        end
        
        -- Clear spacer rows around the graph title (large layout)
        if h >= 18 then
            local lastBarY = (maxGas > 0) and 10 or 9
            for y = lastBarY + 1, topY - 1 do
                if y ~= graphTitleY then
                    blitLine(device, y, w, "", colors.white, colors.black)
                end
            end
        end
        
        -- Calculate min and max for graph scale
        local minVal = math.huge
        local maxVal = -math.huge
        for _, val in ipairs(ioHistory) do
            if val < minVal then minVal = val end
            if val > maxVal then maxVal = val end
        end
        if minVal == math.huge then
            minVal = 0
            maxVal = 10
        elseif maxVal == minVal then
            local v = minVal
            minVal = math.max(0, v - 5)
            maxVal = v + 5
        end
        if maxVal < 10 then maxVal = 10 end
        
        -- Graph title row with max label (single blit)
        local maxLabel = "Max: " .. formatRate(maxVal)
        local titleText = w >= 35 and "Cell I/O History" or "Disk I/O"
        local titlePad = w - 2 - #maxLabel - #titleText
        if titlePad < 1 then titlePad = 1 end
        local graphTitleFull = "  " .. maxLabel .. string.rep(" ", titlePad) .. titleText
        graphTitleFull = graphTitleFull .. string.rep(" ", w - #graphTitleFull)
        graphTitleFull = graphTitleFull:sub(1, w)
        
        local gtFg = string.rep(hexColorMap[colors.lightGray], 2)
                  .. string.rep(hexColorMap[colors.lightGray], 5)
                  .. string.rep(hexColorMap[colors.yellow], #maxLabel - 5)
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
            local bgHexLine = hexColorMap[colors.lime]
            local bgHexFill = hexColorMap[colors.green]
            
            for y = topY, bottomY do
                local textTbl = {}
                local fgTbl = {}
                local bgTbl = {}
                
                -- Left margin
                for c = 1, graphLeftX - 1 do
                    textTbl[c] = " "
                    fgTbl[c] = bgHexBlack
                    bgTbl[c] = bgHexBlack
                end
                
                -- Graph columns
                for i = 1, graphW do
                    local idx = graphLeftX - 1 + i
                    local valIdx = i - (graphW - #ioHistory)
                    
                    if valIdx > 0 and valIdx <= #ioHistory then
                        local val = ioHistory[valIdx]
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
                
                -- Right margin
                for c = graphRightX + 1, w do
                    textTbl[c] = " "
                    fgTbl[c] = bgHexBlack
                    bgTbl[c] = bgHexBlack
                end
                
                device.setCursorPos(1, y)
                device.blit(table.concat(textTbl), table.concat(fgTbl), table.concat(bgTbl))
            end
        else
            blitLine(device, topY, w, "Screen too short for graph", colors.red, colors.black)
        end
        
        -- Min Label row (bottom of screen)
        local minLabel = "  Min: " .. formatRate(minVal)
        local minFull = minLabel .. string.rep(" ", w - #minLabel)
        minFull = minFull:sub(1, w)
        local minFg = string.rep(hexColorMap[colors.lightGray], 7)
                    .. string.rep(hexColorMap[colors.cyan], w - 7)
        minFg = minFg:sub(1, w)
        local minBg = string.rep(hexColorMap[colors.black], w)
        device.setCursorPos(1, h)
        device.blit(minFull, minFg, minBg)
    end
    
    sleep(POLL_INTERVAL)
end
