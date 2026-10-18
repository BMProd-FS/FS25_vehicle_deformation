-- Materials are reconstructed on a hidden carrier, never in the source I3D.
-- The carrier stays alive until map unload so its material cannot be freed.
VDMaterial = {}
VDMaterial.directory = g_currentModDirectory
VDMaterial.supportedVariations = {
    [""] = true, default = true, vmaskUV2 = true, vmaskUV2_normalUV3 = true,
    uvTransform = true, uvTransform_vmaskUV2 = true,
    shaking = true, shaking_vmaskUV2 = true,
    staticLight = true, staticLight_vertex = true, staticLight_vertex_slide = true
}
VDMaterial.customMaps = {
    "detailDiffuse", "detailNormal", "detailSpecular", "dirtDiffuse",
    "dirtNormal", "dirtSpecular", "waterDroplets"
}

function VDMaterial:isLightMaterial(material)
    local variation = getMaterialCustomShaderVariation(material) or ""
    return string.sub(variation, 1, 11) == "staticLight"
end

function VDMaterial:init()
    self.cache = {}
    self.carriers = {}
    self.serial = 0
    self.pending = nil
    self.failures = {}
    self.nextRequestAt = 0
    self.active = true
    -- Runtime index enumeration can return empty names for compiled slots.
    -- Read declaration names once and probe supported parameters by name.
    self.parameterNames = {"colorScale", "porosity", "smoothnessScale", "metalnessScale",
        "clearCoatIntensity", "clearCoatSmoothness", "alphaBlendingClipThreshold"}
    local shaderXML = XMLFile.load("VDParameterNames", self.directory .. "shaders/vehicleDeformationShader.xml")
    if shaderXML ~= nil then
        for _, key in shaderXML:iterator("CustomShader.Parameters.Parameter") do
            local name = shaderXML:getString(key .. "#name")
            if name ~= nil and name ~= "" and not string.match(name, "^vd") then
                self.parameterNames[#self.parameterNames + 1] = name
                local size = tonumber(shaderXML:getString(key .. "#arraySize")) or 0
                for i = 0, size - 1 do self.parameterNames[#self.parameterNames + 1] = name .. i end
            end
        end
        shaderXML:delete()
    end
    self.cacheDirectory = getUserProfileAppPath() .. "modSettings/FS25_vehicle_deformation/cache/"
    createFolder(getUserProfileAppPath() .. "modSettings/")
    createFolder(getUserProfileAppPath() .. "modSettings/FS25_vehicle_deformation/")
    createFolder(self.cacheDirectory)
end

function VDMaterial:isSupported(node, materialIndex)
    local material = getMaterial(node, materialIndex)
    local filename = getMaterialCustomShaderFilename(material) or ""
    filename = string.lower(string.gsub(filename, "\\", "/"))
    if not string.match(filename, "/vehicleshader%.xml$") then return false, "shader" end
    local variation = getMaterialCustomShaderVariation(material) or ""
    if not self.supportedVariations[variation] then return false, "variation:" .. variation end
    return true
end

function VDMaterial:captureParameters(node, index)
    local values, seen = {}, {}
    local function capture(name)
        if type(name) ~= "string" or name == "" or seen[name] then return end
        seen[name] = true
        if getHasShaderParameter(node, name, index) then
            local x, y, z, w = getShaderParameter(node, name, index)
            if type(x) == "number" then
                values[#values + 1] = {name = name, x = x, y = y, z = z, w = w}
            end
        end
    end
    for _, name in ipairs(self.parameterNames or {}) do capture(name) end
    for i = 0, getNumOfShaderParameters(node, index) - 1 do
        capture(getShaderParameterNameByIndex(node, i, index))
    end
    return values
end

function VDMaterial:resolveTexturePath(filename)
    if filename == nil or filename == "" then return nil end
    filename = string.gsub(filename, "\\", "/")
    -- Engine getters return game-relative paths without the $ prefix.
    -- A generated carrier lives elsewhere, so these must be anchored again.
    if string.sub(filename, 1, 5) == "data/" then return "$" .. filename end
    if string.sub(filename, 1, 6) == "dataS/" then return "$" .. filename end
    local basePath = string.gsub(getAppBasePath(), "\\", "/")
    basePath = string.gsub(basePath, "/+$", "") .. "/"
    if string.sub(filename, 1, 5) == "pdlc/" then return basePath .. filename end
    if string.sub(filename, 1, 1) == "$" or string.match(filename, "^%a:/")
        or string.sub(filename, 1, 1) == "/" then return filename end
    -- Other relative paths are game-root-relative, never cache-relative.
    return basePath .. filename
end

function VDMaterial:canCopyParameter(name, brokenLight)
    if not brokenLight then return true end
    local lower = string.lower(name)
    return not string.match(lower, "^light") and not string.match(lower, "^blink")
end

function VDMaterial:writeCarrier(original, node, index)
    local xml = XMLFile.load("VDMaterialCarrier", self.directory .. "assets/materialCarrier.i3d")
    if xml == nil then error("Cannot read materialCarrier.i3d") end
    local fileIndex = 1
    local nextId = 2
    local materialPath = "i3D.Materials.Material(0)"
    -- Editor exports can renumber IDs. Reserve file 1 for the shader and
    -- material 1 for the donor before allocating texture IDs from 2 onward.
    xml:setInt("i3D.Files.File(0)#fileId", 1)
    xml:setInt(materialPath .. "#customShaderId", 1)
    xml:setInt(materialPath .. "#materialId", 1)
    xml:setString("i3D.Scene.Shape(0)#materialIds", "1")
    xml:setBool("i3D.Scene.Shape(0)#visibility", false)
    xml:setBool("i3D.Scene.Shape(0)#collision", false)
    -- Windows, light lenses and decals share the body displacement field.
    -- Their blend mode must survive the material substitution.
    xml:setBool(materialPath .. "#alphaBlending", getMaterialIsAlphaBlended(original))
    xml:setBool(materialPath .. "#alphaTesting", getMaterialIsAlphaTested(original))
    xml:setString("i3D.Files.File(0)#filename", self.directory .. "shaders/vehicleDeformationShader.xml")
    -- Keep the proven inline triangle; no binary geometry is loaded.
    local variation = getMaterialCustomShaderVariation(original) or ""
    -- A damaged lens uses ordinary shading. Do not bind the engine's light
    -- arrays/intensity texture to the deformation material.
    local brokenLight = self:isLightMaterial(original)
    if variation == "default" or brokenLight then variation = "" end
    if variation ~= "" then xml:setString(materialPath .. "#customShaderVariation", variation) end
    -- Seed material defaults before loading; enumeration on a newly assigned
    -- donor must not decide whether original color/fabric overrides survive.
    if node ~= nil then
        local parameterIndex = 0
        for _, value in ipairs(self:captureParameters(node, index)) do
            if self:canCopyParameter(value.name, brokenLight) then
                local path = string.format("%s.CustomParameter(%d)", materialPath, parameterIndex)
                xml:setString(path .. "#name", value.name)
                xml:setString(path .. "#value", string.format("%.9g %.9g %.9g %.9g", value.x or 0, value.y or 0, value.z or 0, value.w or 0))
                parameterIndex = parameterIndex + 1
            end
        end
    end
    local success, r, g, b, a = getMaterialAlbedoColor(original)
    if success then
        xml:setString(materialPath .. "#diffuseColor", string.format("%.9g %.9g %.9g %.9g", r, g, b, a))
    end
    local hasMetalness, metalness = getMaterialMetalness(original)
    local hasSmoothness, smoothness = getMaterialSmoothness(original)
    if hasMetalness and type(metalness) == "number" then xml:setFloat(materialPath .. "#metalness", metalness) end
    if hasSmoothness and type(smoothness) == "number" then xml:setFloat(materialPath .. "#smoothness", smoothness) end
    local function addMap(filename, tag, customName)
        if filename == nil or filename == "" then return end
        -- Engine-generated solid colors are resources, not disk filenames.
        -- The corresponding color is already represented by diffuseColor.
        if string.find(filename, "gen_singleColorTexture_", 1, true) then return end
        local path = string.format("i3D.Files.File(%d)", fileIndex)
        xml:setInt(path .. "#fileId", nextId)
        xml:setString(path .. "#filename", self:resolveTexturePath(filename))
        xml:setInt(materialPath .. "." .. tag .. "#fileId", nextId)
        if customName ~= nil then xml:setString(materialPath .. "." .. tag .. "#name", customName) end
        nextId = nextId + 1
        fileIndex = fileIndex + 1
    end
    addMap(getMaterialDiffuseMapFilename(original), "Texture")
    addMap(getMaterialNormalMapFilename(original), "Normalmap")
    addMap(getMaterialGlossMapFilename(original), "Glossmap")
    if not brokenLight then addMap(getMaterialEmissiveMapFilename(original), "Emissivemap") end
    local customIndex = 0
    for _, name in ipairs(self.customMaps) do
        local filename = getMaterialCustomMapFilename(original, name)
        if filename ~= nil and filename ~= "" then
            addMap(filename, string.format("Custommap(%d)", customIndex), name)
            customIndex = customIndex + 1
        end
    end
    self.serial = self.serial + 1
    local filename = self.cacheDirectory .. string.format("material_%d.i3d", self.serial)
    local saved = xml:saveTo(filename)
    xml:delete()
    if not saved then error("Cannot write material carrier cache") end
    return filename
end

function VDMaterial:finishCarrier(root, original)
    if root == nil or root == 0 then error("Engine could not load deformation material") end
    local shape = getChildAt(root, 0)
    if shape == nil or shape == 0 or not getHasClassId(shape, ClassIds.SHAPE) then
        delete(root)
        error("Material carrier geometry did not load; inspect shapes file path in log.txt")
    end
    if not getHasShaderParameter(shape, "vdDentCenter0") then
        delete(root)
        error("Deformation shader did not compile or carrier did not load; inspect log.txt")
    end
    self.carriers[#self.carriers + 1] = root
    setVisibility(root, false)
    -- The engine only supports shared reflection scaling. This donor's
    -- material is private, so changing it here cannot touch source materials.
    local scaling = getMaterialReflectionMapScaling(original)
    if type(scaling) == "number" then setReflectionMapScaling(shape, scaling, true) end
    -- Keep an engine reference to the source material as well. A bare Lua ID
    -- does not protect it from release when the last visible shape is replaced.
    local originalKeeper = clone(shape, false, false, false)
    link(root, originalKeeper)
    setMaterial(originalKeeper, original, 0)
    setVisibility(originalKeeper, false)
    local material = getMaterial(shape, 0)
    self.cache[original] = material
    return material
end

function VDMaterial:requestCarrier(original, node, index, clock)
    if self.cache[original] ~= nil then return self.cache[original] end
    if self.failures[original] ~= nil then error(self.failures[original]) end
    if self.pending ~= nil or clock < self.nextRequestAt then return nil end
    local filename = self:writeCarrier(original, node, index)
    local job = {original = original, node = node, index = index}
    self.pending = job
    self.nextRequestAt = clock + 100
    -- One native streaming request at a time, never a synchronous impact load.
    job.requestId = streamI3DFile(filename, "carrierLoaded", self, job, false, false, false)
    return nil
end

function VDMaterial:carrierLoaded(root, failedReason, job)
    if not self.active or self.pending ~= job then
        if root ~= nil and root ~= 0 then delete(root) end
        return
    end
    self.pending = nil
    -- A vehicle can be sold while its donor is loading. Never use a freed ID.
    if not entityExists(job.node) or getMaterial(job.node, job.index) ~= job.original then
        if root ~= nil and root ~= 0 then delete(root) end
        return
    end
    local ok, result = pcall(self.finishCarrier, self, root, job.original)
    if not ok then
        self.failures[job.original] = tostring(result)
        Logging.error("[VehicleDeformation] Async material preparation failed: %s", tostring(result))
    end
end

function VDMaterial:apply(node, index, captured)
    local original = getMaterial(node, index)
    local parameters = captured or self:captureParameters(node, index)
    local replacement = self.cache[original]
    if replacement == nil then error("Material was not prepared before substitution") end
    setMaterial(node, replacement, index)
    local brokenLight = self:isLightMaterial(original)
    for _, value in ipairs(parameters) do
        if self:canCopyParameter(value.name, brokenLight) and getHasShaderParameter(node, value.name, index) then
            setShaderParameter(node, value.name, value.x, value.y, value.z, value.w, false, index)
        end
    end
    return original
end

function VDMaterial:delete()
    self.active = false
    if self.pending ~= nil and self.pending.requestId ~= nil then
        cancelStreamI3DFile(self.pending.requestId)
    end
    self.pending = nil
    for _, root in ipairs(self.carriers or {}) do
        if entityExists(root) then delete(root) end
    end
    self.carriers = {}
    self.cache = {}
end
