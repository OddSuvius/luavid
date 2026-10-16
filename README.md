# Luavid

Luavid is a video codec whose decoder is pure Lua (Luau dialect). The encoder runs offline in Python and
turns any video into a stream of Lua modules; the decoder runs inside a game engine's script VM
and writes RGBA pixels into an editable image every frame. No native code, no GPU, no streaming:
everything happens in the interpreter.

It exists to answer one question: how much video can a scripting VM play on its own? The answer
is more than expected, as long as you spend bytes instead of cycles.

## Platform limits

Read these first. They are properties of running inside a script VM, and they decide everything
below.

- **No GPU, no hardware decoder, no video texture.** The only way to put moving pixels on screen
  from script is to write an RGBA buffer into an editable image each tick. That image is capped
  at 1024x1024.
- **The decoder shares the frame budget.** Everything has to fit inside a 16 ms tick alongside
  the game. There is no worker thread to decode on.
- **Data has to live in script source.** There is no binary asset a script can read bytes from.
  The stream is stored as base64 text in modules, which costs a third extra, and modules are
  chunked to 100k characters. Load time is base64 decoding, about 1 s per 15 MB.
- **No streaming.** The whole video is loaded before the first frame; nothing arrives
  progressively.
- **Permissions.** Writing pixels to an editable image at runtime is gated behind an
  experience-level setting and account verification for published games.

## Findings

### 1. It works, at 60 Hz

A 160x120, 24 fps, 3.5 minute video decodes in Lua into an editable image at a steady 60 Hz,
with 0.7 ms of decoding per frame and a worst tick gap of 19 ms. The usual assumption is that
this needs a native decoder. It doesn't; it needs the right codec.

### 2. Native code generation is the enabler

The same decoder runs at 2.3 ms per frame interpreted and 0.7 ms with the VM's native code
generation enabled (`--!native` at the top of the module). That 3.4x is the difference between
a quarter of the pixels and the budget to spend on a heavier decoder, such as an inflater. It is
not an optimisation to add later; the design assumes it.

### 3. Bytes, not cycles, are the real wall

With native code generation on, CPU has roughly 20x headroom at 160x120. Data does not. A codec
simple enough to decode in an interpreter lands at about 0.4 bytes per sample on camera footage,
so size scales linearly with pixels times frames:

| | size for a 3:33 clip |
|---|---|
| 160x120 at 12 fps | 24 MB |
| 160x120 at 24 fps | 46 MB |
| 320x240 at 30 fps | about 230 MB |

Real codecs are 20x to 50x smaller because of motion compensation and transform coding, and
neither decodes fast enough here. Spend resolution and frame rate against the size you can
accept, not against CPU.

### 4. A codec shaped for the interpreter

What survived the measurements:

- YCbCr with luma at full resolution and colour at half, and colour sent only every other frame.
  Colour detail and colour motion are nearly invisible; the data is not.
- Uniform quantization with small steps. Fidelity is exact to the grid: every decoded sample is
  within half a step of the source, luma PSNR 78 dB against the quantized source, and nothing is
  approximated over time.
- Keyframes predict each sample from the previous one in raster order; other frames predict from
  the previous frame. Residuals are tokenised as zero runs, 4-bit values packed two per byte, and
  full bytes. That is the whole entropy stage, and it decodes in one pass straight into the
  planes.
- Per frame the decoder applies the tokens, then converts to RGBA through lookup tables. No
  function call per pixel, only buffer reads and writes.

Two mistakes worth warning about, both of which looked like "bad colour":

- Rounding to the nearest quantization step and then adding half a step back on decode shifts
  every channel up by half a step, which tints the whole picture. Quantize with floor.
- Letting the encoder skip small residuals inside keyframes paints horizontal streaks, because
  the reconstruction lags the source along each row by a different amount. Tolerance belongs on
  the temporal path only, and the shipped profiles use none at all.

### 5. Scene cuts need their own detection

