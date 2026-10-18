VehicleDeformation = {}
VehicleDeformation.directory = g_currentModDirectory
VehicleDeformation.MAX_DENTS = 6
-- All 32 collision categories, including custom mod/map collision groups.
VehicleDeformation.COLLISION_MASK = 4294967295
VehicleDeformation.defaults = {
    enabled = true, minSpeed = 2.5, minDeltaSpeed = 1.25,
    minDeceleration = 18, radius = 0.85, maxDepth = 0.38,
    strength = 0.045, cooldown = 450, sampleInterval = 50,
    maxMaterialsPerVehicle = 256
}
VehicleDeformation.excludedNames = {
    "wheel", "tire", "tyre", "rim", "mirror",
    "exhaust", "hydraulic", "piston", "hose", "cable",
    "belt", "track", "character", "dashboard", "steering", "wiper", "collision"
}

local function clamp(x, lo, hi) return math.max(lo, math.min(x, hi)) end
local function length(x, y, z) return math.sqrt(x*x + y*y + z*z) end
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < 100000 end
local function log(message, ...) Logging.info("[VehicleDeformation] " .. message, ...) end

function VehicleDeformation:safe(label, fn, ...)
    local ok, result = pcall(fn, self, ...)
    if not ok then
        Logging.error("[VehicleDeformation] %s: %s", label, tostring(result))
    end
    return ok, result
end

function VehicleDeformation:loadMap()
    if g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer then
        Logging.warning("[VehicleDeformation] Prototype is disabled in multiplayer.")
        self.active = false
        return
    end
    self.active = true
    self.vehicles = {}
    self.componentVehicles = {}
    self.brokenLights = {}
    self.records = {}
    self.clock = 0
    self.config = {}
    for name, value in pairs(self.defaults) do self.config[name] = value end
    self.settingsDirectory = getUserProfileAppPath() .. "modSettings/FS25_vehicle_deformation/"
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(self.settingsDirectory)
    local filename = self.settingsDirectory .. "settings.xml"
    local xml = XMLFile.loadIfExists("VDSettings", filename)
    if xml == nil then
        xml = XMLFile.create("VDSettings", filename, "vehicleDeformation")
        if xml ~= nil then
            for name, value in pairs(self.config) do
                if type(value) == "boolean" then xml:setBool("vehicleDeformation#" .. name, value)
                else xml:setFloat("vehicleDeformation#" .. name, value) end
            end
            xml:save()
        end
    elseif xml ~= nil then
        for name, value in pairs(self.config) do
            if type(value) == "boolean" then self.config[name] = xml:getBool("vehicleDeformation#" .. name, value)
            else
                local stored = xml:getFloat("vehicleDeformation#" .. name, value)
                if finite(stored) and stored > 0 then self.config[name] = stored end
            end
        end
    end
    if xml ~= nil then xml:delete() end
    self.config.radius = clamp(self.config.radius, 0.25, 3)
    self.config.maxDepth = clamp(self.config.maxDepth, 0.02, 0.8)
    self.config.sampleInterval = clamp(self.config.sampleInterval, 20, 150)
    self.config.maxMaterialsPerVehicle = math.floor(clamp(self.config.maxMaterialsPerVehicle, 1, 512))
    VDMaterial:init()
    self:loadDamage()
    addConsoleCommand("vdStatus", "Show deformation diagnostics for the current vehicle", "consoleStatus", self)
    addConsoleCommand("vdDent", "Add a visual dent: front|rear|left|right [depth] [radius] [height]", "consoleDent", self)
    addConsoleCommand("vdDentNode", "Dent a named mesh: name-or-path [depth] [radius]. No coordinate guessing.", "consoleDentNode", self)
    addConsoleCommand("vdDentAt", "Add a dent in vehicle coordinates: x y z dx dy dz [depth] [radius]", "consoleDentAt", self)
    addConsoleCommand("vdRepair", "Remove visual dents from the current vehicle", "consoleRepair", self)
    addConsoleCommand("vdToggle", "Toggle automatic collision damage", "consoleToggle", self)
    log("Experimental v0.1.17 loaded. Console: vdStatus / vdDentNode Kapot / vdDent front / vdRepair. Single player only.")
end

function VehicleDeformation:savegameFilename()
    local mission = g_currentMission
    local directory = mission ~= nil and mission.missionInfo ~= nil and mission.missionInfo.savegameDirectory
    if directory == nil then return nil end
    return directory .. "/vehicleDeformation.xml"
