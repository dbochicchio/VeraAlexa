------------------------------------------------------------------------
-- Copyright (c) 2018-2021 Daniele Bochicchio
-- License: MIT License
-- Source Code: https://github.com/dbochicchio/VeraAlexa
------------------------------------------------------------------------

module("L_VeraAlexa1", package.seeall)

local _PLUGIN_NAME = "VeraAlexa"
local _PLUGIN_VERSION = "0.97"

local devMode = false
local debugMode = false
local openLuup = false

-- SIDs
local MYSID									= "urn:bochicchio-com:serviceId:VeraAlexa1"
local HASID									= "urn:micasaverde-com:serviceId:HaDevice1"

-- COMMANDS
local COMMANDS_SPEAK						= "-e speak:%q -d %q"
local COMMANDS_ROUTINE						= "-e automation:%q -d %q"
local COMMANDS_LASTALEXA					= "-lastalexa"
local COMMANDS_SETVOLUME					= "-e vol:%s -d %q"
local COMMANDS_GETVOLUME					= "-q -d %q | sed ':a;N;$!ba;s/\\n/ /g' | grep 'volume' | sed -r 's/^.*\"volume\":\\s*([0-9]+)[^0-9]*$/\\1/g'"
local BIN_PATH								= "/storage/alexa"
local SCRIPT_NAME							= "alexa_remote_control_plain.sh"
local SCRIPT_NAME_ADV						= "alexa_remote_control.sh"

-- libs
local lfs = require("lfs")
local json = require("dkjson")

--- ***** GENERIC FUNCTIONS *****
local function dump(t, seen)
	if t == nil then return "nil" end
	if seen == nil then seen = {} end
	local sep = ""
	local str = "{ "
	for k, v in pairs(t) do
		local val
		if type(v) == "table" then
			if seen[v] then
				val = "(recursion)"
			else
				seen[v] = true
				val = dump(v, seen)
			end
		elseif type(v) == "string" then
			if #v > 255 then
				val = string.format("%q", v:sub(1, 252) .. "...")
			else
				val = string.format("%q", v)
			end
		elseif type(v) == "number" and (math.abs(v - os.time()) <= 86400) then
			val = tostring(v) .. "(" .. os.date("%x.%X", v) .. ")"
		else
			val = tostring(v)
		end
		str = str .. sep .. k .. "=" .. val
		sep = ", "
	end
	str = str .. " }"
	return str
end

local function getVarNumeric(sid, name, dflt, devNum)
	local s = luup.variable_get(sid, name, devNum) or ""
	if s == "" then return dflt end
	s = tonumber(s)
	return (s == nil) and dflt or s
end

local function getVar(sid, name, dflt, devNum)
	local s = luup.variable_get(sid, name, devNum) or ""
	if s == "" then return dflt end
	return (s == nil) and dflt or s
end

local function L(devNum, msg, ...) -- luacheck: ignore 212
	local str = string.format("%s[%s@%s]", _PLUGIN_NAME, _PLUGIN_VERSION, devNum)
	local level = 50
	if type(msg) == "table" then
		str = string.format("%s%s:%s", str, msg.prefix or _PLUGIN_NAME, msg.msg)
		level = msg.level or level
	else
		str = string.format("%s:%s", str, msg)
	end

	str = string.gsub(str, "%%(%d+)", function(n)
		n = tonumber(n, 10)
		if n < 1 or n > #arg then return "nil" end
		local val = arg[n]
		if type(val) == "table" then
			return dump(val)
		elseif type(val) == "string" then
			return string.format("%q", val)
		elseif type(val) == "number" and math.abs(val - os.time()) <= 86400 then
			return string.format("%s(%s)", val, os.date("%x.%X", val))
		end
		return tostring(val)
	end)
	luup.log(str, level)
end

local function D(devNum, msg, ...)
	debugMode = getVarNumeric(MYSID, "DebugMode", 0, devNum) == 1

	if debugMode then
		local t = debug.getinfo(2)
		local pfx = string.format("(%s@%s)", t.name or "", t.currentline or "")
		L(devNum, {msg = msg, prefix = pfx}, ...)
	end
