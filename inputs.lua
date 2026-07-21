-- ME Network Production Stats Monitor
-- Uses the ME Bridge from Advanced Peripherals to display
-- the top 10 items increasing in quantity.

-- CONFIGURATION
local POLL_INTERVAL = 2.0       -- Update interval in seconds
local MAX_ITEMS = 10            -- Number of items to display
local EMA_WINDOW_SECONDS = 60.0 -- Smoothing window (60 seconds for a 1-minute average)
local MONITOR_SCALE = 1.0       -- Text size on monitors (1.0 = normal, 1.5 or 2.0 = larger)

-- Items to exclude from the monitor display (by registry ID or display name)
local IGNORE_LIST = {
    ["minecraft:cobblestone"] = true,
    ["Cobblestone"] = true,
}

-- Calculated EMA factor (smoothes rates over the configured window)
local EMA_ALPHA = 2.0 / ((EMA_WINDOW_SECONDS / POLL_INTERVAL) + 1.0)

-- Colors assigned to each of the 10 items/bars
local BAR_COLORS = {
    colors.red,
    colors.orange,
    colors.yellow,
    colors.green,
    colors.lime,
    colors.cyan,
    colors.lightBlue,
    colors.blue,
    colors.purple,
    colors.magenta
}

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

-- Database of item quantities and calculated rates
local db = {}
local lastTime = nil
local isFirstRun = true

-- Helper to clean and format item names if displayName is missing
local function cleanItemName(name)
    local clean = name:match(":(.+)$") or name
    clean = clean:gsub("_", " ")
    clean = clean:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    return clean
end

-- Generate a unique key for items (combining fingerprint, name, or NBT/components)
local function getItemKey(item)
    if item.fingerprint and item.fingerprint ~= "" then
        return item.fingerprint
    end
    
    local extraStr = ""
    if type(item.nbt) == "table" then
        extraStr = textutils.serialize(item.nbt)
    elseif type(item.nbt) == "string" then
        extraStr = item.nbt
    elseif type(item.components) == "table" then
        extraStr = textutils.serialize(item.components)
    end
    return item.name .. ":" .. extraStr
end

-- Format rate of change (items per minute) for display
local function formatRate(rate)
    if rate >= 1000000 then
        return string.format("+%.1fM/m", rate / 1000000)
    elseif rate >= 1000 then
        return string.format("+%.1fk/m", rate / 1000)
    elseif rate >= 10 then
        return string.format("+%.0f/m", rate)
    elseif rate >= 1 then
        return string.format("+%.1f/m", rate)
    else
        return string.format("+%.2f/m", rate)
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
        -- Clear the old device if switching
        if activeDevice then
            pcall(function()
                activeDevice.clear()
                activeDevice.setCursorPos(1, 1)
            end)
        end
        
        activeDevice = dev
        activeDeviceName = devName
        
        -- Initialize the new device
        activeDevice.clear()
        activeDevice.setCursorPos(1, 1)
        if devName ~= "terminal" then
            pcall(function() activeDevice.setTextScale(MONITOR_SCALE) end)
        end
    end
    return activeDevice, (devName ~= "terminal")
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

-- Draw a single list item
local function drawListItem(device, y, i, name, rateStr, isColor, w)
    device.setCursorPos(1, y)
    device.setBackgroundColor(colors.black)
    device.write(string.rep(" ", w)) -- clear line
    
    -- Number label (color-coded to match the bar)
    device.setCursorPos(1, y)
    device.setTextColor(isColor and BAR_COLORS[i] or colors.white)
    local numStr = tostring(i) .. ". "
    device.write(numStr)
    
    -- Rate (right-aligned)
    local rateW = 10
    local rateStart = w - rateW + 1
    device.setCursorPos(rateStart, y)
    device.setTextColor(colors.green)
    local padding = rateW - #rateStr
    device.write(string.rep(" ", padding) .. rateStr)
    
    -- Name (filled in between number and rate)
    local nameStart = #numStr + 1
    local nameW = rateStart - nameStart - 1
    local displayName = name
    if #displayName > nameW then
        displayName = string.sub(displayName, 1, nameW - 3) .. "..."
    end
    device.setCursorPos(nameStart, y)
    device.setTextColor(colors.white)
    device.write(displayName)
end

