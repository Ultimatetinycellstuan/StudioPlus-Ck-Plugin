local PluginSettings = (function() local HttpService = game:GetService("HttpService")

local PluginSettings = {}

local USER_SETTINGS_NAME_PREFIX = "user-"
PluginSettings.RELIABLE_HTTP_SERVICE_KEY = "reliableHttpService"
PluginSettings.PLUGIN_KEY = "plugin"
PluginSettings.PLAYTESTING = "playtesting"

function PluginSettings.getUserSettingsKey(plugin)
	local robloxUserId = plugin:GetStudioUserId()
	return USER_SETTINGS_NAME_PREFIX .. robloxUserId
end

function PluginSettings.new(plugin, rootKey)
	assert((typeof(plugin) == "Instance" and plugin.ClassName == "Plugin") or typeof(plugin) == "table")
	assert(typeof(rootKey) == "string")
	local object = {}
	setmetatable(object, {__index = PluginSettings})
	object._rootKey = rootKey
	object._plugin = plugin
	return object
end

function PluginSettings:getName()
	return self._rootKey
end

function PluginSettings:clearAll()
	self._plugin:SetSetting(self._rootKey, "{}")
end

function PluginSettings:getAll()
	local all = self._plugin:GetSetting(self._rootKey)
	if all ~= nil then
		if type(all) == "string" then
			local ok, decoded = pcall(HttpService.JSONDecode, HttpService, all)
			if ok and decoded and type(decoded) == "table" then
				return decoded
			end
		end
		print("Error decoding plugin settings for: " .. self._rootKey)
		self:clearAll()
		return
	end
end

function PluginSettings:setAll(all)
	local encoded = HttpService:JSONEncode(all)
	self._plugin:SetSetting(self._rootKey, encoded)
end

function PluginSettings:get(key)
	assert(type(key) == "string")
	local all = self:getAll() or {}
	return all[key]
end

function PluginSettings:set(key, value)
	assert(type(key) == "string")
	local all = self:getAll() or {}
	all[key] = value
	self:setAll(all)
end

return PluginSettings
 end)()
local PluginSettingsCache = (function() local HttpService = game:GetService("HttpService")

local PluginSettingsCache = {}
setmetatable(PluginSettingsCache, {__index = PluginSettings})

-- 5 MiB
PluginSettingsCache.SIZE_LIMIT = 5 * (2 ^ 20)

-- Abstract using a PluginSettings as a cache with a maximum size.
function PluginSettingsCache.new(plugin, rootKey)
	assert((typeof(plugin) == "Instance" and plugin.ClassName == "Plugin") or typeof(plugin) == "table")
	assert(type(rootKey) == "string")
	local cache = PluginSettings.new(plugin, rootKey)
	setmetatable(cache, {__index = PluginSettingsCache})
	return cache
end

function PluginSettingsCache:set(key, value)
	assert(type(key) == "string")
	local originalCacheContents = self:getAll()

	PluginSettings.set(self, key, value)

	if not self:_isValid() then
		self:clearAll()
		PluginSettings.set(self, key, value)

		if not self:_isValid() then
			self:setAll(originalCacheContents)
			warn('Cannot set "' .. self:getName() .. '" cache for key "' .. key .. '"')
		end
	end
end

function PluginSettingsCache:_isValid()
	local cache = self:getAll()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, cache)
	local cacheSizeLimitExceeded = type(encoded) == "string" and string.len(encoded) > PluginSettingsCache.SIZE_LIMIT
	return ok and not cacheSizeLimitExceeded
end

return PluginSettingsCache
 end)()
