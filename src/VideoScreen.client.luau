-- Plays the encoded video on screen, locked to the Workspace sound. Press Play in Studio; nothing else to do.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VideoPlayer = require(Shared:WaitForChild("VideoPlayer"))

local SCALE = "fill" -- "fill" = whole screen (aspect kept, black bars); or a number = pixels per video pixel
local SOUND_NAME = nil -- optional: name of a Sound in Workspace to use as the clock; nil = free-run at the video's fps
local OFFSET = 0 -- seconds of video to skip when the sound is at its start (tune the sync here)
local OPTS = { smooth = true, blend = true } -- bilinear upscale + crossfade between frames

local t0 = os.clock()
local video = VideoPlayer.load(require(Shared:WaitForChild("VideoData")))
print(("VideoScreen: %dx%d, %d frames, %.0fs, loaded in %.0f ms"):format(video.w, video.h, #video.frames, video.duration, (os.clock() - t0) * 1000))

local gui = Players.LocalPlayer:WaitForChild("PlayerGui")
local label = VideoPlayer.makeScreen(video, gui, SCALE)

-- Status line under the video: sync numbers, or the reason nothing is drawing.
local status = Instance.new("TextLabel")
status.Name = "Status"
status.BackgroundTransparency = 1
status.TextColor3 = Color3.new(1, 1, 1)
status.TextStrokeTransparency = 0.5
status.TextSize = 18
status.Font = Enum.Font.Code
status.Size = UDim2.new(1, -16, 0, 24)
status.Position = UDim2.new(0, 8, 1, -28)
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = label

local sound = SOUND_NAME and workspace:WaitForChild(SOUND_NAME, 10)
local blocked = false
if sound then
	VideoPlayer.playSynced(video, label, sound, OFFSET, OPTS)
else
	VideoPlayer.play(video, label, 1, OPTS)
end

-- Catch the player's "stopped" warning so the reason shows on screen too.
local LogService = game:GetService("LogService")
LogService.MessageOut:Connect(function(msg, kind)
	if kind == Enum.MessageType.MessageWarning and msg:find("VideoPlayer stopped") then blocked = msg end
end)

local lastPrint = 0
RunService.Heartbeat:Connect(function()
	if blocked then
		status.TextColor3 = Color3.fromRGB(255, 90, 90)
		status.Text = "BLOCKED: enable Game Settings > Security > Allow Mesh & Image APIs, Save, then Play again"
		return
	end
	local t = sound and sound.IsPlaying and sound.PlaybackSpeed > 0 and sound.TimePosition / sound.PlaybackSpeed or -1
	local frame = t >= 0 and math.floor(t / video.delay) % #video.frames + 1 or 0
	status.Text = t >= 0 and ("song %d:%05.2f  frame %d/%d  speed %.5fx"):format(t // 60, t % 60, frame, #video.frames, sound.PlaybackSpeed)
		or "sound not playing: video free-running"
	if os.clock() - lastPrint > 5 then lastPrint = os.clock(); print("VideoScreen: " .. status.Text) end
end)
