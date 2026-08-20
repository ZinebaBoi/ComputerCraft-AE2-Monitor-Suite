-- ME Network Crafting CPU Monitor
-- Uses the ME Bridge from Advanced Peripherals to display
-- stats and status of AE2 Crafting CPUs.

-- CONFIGURATION
local POLL_INTERVAL = 2.0       -- Update interval in seconds
local MONITOR_SCALE = 1.0       -- Text size on monitors (1.0 = normal, 1.5 or 2.0 = larger)
local SECONDS_PER_PAGE = 6.0    -- Seconds to display each page of CPUs (if paginated)

-- Connect to ME Bridge
local me
while not me do
    me = peripheral.find("me_bridge")
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

-- Helper to format bytes (e.g., 65536 -> 64k)
local function formatBytes(bytes)
    if bytes >= 1048576 then
        return string.format("%.0fM", bytes / 1048576)
    elseif bytes >= 1024 then
        return string.format("%.0fk", bytes / 1024)
    else
        return tostring(bytes)
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

-- Build a full-width CPU utilization bar as a blit triple (text, fg, bg)
local function buildUtilBarBlit(w, busyCount, totalCount, isColor)
    local percent = 0.0
    if totalCount > 0 then percent = busyCount / totalCount end
    if percent > 1.0 then percent = 1.0 end
    if percent < 0.0 then percent = 0.0 end
    
    local label = "CPU Util: "
    local pctStr = string.format(" %.1f%%", percent * 100)
    local barW = w - (#label + #pctStr)
    
    if barW < 5 then
        local line = label .. string.format("%d/%d", busyCount, totalCount) .. pctStr
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
        fgStr = fgStr .. string.rep(hexColorMap[colors.cyan], fillW)
        fgStr = fgStr .. string.rep(hexColorMap[colors.white], emptyW)
    end
    fgStr = fgStr .. string.rep(hexColorMap[colors.white], w - #fgStr)
    fgStr = fgStr:sub(1, w)
    
    -- Build bg colors
    local bgStr = string.rep(hexColorMap[colors.black], #label + 1)
    if isColor then
        bgStr = bgStr .. string.rep(hexColorMap[colors.cyan], fillW)
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

-- Pagination variables
local page = 1
local ticksPerPage = math.max(1, math.floor(SECONDS_PER_PAGE / POLL_INTERVAL))
local ticksCount = 0

-- Main Loop
term.clear()
term.setCursorPos(1, 1)
print("ME CPU Monitor running...")
print("Updating display in the background...")

while true do
    local device, isMon = updateDisplayDevice()
    local w, h = device.getSize()
    local isColor = device.isColor()
    
    -- Row 1: Title Header
    local title = "ME CRAFTING PROCESSORS"
    if w < 25 then
        title = "ME PROCESSORS"
    elseif w < 16 then
        title = "CPUS"
    end
    local pad = math.floor((w - #title) / 2)
    local titleLine = string.rep(" ", pad) .. title .. string.rep(" ", w - #title - pad)
    local titleFg = isColor and colors.cyan or colors.white
    blitLine(device, 1, w, titleLine, titleFg, colors.black)
    
    -- Row 2: blank spacer
    blitLine(device, 2, w, "", colors.white, colors.black)
    
    -- Fetch crafting CPUs
    local cpus, err = me.getCraftingCPUs()
    
    if not cpus then
        local errMsg = "ME Error: " .. tostring(err or "Unknown")
        blitLine(device, 3, w, errMsg, colors.red, colors.black)
        sleep(5)
    else
        -- Fetch craftable items and fluids counts for recipes
        local craftItems = me.getCraftableItems() or {}
        local craftFluids = me.getCraftableFluids() or {}
        local itemRecipes = #craftItems
        local fluidRecipes = #craftFluids
        
        -- Calculate summary statistics
        local totalCPUs = #cpus
        local busyCount = 0
        local totalStorage = 0
        local usedStorage = 0
        local totalCoProcs = 0
        
        for _, cpu in ipairs(cpus) do
            local storage = cpu.storage or 0
            totalStorage = totalStorage + storage
            totalCoProcs = totalCoProcs + (cpu.coProcessors or 0)
            
            if cpu.isBusy then
                busyCount = busyCount + 1
                usedStorage = usedStorage + storage
            end
        end
        
        -- Sort CPUs: Busy ones first, then by storage size descending
        table.sort(cpus, function(a, b)
            if a.isBusy ~= b.isBusy then
                return a.isBusy -- busy cpus first
            end
            return (a.storage or 0) > (b.storage or 0)
        end)
        
        -- Layout height budgeting
        local barY, listTitleY, listStartY
        if h >= 18 then
            barY = 7
            listTitleY = 9
            listStartY = 10
        else
            barY = 4
            listTitleY = 5
            listStartY = 6
        end
        
        local listH = h - listStartY + 1
        
        -- Draw Summary Stats
        if h >= 18 then
            local lbl1, val1, lbl2, val2, lbl3, val3
            
            if w >= 39 then
                lbl1 = "CPUs Active:   "
                val1 = string.format("%d / %d busy", busyCount, totalCPUs)
                
                lbl2 = "Storage Alloc: "
                val2 = string.format("%s / %s (%d%%)", formatBytes(usedStorage), formatBytes(totalStorage), totalCPUs > 0 and math.floor(usedStorage / totalStorage * 100) or 0)
                
                lbl3 = "Co-Processors: "
                val3 = string.format("%d total co-procs", totalCoProcs)
            else
                -- Shorten labels and values for smaller widths (like 29)
                lbl1 = "CPUs:    "
                val1 = string.format("%d/%d busy", busyCount, totalCPUs)
                
                lbl2 = "Storage: "
                val2 = string.format("%s/%s (%d%%)", formatBytes(usedStorage), formatBytes(totalStorage), totalCPUs > 0 and math.floor(usedStorage / totalStorage * 100) or 0)
                
                lbl3 = "Co-Procs:"
                val3 = string.format("%d total", totalCoProcs)
            end
            
            blitTwoColor(device, 3, w, lbl1, colors.white, val1, colors.yellow, colors.black)
            blitTwoColor(device, 4, w, lbl2, colors.white, val2, colors.lime, colors.black)
            blitTwoColor(device, 5, w, lbl3, colors.white, val3, colors.lightGray, colors.black)
            local lbl4, val4
            if w >= 39 then
                lbl4 = "Recipes:       "
                val4 = string.format("%d item, %d fluid", itemRecipes, fluidRecipes)
            else
                lbl4 = "Recipes: "
                val4 = string.format("%d item, %d fluid", itemRecipes, fluidRecipes)
            end
            blitTwoColor(device, 6, w, lbl4, colors.white, val4, colors.cyan, colors.black)
        else
            -- Compact stats for small screens
            local lbl = "Active: " .. string.format("%d/%d", busyCount, totalCPUs)
            local extra = ""
            if w >= 30 then
                extra = "  Storage: " .. formatBytes(usedStorage) .. "/" .. formatBytes(totalStorage)
            end
            local padded = lbl .. extra
            blitLine(device, 3, w, padded, colors.white, colors.black)
        end
        
        -- Draw Utilization Bar
        local barText, barFg, barBg = buildUtilBarBlit(w, busyCount, totalCPUs, isColor)
        device.setCursorPos(1, barY)
        device.blit(barText, barFg, barBg)
        
        if h >= 18 then
            blitLine(device, 8, w, "", colors.white, colors.black)
        end
        
        if totalCPUs == 0 then
            clearLines(device, listTitleY, h, w)
            blitLine(device, listTitleY, w, "No Crafting CPUs connected", colors.yellow, colors.black)
        else
            -- Pagination of CPU list
            local itemsPerPage = listH
            local totalPages = math.max(1, math.ceil(totalCPUs / itemsPerPage))
            
            ticksCount = ticksCount + 1
            if ticksCount >= ticksPerPage then
                ticksCount = 0
                page = page + 1
            end
            if page > totalPages then
                page = 1
            end
            
            local startIdx = (page - 1) * itemsPerPage + 1
            local endIdx = math.min(totalCPUs, startIdx + itemsPerPage - 1)
            
            -- Draw list title
            local titleText = "CPU Status List"
            if totalPages > 1 then
                titleText = string.format("CPU Status (Page %d/%d)", page, totalPages)
            elseif w < 24 then
                titleText = "CPUs"
            end
            blitLine(device, listTitleY, w, titleText, colors.lightGray, colors.black)
            
            -- Draw CPUs in current page
            local drawRow = listStartY
            for i = startIdx, endIdx do
                local cpu = cpus[i]
                local cpuName = cpu.name
                if not cpuName or cpuName == "" or cpuName == "unnamed" or cpuName == "Unnamed" then
                    cpuName = "CPU " .. tostring(i)
                end
                
                local numStr = string.format("%d. ", i)
                local statusStr = cpu.isBusy and "[BUSY]" or "[IDLE]"
                
                -- Responsive specs string based on width
                local specsStr
                if w >= 39 then
                    specsStr = string.format("%s / %d cop", formatBytes(cpu.storage), cpu.coProcessors or 0)
                elseif w >= 29 then
                    specsStr = string.format("%s (%dc)", formatBytes(cpu.storage), cpu.coProcessors or 0)
                else
                    specsStr = string.format("%s/%dc", formatBytes(cpu.storage), cpu.coProcessors or 0)
                end
                
                -- Calculate width for name
                local nameStart = #numStr + #statusStr + 2
                local specsW = #specsStr
                local nameW = w - nameStart - specsW - 1
                
                local displayName = cpuName
                if nameW > 3 then
                    if #displayName > nameW then
                        displayName = displayName:sub(1, nameW - 3) .. "..."
                    end
                else
                    displayName = ""
                end
                
                local fullLine = numStr .. " " .. statusStr .. " " .. displayName
                local padSize = w - #fullLine - specsW
                if padSize < 1 then padSize = 1 end
                fullLine = fullLine .. string.rep(" ", padSize) .. specsStr
                fullLine = fullLine:sub(1, w)
                
                -- Foreground Color Construction
                local fgStr = string.rep(hexColorMap[colors.lightGray], #numStr + 1)
                           .. string.rep(hexColorMap[colors.white], #statusStr)
                           .. string.rep(hexColorMap[colors.white], 1 + #displayName + padSize)
                           .. string.rep(hexColorMap[colors.lightGray], specsW)
                fgStr = fgStr:sub(1, w)
                
                -- Background Color Construction
                local statusBgColor = cpu.isBusy and colors.red or colors.green
                local bgStr = string.rep(hexColorMap[colors.black], #numStr + 1)
                           .. string.rep(hexColorMap[statusBgColor], #statusStr)
                           .. string.rep(hexColorMap[colors.black], w - #numStr - 1 - #statusStr)
                bgStr = bgStr:sub(1, w)
                
                device.setCursorPos(1, drawRow)
                device.blit(fullLine, fgStr, bgStr)
                drawRow = drawRow + 1
            end
            
            -- Clear remaining empty rows in the page
            if drawRow <= h then
                clearLines(device, drawRow, h, w)
            end
        end
    end
    
    sleep(POLL_INTERVAL)
end