local HydratorHttpService = (function() local HttpService = game:GetService("HttpService")

local HydratorHttpService = {}

function HydratorHttpService:setup(serverRoot, cache)
	self._serverRoot = serverRoot
	self._cache = cache
end

function HydratorHttpService:get(endpoint, requestData, cacheable)
	local url, headers, cachedResponse =
		self._cache:getUrlAndHeadersAndCachedResponse(self._serverRoot .. endpoint, requestData, cacheable)

	local response = HttpService:RequestAsync({Url = url, Method = "GET", Headers = headers})
	return self._cache:processResponse(url, response, cachedResponse)
end

return HydratorHttpService
 end)()
local HttpRequestCache = (function() local HttpService = game:GetService("HttpService")
local HttpRequestCache = {}

HttpRequestCache.HTTP_STATUS = {
	OK = 200,
	NOT_MODIFIED = 304,
	NOT_FOUND = 404
}

function HttpRequestCache:setup(cache)
	self.cache = cache
end

function HttpRequestCache:createQueryString(request)
	assert(type(request) == "table" or request == nil)

	if request == nil then
		return ""
	end

	local parts = {}

	for k, v in pairs(request) do
		local encodedValue = ((type(v) == "table") and HttpService:JSONEncode(v)) or v

		table.insert(parts, ("%s=%s"):format(HttpService:UrlEncode(k), HttpService:UrlEncode(encodedValue)))
	end

	table.sort(parts)

	return "?" .. table.concat(parts, "&")
end

function HttpRequestCache:getUrlAndHeadersAndCachedResponse(urlWithoutQuery, requestData, cacheable)
	assert(type(urlWithoutQuery) == "string")
	assert(type(requestData) == "table" or requestData == nil)
	assert(type(cacheable) == "boolean" or cacheable == nil)

	local queryString = HttpRequestCache:createQueryString(requestData)

	local url = urlWithoutQuery .. queryString

	local headers

	local requestEtag, cachedResponseBodyJson = self:cacheLoad(url)

	if cacheable then
		headers = {}

		if requestEtag then
			headers["If-None-Match"] = requestEtag
		end

		headers["Cache-Control"] = "public"
	end

	return url, headers, cachedResponseBodyJson
end

function HttpRequestCache:processResponse(url, response, cachedResponseBodyJson)
	assert(
		self:isSuccessResponse(response),
		("HTTP %d error in POST to %s: %s"):format(response.StatusCode, url, tostring(response.StatusMessage))
	)

	-- Roblox lowercases all headers
	local contentType = response.Headers["content-type"]

	if
		(contentType and string.find(contentType, "application/json")) or response.StatusCode == self.HTTP_STATUS.NOT_MODIFIED
	 then
		local responseBodyJson

		if response.StatusCode ~= self.HTTP_STATUS.NOT_MODIFIED then
			responseBodyJson = HttpService:JSONDecode(response.Body)
		end

		-- Response caching is only implemented for JSON responses
		local responseEtag = response.Headers["etag"]

		if responseEtag and response.Headers["cache-control"] ~= "no-store" then
			if responseBodyJson then
				self:cacheSave(url, responseBodyJson, responseEtag)

				return responseBodyJson
			else
				return cachedResponseBodyJson
			end
		else
			return responseBodyJson
		end
	else
		return response.Body
	end
end

function HttpRequestCache:isSuccessResponse(response)
	return response.Success or response.StatusCode == self.HTTP_STATUS.NOT_MODIFIED
end

function HttpRequestCache:cacheSave(url, responseBodyJson, etag)
	assert(type(url) == "string")
	assert(responseBodyJson ~= nil)
	assert(type(etag) == "string")

	-- TODO ROBLOX-1725 - see if we can bring this back without killing Studio performance
	-- self.cache:set(url, HttpService:JSONEncode({etag = etag, responseBodyJson = responseBodyJson}))
end

function HttpRequestCache:cacheLoad(url)
	assert(type(url) == "string")

	local cached = self.cache:get(url)

	if cached ~= nil then
		local ok, parsed = pcall(HttpService.JSONDecode, HttpService, cached)

		if not ok or parsed == nil or parsed.responseBodyJson == nil or parsed.etag == nil then
			self.cache:set(url, nil)
			return
		end

		return parsed.etag, parsed.responseBodyJson
	end
end

return HttpRequestCache
 end)()
