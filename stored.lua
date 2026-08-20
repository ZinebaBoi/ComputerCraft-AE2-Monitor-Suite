-- ME Network Most Stored Items Monitor
-- Uses the ME Bridge from Advanced Peripherals to display
-- the top 10 items in the ME system by quantity.

-- CONFIGURATION
local POLL_INTERVAL = 2.0       -- Update interval in seconds
local MAX_ITEMS = 10            -- Number of items to display
local MONITOR_SCALE = 1.0       -- Text size on monitors (1.0 = normal, 1.5 or 2.0 = larger)

-- Items to exclude from the monitor display (by registry ID or display name)
local IGNORE_LIST = {
    ["minecraft:cobblestone"] = true,
    ["Cobblestone"] = true,
}

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
    me = peripheral.find("me_bridge")
    if not me then
        term.clear()
        term.setCursorPos(1, 1)
        print("Error: ME Bridge peripheral not found!")
        print("Please connect an ME Bridge and restart, or wait...")
        sleep(5)
    end
end

-- Helper to format item counts (e.g., 1000 -> 1.0k, 1000000 -> 1.0M)
local function formatCount(count)
    if count >= 1000000 then
        return string.format("%.1fM", count / 1000000)
    elseif count >= 1000 then
        return string.format("%.1fk", count / 1000)
    else
        return tostring(count)
    end
end

-- Helper to clean and format item names if displayName is missing
local function cleanItemName(name)
    local clean = name:match(":(.+)$") or name
    clean = clean:gsub("_", " ")
    clean = clean:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
    return clean
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
local function drawListItem(device, y, i, name, qtyStr, isColor, w)
    device.setCursorPos(1, y)
    device.setBackgroundColor(colors.black)
    device.write(string.rep(" ", w)) -- clear line
    
    -- Number label (color-coded to match the bar)
    device.setCursorPos(1, y)
    device.setTextColor(isColor and BAR_COLORS[i] or colors.white)
    local numStr = tostring(i) .. ". "
    device.write(numStr)
    
    -- Quantity (right-aligned, colored yellow)
    local qtyW = 10
    local qtyStart = w - qtyW + 1
    device.setCursorPos(qtyStart, y)
    device.setTextColor(colors.yellow)
    local padding = qtyW - #qtyStr
    device.write(string.rep(" ", padding) .. qtyStr)
    
    -- Name (filled in between number and quantity)
    local nameStart = #numStr + 1
    local nameW = qtyStart - nameStart - 1
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
print("ME Storage Monitor running...")
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
    
    local title = "ME STORAGE STATS"
    local padding = math.floor((w - #title) / 2)
    device.setCursorPos(padding + 1, 1)
    device.write(title)

    -- Fetch current items from the ME Bridge
    local currentItems, err = me.getItems()
    
    if not currentItems then
        -- Handle ME Bridge errors or network disconnects
        device.setCursorPos(1, 3)
        device.setTextColor(colors.red)
        device.write("ME Error: " .. tostring(err or "Unknown"))
        sleep(5)
    else
        -- Sort all items in the ME system by quantity descending
        table.sort(currentItems, function(a, b)
            local qtyA = a.amount or a.count or 0
            local qtyB = b.amount or b.count or 0
            return qtyA > qtyB
        end)
        
        -- Filter out items with 0 quantities and ignored items
        local itemsToShow = {}
        for _, item in ipairs(currentItems) do
            local qty = item.amount or item.count or 0
            local isIgnored = IGNORE_LIST[item.name] or (item.displayName and IGNORE_LIST[item.displayName])
            if qty > 0 and not isIgnored then
                table.insert(itemsToShow, item)
            end
        end
        
        -- Calculate height budget dynamically based on terminal height
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
        
        local actualItems = math.min(numItems, #itemsToShow)
        
        -- Find the max quantity among the top items for relative scaling of the bar graphs
        local maxQty = 0.0
        for i = 1, actualItems do
            local qty = itemsToShow[i].amount or itemsToShow[i].count or 0
            if qty > maxQty then
                maxQty = qty
            end
        end
        if maxQty <= 0 then maxQty = 1.0 end
        
        if actualItems == 0 then
            clearLines(device, 3, h, w)
            device.setTextColor(colors.yellow)
            device.setCursorPos(1, 4)
            local msg = "No items in storage"
            local pad = math.floor((w - #msg) / 2)
            device.write(string.rep(" ", pad) .. msg)
        else
            -- Render the top items in the list (Rows 3 to 2+actualItems)
            for i = 1, actualItems do
                local item = itemsToShow[i]
                local qty = item.amount or item.count or 0
                local qtyStr = formatCount(qty)
                
                local displayName = item.displayName
                if not displayName or displayName == "" or displayName == item.name then
                    displayName = cleanItemName(item.name)
                end
                
                drawListItem(device, 2 + i, i, displayName, qtyStr, isColor, w)
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
                local item = itemsToShow[i]
                local qty = item.amount or item.count or 0
                local percent = qty / maxQty
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
    end
    
    sleep(POLL_INTERVAL)
end