end

-- Set variable, only if value has changed.
local function setVar(sid, name, val, devNum)
	val = (val == nil) and "" or tostring(val)
	local s = luup.variable_get(sid, name, devNum) or ""
	D(devNum, "setVar(%1,%2,%3,%4) old value %5", sid, name, val, devNum, s)
	if s ~= val then
		luup.variable_set(sid, name, val, devNum)
		return true, s
	end
	return false, s
end

local function split(str, sep)
	if sep == nil then sep = "," end
	local arr = {}
	if #(str or "") == 0 then return arr, 0 end
	local rest = string.gsub(str or "", "([^" .. sep .. "]*)" .. sep,
		function(m)
			table.insert(arr, m)
			return ""
		end)
	table.insert(arr, rest)
	return arr, #arr
end

local function map(arr, f, res)
	res = res or {}
	for ix, x in ipairs(arr) do
		if f then
			local k, v = f(x, ix)
			res[k] = (v == nil) and x or v
		else
			res[x] = x
		end
	end
	return res
end

local function initVar(sid, name, dflt, dev)
	local currVal = luup.variable_get(sid, name, dev)
	if currVal == nil then
		luup.variable_set(sid, name, tostring(dflt), dev)
		return tostring(dflt)
	end
	return currVal
end

function deviceMessage(devNum, message, error, timeout)
	local status = error and 2 or 4
	timeout = timeout or 15
	D(devNum, "deviceMessage(%1,%2,%3,%4)", devNum, message, error, timeout)
	luup.device_message(devNum, status, message, timeout, _PLUGIN_NAME)
end

function os.capture(cmd, raw)
	local handle = assert(io.popen(cmd, 'r'))
	local output = assert(handle:read('*a'))

	handle:close()

	if raw then
		return output
	end

	output = string.gsub(
		string.gsub(
			string.gsub(output, '^%s+', ''), 
			'%s+$',
			''
		),
		'[\n\r]+',
		' ')

   return output
end

-- ** PLUGIN CODE **
local ttsQueue = {}