local currentDate = os.date('*t')
local hydrateGenerationSuffix = string.format('(%02d%02d%02d)', currentDate.hour, currentDate.min, currentDate.sec)
-- Must match Roblox error exactly, do not change
local ENABLE_HTTP_ERROR = "Http requests are not enabled. Enable via game settings"

local enAssets = {
	viewCourses = 4458031549,
	enableHttp = 3867015493,
	startCourses = 4481213315,
	joinGroup = 4481226494,
	badRequestError = [[
		The Studio+ plugin has experienced an error trying to connect to the servers, but will continue trying to connect.
		
		If the problem persists, please check your Internet connection or try again later.
		
		Retry attempt (%u) in %u seconds...
		]]
}
local zhAssets = {
	viewCourses = 4481235150,
	startCourses = 4606261369,
	joinGroup = 4606261657,
	enableHttp = 4024033938,
	badRequestError = "Studio+ æä»¶è¯å¾è¿æ¥æå¡å¨åºéï¼ä½ä¼ç»§ç»­å°è¯è¿æ¥ãå¦æè¯¥é®é¢æç»­å­å¨ï¼è¯·æ¥çæ¨çç½ç»è¿æ¥æç¨ååè¯ã"
}


local StudioService = game:GetService("StudioService")
local isZh = StudioService.StudioLocaleId == "zh_CN"
local assets = isZh and zhAssets or enAssets

-- This will always be true for the Chinese Studio install even if they have changed their language in settings
local isLuobuStudio = game:GetService("ContentProvider").BaseUrl == "https://www.roblox.cn/"

local serverRoot = isLuobuStudio and "https://cnstudioplus.com/api/" or "https://studioplus.io/api/"

wait(0)

-- This is incremented each time hydratePlugin is called and used to track whether an in-process hydration should continue
-- if rehydrating during hydration
local hydrationSequence = 0

local isFetching = false
local warningWidget
local startWidget
local coursesWidget

local toolbar = plugin:CreateToolbar("Studio+ " .. hydrateGenerationSuffix)

local coursesButton = toolbar:CreateButton("Courses", "View the Studio+ Courses", "rbxassetid://2974851765")

local CoursesWidget = {}

-- By default this is disabled and shows the HTTP warning when enabled
function CoursesWidget.new()
	local info =
		DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		false, -- Disable by default
		true, -- Override the saved enabled/dock state.
		500, -- width
		700, -- height
		500, -- minWidth
		300 -- minHeight
	)

	-- Use a randomized ID so the widget position isn't saved in case it is moved to a bad location
	local widget = plugin:CreateDockWidgetPluginGui("coursesWidget" .. tick(), info)
	widget.Name = "Courses"
	widget.Title = "Courses"

	-- This will be replaced by the Widget close handler when hydrated
	widget:BindToClose(
		function()
			-- Abort hydration
			isFetching = false
			-- Run handler in a separate co-routine in case it yields, which causes Roblox to hard crash.
			spawn(
				function()
					widget.Enabled = false
					startWidget.widget.Enabled = true
				end
			)
		end
	)

	local body = Instance.new("ImageButton")

	body.Name = "ImageLabel"
	body.BackgroundTransparency = 1

	body.Image = "rbxassetid://" .. assets.enableHttp
	body.Size = UDim2.new(0, 500, 0, 640)
	body.Parent = widget

	local object = {
		widget = widget,
		body = body
	}
	setmetatable(object, {__index = CoursesWidget})
	return object
end

function CoursesWidget:show()
	self.widget.Enabled = true
end

function CoursesWidget:hide()
	self.widget.Enabled = false
end

function CoursesWidget:destroy()
	self.widget:Destroy()
end