-- Draw a single vertical bar graph
local function drawVerticalBar(device, x, topY, bottomY, barW, percent, isColor, color)
    local chartHeight = bottomY - topY + 1
    local fillHeight = math.floor(chartHeight * percent + 0.5)
    
    -- Draw from bottom upwards
    for y = bottomY, topY, -1 do
        device.setCursorPos(x, y)
        if y >= bottomY - fillHeight + 1 and fillHeight > 0 then
            -- Filled part of the bar
            if isColor then
                device.setBackgroundColor(color)
                device.write(string.rep(" ", barW))
            else
                device.setBackgroundColor(colors.black)
                device.setTextColor(colors.white)
                device.write(string.rep("|", barW))
            end
        else
            -- Empty part of the bar
            device.setBackgroundColor(colors.black)
            device.write(string.rep(" ", barW))
        end
    end
    device.setBackgroundColor(colors.black) -- restore background
end

-- Main Program Loop
term.clear()
term.setCursorPos(1, 1)
print("ME Production Monitor running...")
print("Updating display in the background...")

while true do
    -- Get current screen or monitor
    local device, isMon = updateDisplayDevice()
    local w, h = device.getSize()
    local isColor = device.isColor()
    
    -- Render Title Header on Row 1 (Black background, Cyan/White text)
    device.setCursorPos(1, 1)
    device.setBackgroundColor(colors.black)
    device.write(string.rep(" ", w)) -- clear line
    
    if isColor then
        device.setTextColor(colors.cyan)
    else
        device.setTextColor(colors.white)
    end
    
    local title = "ME PRODUCTION STATS"
    local padding = math.floor((w - #title) / 2)
    device.setCursorPos(padding + 1, 1)
    device.write(title)

    -- Fetch current items from the ME Bridge
    local currentItems, err = me.listItems()
    local currentTime = os.clock()
    
    if not currentItems then
        -- Handle ME Bridge errors or network disconnects
        device.setCursorPos(1, 3)
        device.setTextColor(colors.red)
        device.write("ME Error: " .. tostring(err or "Unknown"))
        sleep(5)
    else
        if isFirstRun then
            -- Initialize baseline quantities
            for _, item in ipairs(currentItems) do
                local key = getItemKey(item)
                local qty = item.amount or item.count or 0
                db[key] = {
                    name = item.name,
                    displayName = item.displayName or item.name,
                    qty = qty,
                    time = currentTime,
                    rate = 0.0,
                    visited = true
                }
            end
            
            -- Display calibration message on the screen
            device.setTextColor(colors.yellow)
            device.setCursorPos(1, 3)
            device.write("Gathering baseline data...")
            device.setCursorPos(1, 4)
            device.write("Calculating 1-minute averages in " .. tostring(POLL_INTERVAL) .. "s...")
            
            lastTime = currentTime
            isFirstRun = false
        else
            local dt = currentTime - lastTime
            if dt <= 0 then dt = 0.001 end
            
            -- Mark all current db records as unvisited
            for _, entry in pairs(db) do
                entry.visited = false
            end
            
            -- Update quantities and calculate production rates
            for _, item in ipairs(currentItems) do
                local key = getItemKey(item)
                local qty = item.amount or item.count or 0
                local entry = db[key]
                
                if entry then
                    local dq = qty - entry.qty
                    local instantRate = dq / dt
                    if instantRate < 0 then instantRate = 0 end
                    
                    -- Smooth the rate of change using Exponential Moving Average
                    entry.rate = EMA_ALPHA * instantRate + (1.0 - EMA_ALPHA) * entry.rate
                    entry.qty = qty
                    entry.time = currentTime
                    entry.visited = true
                else
                    -- Found a new item in the network
                    local displayName = item.displayName
                    if not displayName or displayName == "" or displayName == item.name then
                        displayName = cleanItemName(item.name)
                    end
                    
                    db[key] = {
                        name = item.name,
                        displayName = displayName,
                        qty = qty,
                        time = currentTime,
                        rate = 0.0,
                        visited = true
                    }
                end
            end
            
            -- Handle items that were completely removed (went to 0 count)
            for key, entry in pairs(db) do
                if not entry.visited and entry.qty > 0 then
                    local dq = 0 - entry.qty
                    local instantRate = dq / dt
                    if instantRate < 0 then instantRate = 0 end
                    
                    entry.rate = EMA_ALPHA * instantRate + (1.0 - EMA_ALPHA) * entry.rate
                    entry.qty = 0
                    entry.time = currentTime
                end
            end
            
            -- Filter out items that are increasing and not ignored
            local increasing = {}
            for _, entry in pairs(db) do
                -- Threshold of 0.001/s (0.06/m) to filter out noise
                local isIgnored = IGNORE_LIST[entry.name] or (entry.displayName and IGNORE_LIST[entry.displayName])
                if entry.rate > 0.001 and not isIgnored then
                    table.insert(increasing, entry)
                end
            end
            
            -- Sort by rate descending
            table.sort(increasing, function(a, b)
                return a.rate > b.rate
            end)
            
            -- Calculate height budget dynamically based on terminal height
            -- Title: 1 row, Spacer: 1 row. List: actualItems. Spacer: dynamic. Chart: chartHeight. Axis: 1 row.
            local numItems = MAX_ITEMS
            local chartHeight = 5
            
            if h - 4 < 15 then
                -- Scale down for small displays
                local budget = h - 4
                if budget >= 8 then
                    numItems = math.floor(budget / 2)
                    chartHeight = budget - numItems
                else
                    numItems = math.max(2, budget - 3)
                    chartHeight = math.max(3, budget - numItems)
                end
            else
                numItems = MAX_ITEMS
                chartHeight = (h - 4) - numItems
                if chartHeight > 10 then
                    chartHeight = 10 -- Cap bar height to keep list readable
                end
            end
            
            local actualItems = math.min(numItems, #increasing)
            
            -- Find the max rate for relative scaling of the bar graphs
            local maxRate = 0.0
            for i = 1, actualItems do
                if increasing[i].rate > maxRate then
                    maxRate = increasing[i].rate
                end
            end
            if maxRate <= 0 then maxRate = 1.0 end
            
            if actualItems == 0 then
                clearLines(device, 3, h, w)
                device.setTextColor(colors.yellow)
                device.setCursorPos(1, 4)
                local msg = "No item production detected"
                local pad = math.floor((w - #msg) / 2)
                device.write(string.rep(" ", pad) .. msg)
                
                device.setTextColor(colors.lightGray)
                device.setCursorPos(1, 6)
                local msg2 = "All quantities stable"
                local pad2 = math.floor((w - #msg2) / 2)
                device.write(string.rep(" ", pad2) .. msg2)
            else
                -- Render the top items in the list (Rows 3 to 2+actualItems)
                for i = 1, actualItems do
                    local item = increasing[i]
                    local ratePerMin = item.rate * 60
                    local rateStr = formatRate(ratePerMin)
                    drawListItem(device, 2 + i, i, item.displayName, rateStr, isColor, w)
                end
                
                -- Dynamic vertical layout coordinates
                local bottomY = h - 1
                local topY = h - chartHeight
                
                -- Clear unused lines between list and bar chart
                clearLines(device, 3 + actualItems, topY - 1, w)
                
                -- Clear the axis row at the bottom
                device.setCursorPos(1, h)
                device.setBackgroundColor(colors.black)
                device.write(string.rep(" ", w))
                
                -- Determine bar width and step spacing dynamically
                local barW = 2
                if w < 30 then
                    barW = 1
                end
                local step = 3
                if w >= actualItems * 4 then
                    step = 4
                elseif w >= actualItems * 3 then
                    step = 3
                elseif w >= actualItems * 2 then
                    step = 2
                    barW = 1
                else
                    step = 1
                    barW = 1
                end
                
                local chartWidth = (actualItems - 1) * step + barW
                local leftMargin = math.floor((w - chartWidth) / 2) + 1
                
                -- Draw vertical bars and axis labels
                for i = 1, actualItems do
                    local item = increasing[i]
                    local percent = item.rate / maxRate
                    local x = leftMargin + (i - 1) * step
                    local color = BAR_COLORS[i] or colors.white
                    
                    -- Render the bar graph column
                    drawVerticalBar(device, x, topY, bottomY, barW, percent, isColor, color)
                    
                    -- Render the matching color-coded number label
                    device.setCursorPos(x, h)
                    device.setTextColor(isColor and color or colors.white)
                    device.setBackgroundColor(colors.black)
                    if barW >= 2 then
                        device.write(string.format("%-2d", i))
                    else
                        device.write(tostring(i))
                    end
                end
            end
            
            lastTime = currentTime
        end
    end
    
    sleep(POLL_INTERVAL)
end