function checkQueue(devNum)
	devNum = tonumber(devNum)

	if ttsQueue[devNum] == nil then ttsQueue[devNum] = {} end

	D(devNum, "checkQueue: %1 in queue", #ttsQueue[devNum])

	-- is queue now empty?
	if #ttsQueue[devNum] == 0 then
		D(devNum, "checkQueue: queue is empty")
		return true
	end

	D(devNum, "checkQueue: play next")

	-- get the next one
	sayTTS(devNum, ttsQueue[devNum][1])

	-- remove from queue
	table.remove(ttsQueue[devNum], 1)
end

function addToQueue(devNum, settings)
	devNum = tonumber(devNum)

	L(devNum, "addToQueue(%1)", settings)
	if ttsQueue[devNum] == nil then ttsQueue[devNum] = {} end

	local defaultBreak = getVar(MYSID, "DefaultBreak", 3, devNum)

	local startPlaying = #ttsQueue[devNum] == 0

	local howMany = tonumber(settings.Repeat or 1)
	D(devNum, 'addToQueue(2): %1 - %2', #ttsQueue[devNum], startPlaying)

	local useAnnoucements = getVarNumeric(MYSID, "UseAnnoucements", 0, devNum)
	if useAnnoucements == 1 then
		-- no need to repeat, just concatenate
		local text = ""
		for f = 1, howMany do
			text = text .. "<s>" .. settings.Text .. '</s>' .. (f == howMany and "" or '<break time="' .. defaultBreak .. 's" />')
		end
		settings.Text = text

		table.insert(ttsQueue[devNum], settings)
	else
		for _ = 1, howMany do
			table.insert(ttsQueue[devNum], settings)
		end
	end
	D(devNum, 'addToQueue(3): %1', #ttsQueue[devNum])

	if startPlaying then
		D(devNum, 'addToQueue(4): playing')
		checkQueue(devNum)
	end
end

local function updateDevicesInternal(devNum)
	local function readFile(path)
		local file = io.open(path, "rb") -- r read mode and b binary mode
		if not file then return nil end
		local content = file:read "*a" -- *a or *all reads the whole file
		file:close()
		return content
	end
	local content = readFile(BIN_PATH .. '/.alexa.devicelist.json')

	local _ ,json = pcall(require, "dkjson")

	-- check for dependencies
	if not json or type(json) ~= "table" then
		L('Failure: dkjson library not found')
		luup.set_failure( 1, devNum)
		return
	end

	local jsonResponse, _, err = json.decode(content)
	if jsonResponse == nil then return end

	local formattedValue = ''
	local devices = jsonResponse.devices
	for _, device in ipairs(devices) do
		formattedValue = formattedValue .. device.accountName .. ', ' .. tostring(device.online) .. ',' .. tostring(device.serialNumber) .. ',' .. device.deviceFamily ..'\n'
	end

	setVar(MYSID, "Devices", formattedValue, devNum)
end

local function safeCall(devNum, call)
	local function err(x)
		local s = string.dump(call)
		D(devNum, '[Error] %1 - %2', x, s)
	end

	local _, r, _ = xpcall(call, err)
	return r
end

local function executeCommand(devNum, command)
	return safeCall(devNum, function()
		if devMode then
			D(devNum, "executeCommand: %1", command)
		end

		local response = os.capture(command)

		-- set failure
		local hasError = (response:find("ERROR: Amazon Login was unsuccessful.") or -1)>0
		setVar(HASID, "CommFailure", (hasError and 2 or 0), devNum)

		-- lastresponse
		setVar(MYSID, "LatestResponse", response, devNum)
		D(devNum, "Response from Alexa.sh: %1", response)

		updateDevicesInternal(devNum)

		return response
	end)
end

local function buildCommand(devNum, settings)
	local args = "export EMAIL=%q && export PASSWORD=%q && export MFASECRET=%q && export NORMALVOL=%q && export SPEAKVOL=%q && export TTS_LOCALE=%q && export LANGUAGE=%q && export AMAZON=%q && export ALEXA=%q && export USE_ANNOUNCEMENT_FOR_SPEAK=%q && export TMP=%q && %s/" .. SCRIPT_NAME .. " "
	local username = getVar(MYSID, "Username", "", devNum)
	local password = getVar(MYSID, "Password", "", devNum) .. getVar(MYSID, "OneTimePassCode", "", devNum)
	local mfaSecret = getVar(MYSID, "MFASecret", "", devNum)
	local defaultVolume = getVarNumeric(MYSID, "DefaultVolume", 0, devNum)
	local announcementVolume = getVarNumeric(MYSID, "AnnouncementVolume", 0, devNum)
	local defaultDevice = getVar(MYSID, "DefaultEcho", "", devNum)
	local alexaHost = getVar(MYSID, "AlexaHost", "", devNum)
	local amazonHost = getVar(MYSID, "AmazonHost", "", devNum)
	local language = getVar(MYSID, "Language", "", devNum)
	local useAnnoucements = getVarNumeric(MYSID, "UseAnnoucements", 0, devNum)

	local device = settings.GroupZones or settings.GroupDevices or defaultDevice
	if device == "LASTALEXA" then
		device = getLastAlexa(devNum, settings) or defaultDevice
		settings.GroupZones = device
		D(devNum, "Getting Last Alexa: %1", device)
	end

	local command = string.format(args, username, password, mfaSecret,
										(defaultVolume or announcementVolume),
										(settings.Volume or announcementVolume),
										(settings.Language or language), (settings.Language or language),
										amazonHost, alexaHost,
										useAnnoucements,
										BIN_PATH, BIN_PATH,
										(settings.Text or "Test"),
										device)

	-- reset onetimepass
	setVar(MYSID, "OneTimePassCode", "", devNum)
	return command, settings
end

function sayTTS(devNum, settings)
	local defaultDevice = getVar(MYSID, "DefaultEcho", "", devNum)
	local text = (settings.Text or "Test")

	local command, newSettings = buildCommand(devNum, settings)
	local args = string.format(COMMANDS_SPEAK,
								text,
								(newSettings.GroupZones or newSettings.GroupDevices or defaultDevice))
	command = command .. args

	D(devNum, "Executing command [TTS]: %1", args)
	executeCommand(devNum, command)

	-- wait for the next one in queue
	local defaultBreak = getVar(MYSID, "DefaultBreak", 3, devNum)
	local useAnnoucements = getVarNumeric(MYSID, "UseAnnoucements", 0, devNum)
	local timeout = defaultBreak -- in seconds

	if useAnnoucements == 0 then
		-- wait for x seconds based on string length
		timeout =  0.062 * string.len(text) + 1
	end

	luup.call_delay("checkQueue", timeout, devNum)
	D(devNum, "Queue will be checked again in %1 secs", timeout)
end

function runRoutine(devNum, settings)
	local defaultDevice = getVar(MYSID, "DefaultEcho", "", devNum)

	local command, newSettings = buildCommand(devNum, settings)
	local args = string.format(COMMANDS_ROUTINE,
									newSettings.RoutineName,
									(newSettings.GroupZones or newSettings.GroupDevices or defaultDevice))
									
	command = command .. args

	D(devNum, "Executing command [runRoutine]: %1", args)
	executeCommand(devNum, command)
end

function runCommand(devNum, settings)
	local command = buildCommand(devNum, settings) .. settings.Command

	D(devNum, "Executing command [runCommand]: %1", settings.Command)
	executeCommand(devNum, command)
end

function getLastAlexa(devNum, settings)
	settings.GroupZones = 'NULL'
	settings.GroupDevices = 'NULL'
	
	local command = buildCommand(devNum, settings) .. COMMANDS_LASTALEXA
	local response = executeCommand(devNum, command)
	D(devNum, "Executing command [lastAelxa]: %1", response)
	return response
end

function setVolume(volume, devNum, settings)
	local defaultVolume = getVarNumeric(MYSID, "DefaultVolume", 0, devNum)
	local defaultDevice = getVar(MYSID, "DefaultEcho", "", devNum)
	local echoDevice = (settings.GroupZones or settings.GroupDevices or defaultDevice)

	local finalVolume = settings.DesiredVolume or 0
	D(devNum, "Volume requested for %2: %1", finalVolume, echoDevice)

	if settings.DesiredVolume == nil and volume ~= 0 then
		-- alexa doesn't support +1/-1, so we must first get current volume
		local command = buildCommand(devNum, settings) ..
								string.format(COMMANDS_GETVOLUME, echoDevice)
		local response = executeCommand(devNum, command)
		response = string.gsub(response, '"','')
		local currentVolume = tonumber(response or defaultVolume)

		D(devNum, "Volume for %2: %1", currentVolume, echoDevice)
		finalVolume = currentVolume + (volume * 10)
	end

	D(devNum, "Volume for %2 set to: %1", finalVolume, echoDevice)
	local command = buildCommand(devNum, settings) ..
						string.format(COMMANDS_SETVOLUME, finalVolume, echoDevice)

	executeCommand(devNum, command)
end

function isFile(name)
	if type(name)~="string" then return false end
	return os.rename(name,name) and true or false
end

function setupScripts(devNum)
	D(devNum, "Setup in progress")
	-- mkdir
	lfs.mkdir(BIN_PATH)

	-- download script from github
	executeCommand(devNum, "curl https://raw.githubusercontent.com/thorsten-gehrig/alexa-remote-control/master/" .. SCRIPT_NAME .. " > " .. BIN_PATH .. "/" .. SCRIPT_NAME)

	-- add permission using lfs
	executeCommand(devNum, "chmod 777 " .. BIN_PATH .. "/" .. SCRIPT_NAME)
	-- TODO: fix this and use lfs
	-- lfs.attributes(BIN_PATH .. "/alexa_remote_control.sh", {permissions = "777"})

	-- install jq
	local currentVer = tonumber(luup.short_version or "1")
	if not openLuup and currentVer >= 7.32 then
		executeCommand(devNum, "opkg update && opkg --force-depends install jq")
	end

	-- first command must be executed to create cookie and setup the environment
	executeCommand(devNum, buildCommand(devNum, {}))

	D(devNum, "Setup completed")
end

function updateDevices(devNum)
	D(devNum, 'updateDevices: %1', devNum)
	executeCommand(devNum, buildCommand(devNum, {}) .. '-a')
end

function reset(devNum)
	os.execute("rm -r " .. BIN_PATH .. "/*")
	setupScripts(devNum)
end

function startPlugin(devNum)
	L(devNum, "Plugin starting")

	-- detect OpenLuup
	for _, v in pairs(luup.devices) do
		if v.device_type == "openLuup" then
			openLuup = true
			BIN_PATH = "/etc/cmh-ludl/VeraAlexa"
		end
	end

	D(devNum, "OpenLuup: %1", openLuup)

	-- jq installed?
	if isFile("/usr/bin/jq") then
		D(devNum, "jq: true")
		SCRIPT_NAME = SCRIPT_NAME_ADV

		deviceMessage(devNum, "Clearing...", false, 5)
	else
		D(devNum, "jq: false")

		-- notify the user to install jq
		local currentVer = tonumber(luup.short_version or "1")

		-- ask to install jq con openLuup
		if openLuup then
			deviceMessage(devNum, 'Please install jq package.', true, 0)
		end

		-- try to install on VeraOS 7.32+
		if currentVer >= 7.32 then
			setVar(HASID, "Configured", 0, devNum)
			D(devNum, "jq: false - forced install")
		end
	end

	-- init default vars
	initVar(MYSID, "DebugMode", 0, devNum)
	BIN_PATH = initVar(MYSID, "BinPath", BIN_PATH, devNum)
	initVar(MYSID, "Username", "youraccount@amazon.com", devNum)
	initVar(MYSID, "Password", "password", devNum)
	initVar(MYSID, "MFASecret", "", devNum)
	initVar(MYSID, "DefaultEcho", "Bedroom", devNum)
	initVar(MYSID, "DefaultVolume", 50, devNum)

	-- migration
	if initVar(MYSID, "AnnouncementVolume", "0", devNum) == "0" then
		local volume = getVarNumeric(MYSID, "DefaultVolume", 0, devNum)
		setVar(MYSID, "AnnouncementVolume", volume, devNum)
		setVar(HASID, "AnnouncementVolume", nil, devNum) -- bug fixing
	end

	-- init default values for US
	initVar(MYSID, "Language", "en-us", devNum)
	initVar(MYSID, "AlexaHost", "pitangui.amazon.com", devNum)
	initVar(MYSID, "AmazonHost", "amazon.com", devNum)

	-- annoucements
	initVar(MYSID, "UseAnnoucements", "0", devNum)
	initVar(MYSID, "DefaultBreak", 3, devNum)

	-- OTP
	initVar(MYSID, "OneTimePassCode", "", devNum)

	-- categories
	if luup.attr_get("category_num", devNum) == nil then
		luup.attr_set("category_num", "15", devNum)			-- A/V
	end

	-- generic
	initVar(HASID, "CommFailure", 0, devNum)

	-- currentversion
	local vers = initVar(MYSID, "CurrentVersion", "0", devNum)
	if vers ~= _PLUGIN_VERSION then
		-- new version, let's reload the script again
		L(devNum, "New version detected: reconfiguration in progress")
		setVar(HASID, "Configured", 0, devNum)
		setVar(MYSID, "CurrentVersion", _PLUGIN_VERSION, devNum)
	end

	-- check for configured flag and for the script
	local configured = getVarNumeric(HASID, "Configured", 0, devNum)
	if configured == 0 or not isFile(BIN_PATH .. "/" .. SCRIPT_NAME) then
		setupScripts(devNum)
		setVar(HASID, "Configured", 1, devNum)
	else
		D(devNum, "Engine correctly configured: skipping config")
	end

	-- randomizer
	math.randomseed(tonumber(tostring(os.time()):reverse():sub(1,6)))

	checkQueue(devNum)

	-- status
	luup.set_failure(0, devNum)
	return true, "Ready", _PLUGIN_NAME
end