local StartWidget = {}

function StartWidget.new(preHydrateOpenFn)
	assert(type(preHydrateOpenFn) == "function")

	local width = 320
	local height = 80
	local info =
		DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Left,
		true, -- Window will be initially enabled.
		true, -- Override the saved enabled/dock state.
		width,
		height,
		width,
		height
	)

	-- Use a randomized ID so the widget position isn't saved in case it is moved to a bad location
	local widget = plugin:CreateDockWidgetPluginGui("startWidget" .. tick(), info)
	widget.Name = "Studio+"
	widget.Title = "Studio+"

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.Parent = widget
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.fromRGB(42, 22, 51)

	local showJoinGroup = isZh and false

	local function makeButton(name, assetId)
		local button = Instance.new("ImageButton")
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.Name = name
		button.Image = "rbxassetid://" .. assetId
		button.MouseEnter:Connect(function()
			plugin:GetMouse().Icon = "rbxassetid://" .. 2932358021
		end)
		button.MouseLeave:Connect(function()
			plugin:GetMouse().Icon = ""
		end)
		return button
	end

	local instance = {
		widget = widget,
		open = function(self, isJoinGroupActivated)
			plugin:GetMouse().Icon = ""
			preHydrateOpenFn(isJoinGroupActivated)
		end,
		close = function()
			-- Abort hydrating
			isFetching = false
			widget.Enabled = false
		end
	}

	local body = makeButton("BackgroundImage", assets.viewCourses)
	body.Position = UDim2.new(0, 0, 0, 0)
	body.Size = UDim2.new(0, 327, 0, 177)
	body.Parent = frame

	if isZh then
		local startCourses = makeButton("StartCourses", assets.startCourses)
		if showJoinGroup then
			startCourses.Position = UDim2.new(0, 125, 0, 70)
		else
			startCourses.Position = UDim2.new(0, 220, 0, 70)
		end
		startCourses.Activated:Connect(
			function()
				instance:open(false)
			end
		)
		startCourses.Size = UDim2.new(0, 91, 0, 80)
		startCourses.Parent = frame
	else
		body.Activated:Connect(
			function()
				instance:open(false)
			end
		)
	end

	if showJoinGroup then
		local joinGroup = makeButton("JoinGroup", assets.joinGroup)
		joinGroup.Position = UDim2.new(0, 220, 0, 70)
		joinGroup.Size = UDim2.new(0, 91, 0, 80)
		joinGroup.Parent = frame
		joinGroup.Activated:Connect(
			function()
				instance:open(true)
			end
		)
	end

	widget:BindToClose(
		function()
			instance:close()
		end
	)

	setmetatable(instance, {__index = StartWidget})
	return instance
end

function StartWidget:destroy()
	self.widget:Destroy()
end

-- Define a table to wrap a widget for displaying a warning
local WarningWidget = {}

function WarningWidget.new()
	local info =
		DockWidgetPluginGuiInfo.new(
		Enum.InitialDockState.Float,
		true, -- Window will be initially enabled.
		true, -- Override the saved enabled/dock state.
		400, -- Width of the floating window.
		200 -- Height of the floating window.
	)

	-- Use a randomized ID so the widget position isn't saved in case it is moved to a bad location
	local widget = plugin:CreateDockWidgetPluginGui("warningWidget" .. tick(), info)
	widget.Name = "Studio+ Plugin Error"
	widget.Title = "Studio+ Plugin Error"

	local body = Instance.new("TextLabel")
	body.TextScaled = false
	body.TextSize = 16.0
	body.TextWrapped = true
	body.Font = Enum.Font.Gotham
	body.TextTruncate = Enum.TextTruncate.AtEnd
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.AnchorPoint = Vector2.new(0.5, 0.5)
	body.Size = UDim2.new(0.9, 0, 0.9, 0)
	body.Position = UDim2.new(0.5, 0, 0.5, 0)
	body.SizeConstraint = Enum.SizeConstraint.RelativeXY
	body.BackgroundColor3 = Color3.new(1, 1, 1)
	body.TextColor3 = Color3.fromRGB(211, 06, 58)
	body.BorderSizePixel = 0
	body.Parent = widget

	local object = {
		widget = widget,
		body = body
	}
	setmetatable(object, {__index = WarningWidget})
	return object
