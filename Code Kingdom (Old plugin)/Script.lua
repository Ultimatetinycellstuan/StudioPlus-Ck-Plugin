local serverRoot = "https://service-production.codekingdoms.com:443/roblox/"
local RunService = game:GetService("RunService")
local hydratorVersion = "1.2.0"
local RETRY_INTERVAL_IN_SECONDS = 10

local RunLocation = {
	Unknown = "Unknown",
	StudioLocal = "Roblox Studio",
	StudioServer = "Roblox Studio Test Server",
	StudioClient = "Roblox Studio Test Client"
}

local runLocation = RunLocation.Unknown

wait(0)

if RunService:IsServer() and RunService:IsClient() then

	runLocation = RunLocation.StudioLocal

elseif RunService:IsServer() then

	runLocation = RunLocation.StudioServer

elseif RunService:IsClient() then

	runLocation = RunLocation.StudioClient

end

if runLocation == RunLocation.Unknown then

	return

end

local systemFolder

local isSeparateClient = (runLocation == RunLocation.StudioClient or runLocation == RunLocation.RobloxClient)

if isSeparateClient then

	systemFolder = game.ReplicatedStorage:WaitForChild("CodeKingdoms", 15)

	if ( systemFolder == nil ) then

		error("Code Kingdoms client failed to start, please contact support")

	end

else 

	systemFolder = game.ReplicatedStorage:FindFirstChild("CodeKingdoms")

	if ( systemFolder == nil ) then

		systemFolder = Instance.new("Folder", game.ReplicatedStorage)
		systemFolder.Name = "CodeKingdoms"

	end

end

if ( systemFolder:FindFirstChild('HasPlugin') == nil ) then

	local HasPlugin = Instance.new("BoolValue", systemFolder)
	HasPlugin.Name = "HasPlugin"
	HasPlugin.Value = true

end

local pluginEnvironmentRecord = systemFolder:FindFirstChild("Environment")

if ( pluginEnvironmentRecord == nil ) then

	local Environment = Instance.new("StringValue", systemFolder)
	Environment.Name = "Environment"
	Environment.Value = "production"

elseif( pluginEnvironmentRecord.Value ~= "production") then

	return

end

print( "This game is running using Code Kingdoms on", runLocation )

if ("production" ~= "production") then

	print("Using env production")

end

if not isSeparateClient then

	local folder = Instance.new("Folder")
	folder.Name = "plugin"

	local HttpService = game.HttpService

	local ok, resultString

	local warningWidget = nil
	local widgetBody = nil

	while not ok do

		ok, resultString = pcall( HttpService.GetAsync, HttpService, serverRoot .. "plugin" )

		if ( not ok ) then

			if not warningWidget then

				local info = DockWidgetPluginGuiInfo.new(
					Enum.InitialDockState.Float,
					true,						 -- Window will be initially enabled.
					true,						 -- Override the saved enabled/dock state.
					550,						 -- Width of the floating window.
					500							 -- Height of the floating window.
				)

				warningWidget = plugin:CreateDockWidgetPluginGui("hydratorWidget", info)
				warningWidget.Title = "Code Kingdoms"

				widgetBody = Instance.new("TextLabel")
				widgetBody.TextScaled = false
				widgetBody.TextSize = 14.0
				widgetBody.TextWrapped= true
				widgetBody.Text = [[Please enable HTTP Requests and Script Injection permissions so that the CK Editor can load your project into Roblox Studio.

Follow these steps:

1. Select the "Plugins" tab in the menu
2. Click "Manage Plugins"
3. Locate the "Code Kingdoms" plugin in the list and check that there are ticks next to HTTP Requests and Script Injection 
4. If not, click the small edit icon and make sure these permissions are both checked

Please feel free to contact us via the Code Kingdoms website if you have any questions.
]]
				widgetBody.Font = Enum.Font.Gotham
				widgetBody.TextTruncate = Enum.TextTruncate.AtEnd
				widgetBody.AnchorPoint = Vector2.new(0.5,0.5)
				widgetBody.Size = UDim2.new(1,-20,1,-20)
				widgetBody.Position = UDim2.new(0.5,0,0.5,0)
				widgetBody.SizeConstraint = Enum.SizeConstraint.RelativeXY
				widgetBody.BackgroundColor3 = Color3.new(1, 1, 1)
				widgetBody.TextColor3 = Color3.fromRGB(0, 25, 255)
				widgetBody.TextXAlignment = Enum.TextXAlignment.Left
				widgetBody.BorderSizePixel = 0
				widgetBody.Parent = warningWidget

			end

			print( "Plugin failed to connect to Code Kingdoms server. Retrying in " .. RETRY_INTERVAL_IN_SECONDS .. " seconds." )
			print( "Error: " .. resultString )

			wait( RETRY_INTERVAL_IN_SECONDS )

		elseif warningWidget then

			warningWidget:Destroy()

		end

	end

	print( "Plugin successfully connected to Code Kingdoms server.")

	local json = HttpService:JSONDecode( resultString )

	local moduleScript

	for filename,contents in pairs(json) do

		moduleScript = Instance.new("ModuleScript", folder)
		moduleScript.Name = filename
		moduleScript.Source = contents

	end

	local CkMain = require(folder.CkMain)
	local ck = CkMain( serverRoot, plugin, systemFolder, hydratorVersion )
	ck:setupRuntime()

end