A cut coded as a delta is a huge residual drawn over the wrong colour, and with colour sent on
alternate frames the new scene can appear in the old scene's colours for a frame. Mean pixel
change can't tell a cut from fast motion. The L1 distance between consecutive 32-bin luma
histograms can: cuts score above 0.7, fast motion stays under 0.35. Frames over 0.5 become
keyframes carrying colour, with a flag that tells the player not to crossfade into them.

### 6. Three quality tricks that cost no data

- Let the renderer upscale bilinearly instead of showing blocks.
- Crossfade between consecutive decoded frames every tick, so 12 fps reads as motion rather than
  a slideshow. Skip it across cuts.
- Add a 4x4 Bayer dither of half a luma step at decode time and flip its sign every frame; the
  crossfade averages it out and banding disappears.

### 7. Frame timing must be exact

The stream header stores the frame delay in whole milliseconds. Using 42 ms for 24 fps runs the
video 0.8 percent slow, which is 1.7 s over a 3.5 minute clip and visible against anything else
running on a real clock after a minute. Recover the integer frame rate and use the exact period.
Measured against an external clock, the shipped player stays within one frame for the whole
clip.

## Results

Measured on a 3:33 clip of 4:3 camera footage, decoded on a laptop CPU.

| | 12 fps profile | 24 fps profile |
|---|---|---|
| resolution | 160x120 | 160x120 |
| luma / chroma step | 5 / 6 | 4 / 4 |
| stream size | 18 MB | 35 MB |
| as text modules (base64) | 24 MB | 46 MB |
| decode per frame | 0.7 ms | 0.7 ms |
| load time | 1.5 s | 3.8 s |
| playback | 60 Hz | 60 Hz, worst gap 19 ms |
| client memory | ~30 MB | ~30 MB |

## How it works

Encoder, `tools/luavid-encode.py`: decode with ffmpeg, auto-crop black bars, resample to the target
size and frame rate, light temporal denoise (noise is the most expensive thing to encode),
YCbCr, quantize, predict, tokenise, emit base64 in 100k-character modules plus an index module
that concatenates them.

Decoder, `src/VideoPlayer.luau`: base64 to a byte buffer, scan the frame table once, keep three
plane buffers, decode a frame into them and convert to RGBA. Seeking walks back to the nearest
keyframe and decodes forward.

`src/VideoScreen.client.luau` is the reference integration: a fullscreen image with a status
line. The player can free-run at the video's frame rate or follow any external clock you hand
it, and seeks through keyframes when that clock jumps.

## Usage

```
# encode: input, output folder, width, height, fps, tolerance, keyframe seconds, max seconds, luma step, chroma step
uv run --with numpy --with pillow python tools/luavid-encode.py input.mp4 VideoData 160 120 24 0 3 1e9 4 4
```

Sync `VideoData`, `src/VideoPlayer.luau` and the client script into your project (a Rojo project
file is included) and press Play.

## Compression beyond the codec

Generic compression on top of the token stream gains about 1.6x with zlib and 1.7x with lzma;
the stream is already run-length coded, so a dictionary coder only finds the remaining entropy.
The encoder can wrap the stream in a zlib container (`ZLIB=1`) if you pair it with a DEFLATE
decoder in Lua on the player side. A fast one exists in the Picguin image library and inflates
35 MB in about 2 s with native code generation. It is not included here.

## Ideas not taken

- Vector quantization in the style of 1990s game codecs: codebooks of 2x2 blocks, decoding is a
  table copy. Likely 3x to 5x smaller than this codec and faster to decode, at the cost of a much
  heavier encoder.
- Motion compensation with cheap block copies: 2x to 3x on camera footage; the search cost lives
  in the encoder, which can take as long as it likes.
- Static Huffman tables on the nibble stream: about 1.4x, needs native code generation to stay
  within budget.

## License

MIT with an attribution requirement: you can use, modify and redistribute Luavid freely, but
anything built with it or derived from it must visibly credit Suvius as the author and, where
practical, link back to this repository. See LICENSE.