end

function WarningWidget:setText(text)
	self.body.Text = text
end

function WarningWidget:destroy()
	self.widget:Destroy()
end


-- These settings persist for the duration of a Roblox Studio run (including during rehydration)
local sessionSettings = {
	fallbackServerRoot = isLuobuStudio and "https://studioplus.io/api/" or "https://cnstudioplus.com/api/"
}

local coursesButtonSignal
local main

local function toboolean(value)
	return not (not value)
end

local function fetchPluginCodeAndRunMain(isCourseProject, runTests, hydrationSequence, isJoinGroupActivated)
	assert(type(isCourseProject) == "boolean", "isCourseProject must be a boolean")
	assert(type(runTests) == "boolean" or runTests == nil, "runTests must be a boolean or nil")
	assert(type(hydrationSequence) == "number", "hydrationSequence must be a number")
	assert(type(isJoinGroupActivated) == "boolean" or isJoinGroupActivated == nil, "isJoinGroupActivated must be a boolean or nil") 

	if isFetching then
		return
	end
	isFetching = true

	local RunService = game:GetService("RunService")
	local canShowMessages = RunService:IsEdit()

	local response

	local retryCount = 1

	local currentHydrationSequence = hydrationSequence
	sessionSettings.hydrationSequence = currentHydrationSequence

	repeat
		local ok
		ok, response =
			pcall(
			function()
				return HydratorHttpService:get("plugin", {}, false)
			end
		)

		local error = (ok and response and response.error) or (not ok and response)

		if error then
			local retrySeconds = (error == ENABLE_HTTP_ERROR) and 1 or 10
			while retrySeconds > 0 do
				-- Abort retries if hydratePlugin is called again
				if currentHydrationSequence ~= hydrationSequence or not isFetching then
					return
				end

				if canShowMessages then
					print(error)
					if error == ENABLE_HTTP_ERROR then
						coursesWidget:show()
					else
						if not warningWidget then
							warningWidget = WarningWidget.new()
						end
						local badRequestMessage =
							isZh and assets.badRequestError or string.format(assets.badRequestError, retryCount, retrySeconds)
						warningWidget:setText(badRequestMessage)
					end
				end

				retrySeconds = retrySeconds - 1
				wait(1)
			end
			retryCount = retryCount + 1
		end
	until not error

	isFetching = false

	-- Reset change history waypoints lest an undo revert the enabling of HTTP requests.
	game:GetService("ChangeHistoryService"):ResetWaypoints()

	if warningWidget then
		warningWidget:destroy()
	end

	if canShowMessages then
		print("Studio+ plugin successfully connected to server.")
	end

	local setupSource = response.init

	if not (setupSource and type(setupSource) == "string") then
		if canShowMessages then
			warningWidget = WarningWidget.new()
			warningWidget:setText("The files received from the server were missing a setup script")
		end
		return
	end

	local setupScript = Instance.new("ModuleScript")
	setupScript.Source = setupSource
	local setup = require(setupScript)
	local newMain =
		setup(
		response,
		"ceece109d4dffa5ed332a4424199667d5e2e228e83f75d9d46393d6cd007db3a",
		WarningWidget,
		{
			plugin = plugin,
			serverRoot = serverRoot,
			isCourseProject = isCourseProject,
			envType = "production",
			runTests = runTests,
			hydratorCoursesWidget = coursesWidget.widget,
			hydratorCoursesButton = coursesButton,
			hydratorStartWidget = startWidget,
			sessionSettings = sessionSettings,
			showJoinGroupOnHydrate = isJoinGroupActivated,
			rehydrate = function(replacementServerRoot)
				serverRoot = replacementServerRoot or serverRoot
				hydratePlugin(false, true)
			end
		}
	)
	-- coursesWidget lifecycle is now managed by Main
	coursesWidget = nil

	main = newMain

	if coursesButtonSignal then
		coursesButtonSignal:Disconnect()
		coursesButtonSignal = nil
	end