end

function VehicleDeformation:loadDamage()
    local filename = self:savegameFilename()
    local xml = XMLFile.loadIfExists("VDDamage", filename)
    if xml == nil then return end
    for _, vehicleKey in xml:iterator("vehicleDeformation.vehicle") do
        local id = xml:getString(vehicleKey .. "#id")
        if id ~= nil then
            local record = {}
            for _, shapeKey in xml:iterator(vehicleKey .. ".shape") do
                local path = xml:getString(shapeKey .. "#path")
                if path ~= nil then
                    local dents = {}
                    for _, dentKey in xml:iterator(shapeKey .. ".dent") do
                        local dent = {}
                        local valid = true
                        for _, name in ipairs({"x", "y", "z", "dx", "dy", "dz", "radius"}) do
                            dent[name] = xml:getFloat(dentKey .. "#" .. name)
                            valid = valid and finite(dent[name])
                        end
                        if valid and dent.radius >= 0.02 and dent.radius <= 50 and #dents < self.MAX_DENTS
                            and length(dent.dx, dent.dy, dent.dz) <= dent.radius * 0.6 then
                            dents[#dents + 1] = dent
                        end
                    end
                    if #dents > 0 then record[path] = dents end
                end
            end
            self.records[id] = record
        end
    end
    xml:delete()
end

function VehicleDeformation:snapshot(state)
    local record = {}
    for _, shape in ipairs(state.shapes) do
        if #shape.dents > 0 then record[shape.path] = shape.dents end
    end
    return record
end

function VehicleDeformation:saveDamage(filenameOverride)
    if not self.active then return end
    local filename = filenameOverride or self:savegameFilename()
    if filename == nil then return end
    for vehicle, state in pairs(self.vehicles) do
        if vehicle.uniqueId ~= nil then self.records[tostring(vehicle.uniqueId)] = self:snapshot(state) end
    end
    local xml = XMLFile.create("VDDamage", filename, "vehicleDeformation")
    if xml == nil then return end
    xml:setInt("vehicleDeformation#version", 1)
    local vi = 0
    for id, record in pairs(self.records) do
        if next(record) ~= nil then
            local vk = string.format("vehicleDeformation.vehicle(%d)", vi)
            xml:setString(vk .. "#id", id)
            local si = 0
            for path, dents in pairs(record) do
                local sk = string.format("%s.shape(%d)", vk, si)
                xml:setString(sk .. "#path", path)
                for di, dent in ipairs(dents) do
                    local dk = string.format("%s.dent(%d)", sk, di - 1)
                    for name, value in pairs(dent) do xml:setFloat(dk .. "#" .. name, value) end
                end
                si = si + 1
            end
            vi = vi + 1
        end
    end
    xml:save()
    xml:delete()
end

function VehicleDeformation:isExcluded(node, root)
    local current = node
    while current ~= nil and current ~= 0 and current ~= root do
        local name = string.lower(getName(current) or "")
        for _, word in ipairs(self.excludedNames) do
            if string.find(name, word, 1, true) then return true end
        end
        current = getParent(current)
    end
    return false
end

function VehicleDeformation:registerVehicle(vehicle)
    if not self.active or not vehicle.isClient or vehicle.isDeleted or self.vehicles[vehicle] ~= nil then return end
    if vehicle.propertyState == VehiclePropertyState.SHOP_CONFIG or vehicle.components == nil then return end
    local state = {vehicle = vehicle, shapes = {}, elapsed = 0, cooldown = 0, supported = 0,
        skipped = 0, connected = 0, errors = 0, age = 0, jobs = {}}
    self.vehicles[vehicle] = state
    for _, component in ipairs(vehicle.components) do self.componentVehicles[component.node] = vehicle end
    local saved = self.records[tostring(vehicle.uniqueId)] or {}
    local function visit(node, path, root)
        if getHasClassId(node, ClassIds.SHAPE) and not getIsNonRenderable(node) then
            local slots = {}
            if not self:isExcluded(node, root) then
                for index = 0, getNumOfMaterials(node) - 1 do
                    if VDMaterial:isSupported(node, index) and state.supported < self.config.maxMaterialsPerVehicle then
                        local original = getMaterial(node, index)
                        slots[#slots + 1] = {index = index, original = original, breakableLight = VDMaterial:isLightMaterial(original)}
                        state.supported = state.supported + 1
                    else state.skipped = state.skipped + 1 end
                end
            else state.skipped = state.skipped + getNumOfMaterials(node) end
            if #slots > 0 then
                local shape = {node = node, path = path, slots = slots, dents = saved[path] or {}, converted = false, state = state}
                self:queueShape(shape)
                state.shapes[#state.shapes + 1] = shape
                if #shape.dents > 0 then
                    self:connectShape(state, shape)
                    self:pushDents(shape)
                end
            end
        end
        for i = 0, getNumOfChildren(node) - 1 do visit(getChildAt(node, i), path .. "/" .. i, root) end
    end
    for index, component in ipairs(vehicle.components) do visit(component.node, tostring(index), component.node) end
    if state.supported > 0 then log("%s: %d candidate materials, %d skipped", vehicle.configFileName or "vehicle", state.supported, state.skipped) end
end

-- Impacts only change Lua damage records. Native preparation runs in update.
function VehicleDeformation:connectShape(state, shape)
    return not shape.failed
end

function VehicleDeformation:queueShape(shape)
    for _, slot in ipairs(shape.slots) do
        if not slot.queued then
            slot.queued = true
            table.insert(shape.state.jobs, {shape = shape, slot = slot})
        end
    end
end

function VehicleDeformation:refreshBrokenLight(shape)
    self.brokenLights[shape.node] = nil
    for _, slot in ipairs(shape.slots) do
        if slot.breakableLight and slot.converted then self.brokenLights[shape.node] = true; break end
    end
end

function VehicleDeformation:pushDents(shape)
    shape.revision = (shape.revision or 0) + 1
    self:queueShape(shape)
end

function VehicleDeformation:flushSlot(shape, slot)
    slot.sent = slot.sent or {}
    for i = 0, self.MAX_DENTS - 1 do
        local dent = shape.dents[i + 1]
        local values = dent ~= nil and {dent.x, dent.y, dent.z, dent.radius, dent.dx, dent.dy, dent.dz, 0}
            or {0, 0, 0, 0, 0, 0, 0, 0}
        local old = slot.sent[i]
        for group = 0, 1 do
            local offset = group * 4
            if old == nil or old[offset+1] ~= values[offset+1] or old[offset+2] ~= values[offset+2]
                or old[offset+3] ~= values[offset+3] or old[offset+4] ~= values[offset+4] then
                local name = (group == 0 and "vdDentCenter" or "vdDentVector") .. i
                setShaderParameter(shape.node, name, values[offset+1], values[offset+2], values[offset+3], values[offset+4], false, slot.index)
            end
        end
        slot.sent[i] = values
    end
    slot.revision = shape.revision or 0
end

function VehicleDeformation:processPreparation()
    -- At most one material slot is attached/updated per frame. Prefer visible
    -- the driven vehicle, then saved damage, then remaining vehicles gradually.
    local current = self:currentVehicle()
    local selectedState, selectedJob, selectedIndex, bestScore = nil, nil, nil, -1
    for vehicle, state in pairs(self.vehicles) do
        if not vehicle.isDeleted then
            for i = #state.jobs, 1, -1 do
                local job = state.jobs[i]
                local shape, slot = job.shape, job.slot
                if shape.failed or not entityExists(shape.node) then
                    slot.queued = false
                    table.remove(state.jobs, i)
                end
            end
            for i, job in ipairs(state.jobs) do
                local shape, slot = job.shape, job.slot
                local cached = slot.converted or VDMaterial.cache[slot.original] ~= nil
                local canRequest = VDMaterial.pending == nil and self.clock >= VDMaterial.nextRequestAt
                if cached or canRequest or VDMaterial.failures[slot.original] ~= nil then
                    local score = (#shape.dents > 0 and 4 or 0) + (vehicle == current and 8 or 0) + (cached and 1 or 0)
                    if score > bestScore then
                        selectedState, selectedJob, selectedIndex, bestScore = state, job, i, score
                    end
                end
            end
        end
    end
    if selectedJob == nil then return end
    local state, shape, slot = selectedState, selectedJob.shape, selectedJob.slot
    local ok, failure = pcall(function()
        if not slot.converted then
            -- Other mods may replace a material after registration. Refresh the
            -- ID from its live shape before querying native material properties.
            slot.original = getMaterial(shape.node, slot.index)
            local material = VDMaterial:requestCarrier(slot.original, shape.node, slot.index, self.clock)
            if material == nil then return end
            if #shape.dents == 0 then
                -- Prewarming only fills the cache. All intact parts keep their
                -- original materials until they actually receive damage.
                slot.queued = false
                table.remove(state.jobs, selectedIndex)
                return
            end
            slot.parameters = VDMaterial:captureParameters(shape.node, slot.index)
            VDMaterial:apply(shape.node, slot.index, slot.parameters)
            slot.converted = true
            self:refreshBrokenLight(shape)
            state.connected = state.connected + 1
        end
        self:flushSlot(shape, slot)
        slot.queued = false
        table.remove(state.jobs, selectedIndex)
        shape.converted = true
        for _, other in ipairs(shape.slots) do
            if not other.converted then shape.converted = false; break end
        end
    end)
    if not ok then
        if entityExists(shape.node) then
            setMaterial(shape.node, slot.original, slot.index)
            for _, value in ipairs(slot.parameters or {}) do
                setShaderParameter(shape.node, value.name, value.x, value.y, value.z, value.w, false, slot.index)
            end
        end
        if slot.converted then state.connected = state.connected - 1 end
        slot.converted = false
        self:refreshBrokenLight(shape)
        shape.failed = true
        slot.queued = false
        table.remove(state.jobs, selectedIndex)
        state.errors = state.errors + 1
        Logging.error("[VehicleDeformation] Queued material substitution failed on %s: %s", shape.path, tostring(failure))
    end
end

function VehicleDeformation:addDent(vehicle, wx, wy, wz, dx, dy, dz, depth, radius, onlyShape)
    local state = self.vehicles[vehicle]
    if state == nil then self:registerVehicle(vehicle); state = self.vehicles[vehicle] end
    if state == nil then return 0 end
    depth = clamp(depth, 0.01, self.config.maxDepth)
    radius = clamp(radius, 0.25, 3)
    depth = math.min(depth, radius * 0.45)
    local magnitude = length(dx, dy, dz)
    if magnitude < 0.001 then return 0 end
    dx, dy, dz = dx / magnitude, dy / magnitude, dz / magnitude
    local affected = 0
    for _, shape in ipairs(state.shapes) do
        if (onlyShape == nil or onlyShape == shape) and not shape.failed and entityExists(shape.node) then
            local sx, sy, sz, sr = getShapeWorldBoundingSphere(shape.node)
            if length(wx - sx, wy - sy, wz - sz) <= radius + sr then
                if self:connectShape(state, shape) then
                    local x, y, z = worldToLocal(shape.node, wx, wy, wz)
                    local vx, vy, vz = worldDirectionToLocal(shape.node, dx * depth, dy * depth, dz * depth)
                    local rx, ry, rz = worldDirectionToLocal(shape.node, dx * radius, dy * radius, dz * radius)
                    local localRadius = length(rx, ry, rz)
                    local merged = false
                    for _, dent in ipairs(shape.dents) do
                        if length(x - dent.x, y - dent.y, z - dent.z) < localRadius * 0.35 then
                            local combined = length(dent.dx + vx, dent.dy + vy, dent.dz + vz)
                            local limit = math.max(dent.radius, localRadius) * 0.45
                            local factor = combined > limit and limit / combined or 1
                            dent.dx, dent.dy, dent.dz = (dent.dx + vx)*factor, (dent.dy + vy)*factor, (dent.dz + vz)*factor
                            dent.radius = math.max(dent.radius, localRadius)
                            merged = true
                            break
                        end
                    end
                    if not merged then
                        local dent = {x = x, y = y, z = z, dx = vx, dy = vy, dz = vz, radius = localRadius}
                        if #shape.dents < self.MAX_DENTS then shape.dents[#shape.dents + 1] = dent
                        else
                            -- Keep the most recent impacts; shader work stays bounded.
                            table.remove(shape.dents, 1)
                            shape.dents[#shape.dents + 1] = dent
                        end
                    end
                    self:pushDents(shape)
                    affected = affected + 1
                end
            end
        end
    end
    return affected
end

function VehicleDeformation:belongsToVehicle(node, vehicle)
    local rootVehicle = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    while node ~= nil and node ~= 0 do
        if g_currentMission ~= nil and g_currentMission.nodeToObject ~= nil then
            local object = g_currentMission.nodeToObject[node]
            if object ~= nil and object.getRootVehicle ~= nil and object:getRootVehicle() == rootVehicle then return true end
        end
        for _, component in ipairs(vehicle.components) do if node == component.node then return true end end
        node = getParent(node)
    end
    return false
end

function VehicleDeformation:raycastCallback(node, x, y, z, distance, nx, ny, nz)
    local probe = self.probe
    if probe == nil or self:belongsToVehicle(node, probe.vehicle) then return true end
    if ny == nil or math.abs(ny) > 0.75 then return true end
    local facing = -(nx*probe.dx + ny*probe.dy + nz*probe.dz)
    if facing < 0.15 then return true end
    if distance <= probe.extent + 0.65 and (probe.hit == nil or distance < probe.hit.distance) then
        probe.hit = {x = x, y = y, z = z, nx = nx, ny = ny, nz = nz, distance = distance, time = self.clock,
            targetVehicle = self:vehicleFromNode(node)}
    end
    return true
end

function VehicleDeformation:vehicleFromNode(node)
    -- Collision shapes are usually children of a registered component node.
    while node ~= nil and node ~= 0 and entityExists(node) do
        local objects = g_currentMission ~= nil and g_currentMission.nodeToObject
        local object = objects ~= nil and objects[node]
        if object ~= nil and self.vehicles[object] ~= nil then return object end
        local vehicle = self.componentVehicles[node]
        if vehicle ~= nil then return vehicle end
        node = getParent(node)
    end
    return nil
end

function VehicleDeformation:applyDetectedImpact(state, hit, depth)
    local vehicle, other = state.vehicle, hit.targetVehicle
    local targetState = other ~= nil and self.vehicles[other] or nil
    if other == vehicle or other ~= nil and (other.isDeleted or not entityExists(other.rootNode)) then
        other, targetState = nil, nil
    end
    if targetState ~= nil then
        -- Both vehicles can sample the same collision. Count it once for this
        -- pair, while retaining independent collisions with other vehicles.
        local contacts = state.contacts or {}
        if contacts[other] ~= nil and self.clock - contacts[other] < self.config.cooldown then return 0, 0 end
        state.contacts = contacts
        targetState.contacts = targetState.contacts or {}
        contacts[other] = self.clock
        targetState.contacts[vehicle] = self.clock
    end
    local count = self:addDent(vehicle, hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz, depth, self.config.radius)
    local targetCount = 0
    if targetState ~= nil then
        -- The struck vehicle compresses in the opposite world direction at
        -- the same contact, including parked/sleeping vehicles and implements.
        targetCount = self:addDent(other, hit.x, hit.y, hit.z, -hit.nx, -hit.ny, -hit.nz, depth, self.config.radius)
    end
    return count, targetCount
end

function VehicleDeformation:probeCollision(vehicle, vx, vy, vz)
    local horizontal = length(vx, 0, vz)
    if horizontal < self.config.minSpeed then return nil end
    local dx, dz = vx / horizontal, vz / horizontal
    local lx, _, lz = worldDirectionToLocal(vehicle.rootNode, dx, 0, dz)
    local size = vehicle.size or {}
    local width, vehicleLength = size.width or 2.5, size.length or 5
    local extent = math.abs(lx)*width*0.5 + math.abs(lz)*vehicleLength*0.5
    self.probe = {vehicle = vehicle, dx = dx, dy = 0, dz = dz, extent = extent}
    local mask = self.COLLISION_MASK
    local reach = extent + horizontal * self.config.sampleInterval / 1000 + 0.8
    for _, height in ipairs({0.5, 1.0, 1.6}) do
        local wx, wy, wz = localToWorld(vehicle.rootNode, size.widthOffset or 0, height, size.lengthOffset or 0)
        for _, side in ipairs({-0.32, 0, 0.32}) do
            local offset = side * width
            raycastAll(wx + dz*offset, wy, wz - dx*offset, dx, 0, dz, reach, "raycastCallback", self, mask)
        end
    end
    local hit = self.probe.hit
    self.probe = nil
    return hit
end

function VehicleDeformation:updateVehicle(state, dt)
    local vehicle = state.vehicle
    if state.disabled or vehicle.isDeleted or not entityExists(vehicle.rootNode) then return end
    state.age = state.age + dt
    state.cooldown = math.max(0, state.cooldown - dt)
    state.elapsed = state.elapsed + dt
    if state.elapsed < self.config.sampleInterval then return end
    local sampleTime = state.elapsed / 1000
    state.elapsed = 0
    if not self.config.enabled or state.age < 1500 or getIsSleeping(vehicle.rootNode) then
        state.previousVelocity = nil
        state.hit = nil
        return
    end
    local vx, vy, vz = getLinearVelocity(vehicle.rootNode)
    local previous = state.previousVelocity
    if previous ~= nil and sampleTime < 0.25 then
        local change = length(vx - previous.x, 0, vz - previous.z)
        local speed = length(previous.x, 0, previous.z)
        local hit = state.hit
        if state.cooldown == 0 and speed >= self.config.minSpeed and change >= self.config.minDeltaSpeed
            and change / sampleTime >= self.config.minDeceleration and hit ~= nil and self.clock - hit.time <= 250 then
            local toward = -(previous.x*hit.nx + previous.z*hit.nz)
            if toward >= self.config.minSpeed * 0.5 then
                local depth = math.min(self.config.maxDepth, change * self.config.strength)
                -- The obstacle's outward normal points back into the arriving
                -- vehicle. Negating it would pull panels towards the obstacle.
                local count, targetCount = self:applyDetectedImpact(state, hit, depth)
                state.cooldown = self.config.cooldown
                if count + targetCount > 0 then log("Impact: %.1f km/h velocity change, %d own shapes, %d target shapes", change * 3.6, count, targetCount) end
            end
        end
    end
    state.previousVelocity = {x = vx, y = vy, z = vz}
    local hit = self:probeCollision(vehicle, vx, vy, vz)
    if hit ~= nil then state.hit = hit end
end

function VehicleDeformation:update(dt)
    if not self.active then return end
    self.clock = self.clock + dt
    self:safe("preparation queue", self.processPreparation)
    for _, state in pairs(self.vehicles) do
        if not state.disabled then
            local ok, failure = pcall(self.updateVehicle, self, state, dt)
            if not ok then
                state.disabled = true
                Logging.error("[VehicleDeformation] Vehicle update disabled: %s", tostring(failure))
            end
        end
    end
end

function VehicleDeformation:unregisterVehicle(vehicle)
    if not self.active then return end
    local state = self.vehicles[vehicle]
    if state ~= nil and vehicle.uniqueId ~= nil then self.records[tostring(vehicle.uniqueId)] = self:snapshot(state) end
    if state ~= nil then
        for _, shape in ipairs(state.shapes) do self.brokenLights[shape.node] = nil end
        for _, component in ipairs(vehicle.components) do
            if self.componentVehicles[component.node] == vehicle then self.componentVehicles[component.node] = nil end
        end
    end
    for _, otherState in pairs(self.vehicles) do
        if otherState.contacts ~= nil then otherState.contacts[vehicle] = nil end
    end
    self.vehicles[vehicle] = nil
end

function VehicleDeformation:repair(vehicle)
    local state = self.vehicles[vehicle]
    if state == nil then return end
    for _, shape in ipairs(state.shapes) do
        shape.dents = {}
        for _, slot in ipairs(shape.slots) do
            if slot.breakableLight and slot.converted and entityExists(shape.node) then
                setMaterial(shape.node, slot.original, slot.index)
                for _, value in ipairs(slot.parameters or {}) do
                    setShaderParameter(shape.node, value.name, value.x, value.y, value.z, value.w, false, slot.index)
                end
                slot.converted = false
                slot.sent = nil
                slot.revision = nil
                shape.converted = false
                state.connected = state.connected - 1
            end
        end
        self:refreshBrokenLight(shape)
        if entityExists(shape.node) then self:pushDents(shape) end
    end
    self.records[tostring(vehicle.uniqueId)] = {}
    state.previousVelocity = nil
    state.hit = nil
end

function VehicleDeformation:currentVehicle()
    if g_localPlayer ~= nil then return g_localPlayer:getCurrentVehicle() end
    return nil
end

function VehicleDeformation:consoleStatus()
    local vehicle = self:currentVehicle()
    if vehicle == nil then return "Enter a vehicle first." end
    if self.vehicles[vehicle] == nil then self:registerVehicle(vehicle) end
    local state = self.vehicles[vehicle]
    if state == nil then return "Vehicle is not available for deformation." end
    local dents = 0
    for _, shape in ipairs(state.shapes) do dents = dents + #shape.dents end
    log("v0.1.17 Current vehicle: %s", vehicle.configFileName or "unknown")
    for _, shape in ipairs(state.shapes) do
        local wx, wy, wz, radius = getShapeWorldBoundingSphere(shape.node)
        local x, y, z = worldToLocal(vehicle.rootNode, wx, wy, wz)
        log("%s %s: %d material slots, %d dents, connected=%s skinned=%s center=%.2f,%.2f,%.2f radius=%.2f",
            shape.path, getName(shape.node), #shape.slots, #shape.dents, tostring(shape.converted),
            tostring(getShapeIsSkinned(shape.node)), x, y, z, radius)
    end
    return string.format("VD: auto=%s candidates=%d connected=%d skipped=%d dents=%d errors=%d disabled=%s queued=%d streaming=%s",
        tostring(self.config.enabled), state.supported, state.connected, state.skipped, dents, state.errors, tostring(state.disabled == true), #state.jobs, tostring(VDMaterial.pending ~= nil))
end

function VehicleDeformation:consoleDent(side, depth, radius, height)
    local vehicle = self:currentVehicle()
    if vehicle == nil then return "Enter a vehicle first." end
    side = string.lower(side or "front")
    if side == "hood" or side == "kapot" or side == "bonnet" then
        return self:consoleDentNode(side, depth, radius)
    end
    for _, argument in pairs({depth = depth, radius = radius, height = height}) do
        if not finite(tonumber(argument)) then
            return "Invalid number. Example: vdDent front 0.25 1.25 1.0 (height 1.0 metre, not 10)."
        end
    end
    local size = vehicle.size or {}
    local x, y, z = size.widthOffset or 0, tonumber(height) or 1.0, size.lengthOffset or 0
    local dx, dz = 0, -1
    if side == "front" then z = z + (size.length or 5)*0.5
    elseif side == "rear" then z = z - (size.length or 5)*0.5; dz = 1
    elseif side == "left" then x = x + (size.width or 2.5)*0.5; dx, dz = -1, 0
    elseif side == "right" then x = x - (size.width or 2.5)*0.5; dx, dz = 1, 0
    else return "Usage: vdDent front|rear|left|right [depth] [radius] [height]" end
    local wx, wy, wz = localToWorld(vehicle.rootNode, x, y, z)
    local worldDX, worldDY, worldDZ = localDirectionToWorld(vehicle.rootNode, dx, 0, dz)
    local ok, count = self:safe("test dent", self.addDent, vehicle, wx, wy, wz, worldDX, worldDY, worldDZ,
        tonumber(depth) or 0.25, tonumber(radius) or 1.25)
    if not ok then return "Failed. See [VehicleDeformation] in log.txt." end
    return string.format("Dent affected %d shapes. Try vdDentAt for a precise location; vdStatus for details.", count)
end

function VehicleDeformation:consoleDentNode(selector, depth, radius)
    local vehicle = self:currentVehicle()
    if vehicle == nil then return "Enter a vehicle first." end
    if selector == nil or selector == "" then return "Usage: vdDentNode name-or-path [depth] [radius]" end
    if (depth ~= nil and not finite(tonumber(depth))) or (radius ~= nil and not finite(tonumber(radius))) then
        return "Invalid number. Example: vdDentNode Kapot 0.25"
    end
    if self.vehicles[vehicle] == nil then self:registerVehicle(vehicle) end
    local state = self.vehicles[vehicle]
    if state == nil then return "Vehicle unavailable." end
    local selected
    selector = string.lower(selector)
    for _, shape in ipairs(state.shapes) do
        local name = string.lower(getName(shape.node) or "")
        local matches = shape.path == selector or string.find(name, selector, 1, true) ~= nil
        if selector == "hood" or selector == "kapot" or selector == "bonnet" then
            matches = string.find(name, "hood", 1, true) ~= nil or string.find(name, "kapot", 1, true) ~= nil
                or string.find(name, "bonnet", 1, true) ~= nil
        end
        if matches then
            if selected ~= nil then return "Several matching meshes. Use an exact path from vdStatus." end
            selected = shape
        end
    end
    if selected == nil then return "No matching eligible mesh. Use a name or path from vdStatus." end
    local wx, wy, wz, sr = getShapeWorldBoundingSphere(selected.node)
    -- A diagnostic dent covers the actual mesh bounds by default, rather than
    -- a possibly empty point at the vehicle's declared front/rear extent.
    local actualRadius = tonumber(radius) or clamp(sr * 1.1, 0.3, 3)
    local dx, dy, dz = localDirectionToWorld(selected.node, 0, -1, 0)
    local ok, count = self:safe("named mesh test", self.addDent, vehicle, wx, wy, wz, dx, dy, dz,
        tonumber(depth) or 0.25, actualRadius, selected)
    if not ok then return "Failed. See [VehicleDeformation] in log.txt." end
    return string.format("v0.1.17 %s: affected=%d radius=%.2f. vdRepair removes the test dent.", getName(selected.node), count, actualRadius)
end

function VehicleDeformation:consoleDentAt(x, y, z, dx, dy, dz, depth, radius)
    local vehicle = self:currentVehicle()
    if vehicle == nil then return "Enter a vehicle first." end
    x, y, z, dx, dy, dz = tonumber(x), tonumber(y), tonumber(z), tonumber(dx), tonumber(dy), tonumber(dz)
    if not (finite(x) and finite(y) and finite(z) and finite(dx) and finite(dy) and finite(dz)) then
        return "Usage: vdDentAt x y z dx dy dz [depth] [radius] (vehicle local coordinates)"
    end
    local wx, wy, wz = localToWorld(vehicle.rootNode, x, y, z)
    dx, dy, dz = localDirectionToWorld(vehicle.rootNode, dx, dy, dz)
    local ok, count = self:safe("precise test dent", self.addDent, vehicle, wx, wy, wz, dx, dy, dz,
        tonumber(depth) or 0.25, tonumber(radius) or 1.25)
    if not ok then return "Failed. See [VehicleDeformation] in log.txt." end
    return string.format("Dent affected %d shapes.", count)
end

function VehicleDeformation:consoleRepair()
    local vehicle = self:currentVehicle()
    if vehicle == nil then return "Enter a vehicle first." end
    self:repair(vehicle)
    return "Visual dents removed."
end

function VehicleDeformation:consoleToggle()
    self.config.enabled = not self.config.enabled
    return "Automatic collision dents: " .. tostring(self.config.enabled)
end

function VehicleDeformation:deleteMap()
    if not self.active then return end
    self.active = false
    for _, name in ipairs({"vdStatus", "vdDent", "vdDentNode", "vdDentAt", "vdRepair", "vdToggle"}) do removeConsoleCommand(name) end
    VDMaterial:delete()
    self.vehicles = {}
    self.componentVehicles = {}
    self.brokenLights = {}
    self.records = {}
end

-- Global hooks add behavior to stock and third-party vehicles without editing them.
Vehicle.onFinishedLoading = Utils.appendedFunction(Vehicle.onFinishedLoading, function(vehicle)
    VehicleDeformation:safe("register vehicle", VehicleDeformation.registerVehicle, vehicle)
end)
Vehicle.delete = Utils.prependedFunction(Vehicle.delete, function(vehicle)
    VehicleDeformation:safe("unregister vehicle", VehicleDeformation.unregisterVehicle, vehicle)
end)
-- Write into the engine's staging directory before it commits the save.
-- Writing after FSBaseMission.saveSavegame would miss asynchronous/cloud saves.
SavegameController.onSaveStartComplete = Utils.prependedFunction(SavegameController.onSaveStartComplete, function(_, errorCode, directory)
    if errorCode == Savegame.ERROR_OK and directory ~= nil then
        VehicleDeformation:safe("save dents", VehicleDeformation.saveDamage, directory .. "/vehicleDeformation.xml")
    end
end)
Wearable.repairVehicle = Utils.appendedFunction(Wearable.repairVehicle, function(vehicle)
    if VehicleDeformation.active then VehicleDeformation:repair(vehicle) end
end)
-- The game's light controller must not keep writing light-only uniforms into
-- a lens that now uses ordinary shading. Intact and repaired nodes pass through.
if StaticLight ~= nil then
    for _, method in ipairs({"setState", "setIsBlinking"}) do
        local original = StaticLight[method]
        if original ~= nil then
            StaticLight[method] = function(light, ...)
                if VehicleDeformation.active and VehicleDeformation.brokenLights[light.node] then return end
                return original(light, ...)
            end
        end
    end
end
addModEventListener(VehicleDeformation)
