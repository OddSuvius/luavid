--!strict
--!native
-- Decodes LVD1 data (see tools/luavid-encode.py) into an EditableImage and plays it on an ImageLabel,
-- either free-running at the video's own frame rate or locked to a Sound's playback position.
local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
-- Optional: a DEFLATE decoder module next to this one enables the zlib container (encoder ZLIB=1).
local inflateModule = script.Parent:FindFirstChild("Inflate")
local Inflate = inflateModule and require(inflateModule)

local KEEP = 255
local B64 = {}
do
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do B64[string.byte(chars, i)] = i - 1 end
end

local function base64Decode(s: string): buffer
	local n = #s
	local pad = (string.sub(s, n) == "=" and 1 or 0) + (string.sub(s, n - 1, n - 1) == "=" and 1 or 0)
	local size = n // 4 * 3 - pad
	local out = buffer.create(size)
	local o = 0
	for i = 1, n - 4, 4 do -- all full groups except the last (which may be padded)
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = B64[a] * 262144 + B64[b] * 4096 + B64[c] * 64 + B64[d]
		buffer.writeu8(out, o, v // 65536); buffer.writeu8(out, o + 1, v // 256 % 256); buffer.writeu8(out, o + 2, v % 256)
		o += 3
	end
	local a, b, c, d = string.byte(s, n - 3, n)
	local v = B64[a] * 262144 + B64[b] * 4096 + (B64[c] or 0) * 64 + (B64[d] or 0)
	for k, byte in { v // 65536, v // 256 % 256, v % 256 } do
		if o + k - 1 < size then buffer.writeu8(out, o + k - 1, byte) end
	end
	return out
end

export type Video = { data: buffer, w: number, h: number, qy: number, qc: number,
	frames: { { start: number, stop: number, key: boolean, chroma: boolean, cut: boolean } }, delay: number, duration: number }

local VideoPlayer = {}

function VideoPlayer.load(b64: string): Video
	local data = base64Decode(b64)
	if buffer.readstring(data, 0, 4) == "LVZ1" then -- zlib container: inflate to the raw LVD1 stream
		assert(Inflate, "this video was encoded with ZLIB=1 but no Inflate module is present")
		local rawLen, compLen = buffer.readu32(data, 4), buffer.len(data) - 8
		local comp = buffer.create(compLen)
		buffer.copy(comp, 0, data, 8, compLen)
		local raw, err = Inflate.decompress(comp, rawLen)
		assert(raw, "inflate failed: " .. err.message)
		data = raw :: buffer
	end
	assert(buffer.readstring(data, 0, 4) == "LVD1", "not LVD1 data")
	local w, h = buffer.readu16(data, 4), buffer.readu16(data, 6)
	local frameCount, delay = buffer.readu32(data, 8), buffer.readu16(data, 12)
	local qy, qc = buffer.readu8(data, 14), buffer.readu8(data, 15)
	local frames, off = {}, 16
	for f = 1, frameCount do
		local len, flags = buffer.readu32(data, off), buffer.readu8(data, off + 4)
		frames[f] = { start = off + 5, stop = off + 5 + len, key = flags % 2 == 1, chroma = flags // 2 % 2 == 1, cut = flags // 4 % 2 == 1 }
		off += 5 + len
	end
	-- The header holds the frame delay in whole milliseconds (42 for 24 fps); using it directly runs the
	-- video 0.8% slow and loses lip sync over a song. Recover the integer frame rate and use the exact period.
	local fps = math.round(1000 / delay)
	return { data = data, w = w, h = h, qy = qy, qc = qc, frames = frames, delay = 1 / fps, duration = frameCount / fps }
end

-- Applies one plane's residual tokens. Keyframe: each element is predicted from the previous one
-- (raster order), starting at `mid`. Inter frame: predicted from the plane's current contents.
local function decodePlane(data: buffer, pos: number, plane: buffer, count: number, isKey: boolean, mid: number): number
	local p, pred = 0, mid
	local function apply(r: number)
		if isKey then
			pred += r
			buffer.writeu8(plane, p, pred)
		elseif r ~= 0 then
			buffer.writeu8(plane, p, buffer.readu8(plane, p) + r)
		end
		p += 1
	end
	while p < count do
		local op = buffer.readu8(data, pos)
		pos += 1
		if op < 0x80 then
			local k = op + 1
			if isKey then buffer.fill(plane, p, pred, k) end
			p += k
		elseif op < 0xC0 then
			local k = op - 0x7F
			for j = 0, k - 1 do
				local byte = buffer.readu8(data, pos + j // 2)
				local nib = if j % 2 == 0 then byte % 16 else byte // 16
				apply(if nib > 7 then nib - 16 else nib)
			end
			pos += (k + 1) // 2
		else
			local k = op - 0xBF
			for j = 0, k - 1 do
				local v = buffer.readu8(data, pos + j)
				apply(if v > 127 then v - 256 else v)
			end
			pos += k
		end
	end
	return pos
end

-- Decoder state: the three quantized planes plus lookup tables for the YCbCr -> RGB step.
local function makeDecoder(video: Video)
	local w, h = video.w, video.h
	local cw, ch = w // 2, h // 2
	local Y, Cb, Cr = buffer.create(w * h), buffer.create(cw * ch), buffer.create(cw * ch)
	local lumaMid, chromaMid = (255 // video.qy) // 2, (255 // video.qc) // 2
	local yl, rCr, gCb, gCr, bCb = {}, {}, {}, {}, {}
	for q = 0, 255 do
		yl[q] = math.min(255, q * video.qy + video.qy // 2)
		local c = math.min(255, q * video.qc + video.qc // 2) - 128
		rCr[q], gCb[q], gCr[q], bCb[q] = 1.402 * c, -0.34414 * c, -0.71414 * c, 1.772 * c
	end
	-- Decode-side ordered dither: a 4x4 Bayer pattern of +-half a luma step, flipped on odd
	-- frames so the frame blend averages it out. Hides quantization banding at zero data cost.
	local bayer = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }
	local dither = {}
	for i = 1, 16 do dither[i] = (bayer[i] / 16 - 0.5) * video.qy end
	-- Decodes frame f into the planes, then converts the whole picture into the RGBA buffer.
	return function(f: number, rgba: buffer)
		local fr, isKey = video.frames[f], video.frames[f].key
		local pos = decodePlane(video.data, fr.start, Y, w * h, isKey, lumaMid)
		if fr.chroma then
			pos = decodePlane(video.data, pos, Cb, cw * ch, isKey, chromaMid)
			decodePlane(video.data, pos, Cr, cw * ch, isKey, chromaMid)
		end
		local o, flip = 0, if f % 2 == 0 then 1 else -1
		for y = 0, h - 1 do
			local crow, drow = (y // 2) * cw, (y % 4) * 4
			for x = 0, w - 1 do
				local ci = crow + x // 2
				local cb, cr = buffer.readu8(Cb, ci), buffer.readu8(Cr, ci)
				local l = yl[buffer.readu8(Y, y * w + x)] + flip * dither[drow + x % 4 + 1]
				buffer.writeu8(rgba, o, math.clamp(l + rCr[cr], 0, 255))
				buffer.writeu8(rgba, o + 1, math.clamp(l + gCb[cb] + gCr[cr], 0, 255))
				buffer.writeu8(rgba, o + 2, math.clamp(l + bCb[cb], 0, 255))
				o += 4
			end
		end
	end
end

export type Options = { smooth: boolean?, blend: boolean? }
-- smooth: let the GPU upscale bilinearly instead of showing blocks (free quality, zero data).
-- blend: crossfade between consecutive frames every Heartbeat, so a 6 fps stream doesn't stutter.

-- Creates the image and returns `show(frame, mix)`: decodes forward from the current frame, or
-- seeks back through the nearest keyframe when the target is behind. `mix` (0..1) is how far
-- playback is between `frame` and the next one; it only matters when blending.
local function makeRenderer(video: Video, label: ImageLabel, opts: Options?)
	local image = AssetService:CreateEditableImage({ Size = Vector2.new(video.w, video.h) })
	local decodeFrame = makeDecoder(video)
	local size = video.w * video.h * 4
	local rgba = buffer.create(size)
	for i = 3, size - 1, 4 do buffer.writeu8(rgba, i, 255) end
	local blend = opts and opts.blend
	local prev, out = blend and buffer.create(size) or nil, blend and buffer.create(size) or nil
	if blend then buffer.copy(out :: buffer, 0, rgba) end
	label.ImageContent = Content.fromObject(image)
	label.ResampleMode = (opts and opts.smooth) and Enum.ResamplerMode.Default or Enum.ResamplerMode.Pixelated
	local current, lastMix = 0, -1
	local function write(buf: buffer): boolean
		local ok, err = pcall(image.WritePixelsBuffer, image, Vector2.zero, Vector2.new(video.w, video.h), buf)
		if not ok then warn("VideoPlayer stopped: " .. tostring(err) .. " (Game Settings > Security > Allow Mesh & Image APIs, then save)") end
		return ok
	end
	local function show(target: number, mix: number?): boolean
		if target ~= current then
			local from = current + 1
			if target < current or target - current > 60 then -- seek: restart from the last keyframe at or before target
				from = target
				while from > 1 and not video.frames[from].key do from -= 1 end
			end
			if blend then buffer.copy(prev :: buffer, 0, rgba) end -- previous frame = what we showed last
			for f = from, target do decodeFrame(f, rgba) end
			if blend and (from ~= current + 1 or video.frames[target].cut) then buffer.copy(prev :: buffer, 0, rgba) end -- no crossfade after a seek or across a scene cut
			current, lastMix = target, -1
			if not blend then return write(rgba) end
		end
		if not blend then return true end
		local m = math.floor(math.clamp(mix or 1, 0, 1) * 16) / 16 -- 16 steps: enough for a crossfade, fewer rewrites
		if m == lastMix then return true end
		lastMix = m
		for i = 0, size - 1, 4 do
			for c = 0, 2 do
				local a, b = buffer.readu8(prev :: buffer, i + c), buffer.readu8(rgba, i + c)
				buffer.writeu8(out :: buffer, i + c, a + (b - a) * m)
			end
		end
		return write(out :: buffer)
	end
	return show, function() image:Destroy() end
end

-- Free-running loop at the video's frame rate times `speed`. Returns a stop function.
function VideoPlayer.play(video: Video, label: ImageLabel, speed: number?, opts: Options?): () -> ()
	local show, destroy = makeRenderer(video, label, opts)
	local t, rate = 0, (speed or 1)
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		t = (t + dt * rate) % video.duration
		local pos = t / video.delay
		if not show(math.floor(pos) + 1, pos % 1) then conn:Disconnect() end
	end)
	return function() conn:Disconnect(); destroy() end
end

-- Locks the video to a Sound: video time = real seconds elapsed in the sound (+ offset), so it
-- restarts whenever the sound loops. Falls back to free-running while the sound is not playing.
function VideoPlayer.playSynced(video: Video, label: ImageLabel, sound: Sound, offset: number?, opts: Options?): () -> ()
	local show, destroy = makeRenderer(video, label, opts)
	local t, n = 0, #video.frames
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if sound.IsPlaying and sound.PlaybackSpeed > 0 then
			t = sound.TimePosition / sound.PlaybackSpeed + (offset or 0)
		else
			t += dt
		end
		local pos = t / video.delay
		if not show(math.floor(pos) % n + 1, pos % 1) then conn:Disconnect() end
	end)
	return function() conn:Disconnect(); destroy() end
end

-- Builds a centered ScreenGui with the video on an ImageLabel; returns the label and a destroy function.
-- scale = pixels per video pixel, or "fill" to cover the whole screen (aspect kept, black bars).
function VideoPlayer.makeScreen(video: Video, parent: Instance, scale: (number | "fill")?): (ImageLabel, () -> ())
	local gui = Instance.new("ScreenGui")
	gui.Name = "VideoScreen"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100
	local label = Instance.new("ImageLabel")
	label.Name = "Video"
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BorderSizePixel = 0
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	if scale == "fill" then
		local backdrop = Instance.new("Frame")
		backdrop.Name = "Backdrop"
		backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
		backdrop.BorderSizePixel = 0
		backdrop.Size = UDim2.fromScale(1, 1)
		backdrop.Parent = gui
		label.Size = UDim2.fromScale(1, 1)
		local aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = video.w / video.h
		aspect.AspectType = Enum.AspectType.FitWithinMaxSize
		aspect.Parent = label
	else
		label.Size = UDim2.fromOffset(video.w * ((scale :: number?) or 4), video.h * ((scale :: number?) or 4))
	end
	label.Parent = gui
	gui.Parent = parent
	return label, function() gui:Destroy() end
end

VideoPlayer._makeDecoder = makeDecoder -- exposed for benchmarks

return VideoPlayer