end

function hydratePlugin(runTests, skipStartButton)
	hydrationSequence = hydrationSequence + 1

	local RunService = game:GetService("RunService")

	if not RunService:IsServer() and not RunService:IsEdit() then
		-- The plugin can only be hydrated from the server or in edit mode (for Team Create IsEdit and IsClient are true).
		return
	end

	if not coursesButtonSignal then
		coursesButtonSignal =
			coursesButton.Click:Connect(
			function()
				hydratePlugin(false, true)
			end
		)
	end

	if main then
		main:Cleanup()
		main = nil
	end

	local cache = PluginSettingsCache.new(plugin, PluginSettings.PLUGIN_KEY)
	HttpRequestCache:setup(cache)
	HydratorHttpService:setup(serverRoot, HttpRequestCache)

	local configFolder = game.ServerStorage:FindFirstChild("CourseConfig")
	local isCourseProject = toboolean(configFolder and configFolder:FindFirstChild("CourseId"))

	if coursesWidget then
		coursesWidget:destroy()
	end
	coursesWidget = CoursesWidget.new()
	if startWidget then
		startWidget:destroy()
	end
	startWidget =
		StartWidget.new(
		function(isJoinGroupActivated)
			startWidget.widget.Enabled = false
			fetchPluginCodeAndRunMain(isCourseProject, runTests, hydrationSequence, isJoinGroupActivated)
		end
	)

	if isCourseProject or skipStartButton then
		fetchPluginCodeAndRunMain(isCourseProject, runTests, hydrationSequence, false)
	end
end

if ("production" ~= "production" and "production" ~= "staging") then
	print("Using envType production")
	-- Comment out below code if testing plugin updates not breaking
	local devToolbar = plugin:CreateToolbar("Studio+ Dev " .. hydrateGenerationSuffix)
	local button =
		devToolbar:CreateButton(
		"Rehydrate",
		"Re-runs the code to hydrate the plugin from the server",
		"rbxassetid://2224900220"
	)
	button.Click:connect(
		function()
			hydratePlugin()
		end
	)

	local rehydrateAction = plugin:CreatePluginAction("rehydrate", "Rehydrate", "Rehydrate", true)

	rehydrateAction.Triggered:connect(
		function()
			hydratePlugin()
		end
	)

	local runTestsActions =
		plugin:CreatePluginAction("runTests", "Rehydrate and run tests", "Rehydrate and run tests", true)

	runTestsActions.Triggered:connect(
		function()
			hydratePlugin(true, true)
		end
	)

	local testButton = devToolbar:CreateButton("Run Tests", "Rehydrates and runs plugin tests", "rbxassetid://2224900220")
	testButton.Click:connect(
		function()
			hydratePlugin(true, true)
		end
	)

	local clearSettingsButton =
		devToolbar:CreateButton("Clear Settings", "Deletes the settings for the plugin", "rbxassetid://1351528627")
	clearSettingsButton.Click:connect(
		function()
			print("Studio+ plugin settings were cleared.")
			PluginSettings.new(plugin, PluginSettings.PLUGIN_KEY):clearAll()
			PluginSettings.new(plugin, PluginSettings.RELIABLE_HTTP_SERVICE_KEY):clearAll()
			PluginSettings.new(plugin, PluginSettings.getUserSettingsKey(plugin)):clearAll()
			hydratePlugin()
		end
	)
end

hydratePlugin()
