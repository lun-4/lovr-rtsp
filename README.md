# lovr-rtsp

streaming rtsp to a lovr Image object, courtesy of ffmpeg

## how to build

- https://ziglang.org

```sh
git clone https://github.com/lun-4/lovr-rtsp
cd lovr-rtsp

# for linux x86 (uses system's ffmpeg libs, so have it installed):
zig build
cp ./zig-out/lib/librtsp.so.0.0.1 path/to/your/game/or/lovr/folder/rtsp.so

# for android (WILL BREAK ON ANY SYSTEM OTHER THAN MINE. CURSED BUILD PROCESS AHEAD):
#
# will not provide support to android builds of lovr-rtsp at the moment.
# too much bandwidth and curse in this exists at the moment, with lots of
# hardcoded paths. maybe in the future, but not now.

# get allonet repo
# clone to a different folder
# DO NOT DO THIS ON CURRENT DIRECTORY
# allonet is NOT (and will never be) a submodule.
git clone https://github.com/alloverse/allonet path/to/allonet/repository/clone
./copy_vendored_ffmpeg.sh path/to/allonet/repository/clone

# you need android NDK, you can get that via android's commandlinetoools, as shown here
path/to/android/commandlinetools/bin/sdkmanager --sdk_root=/path/to/sdkroot 'platforms;android-28' 'build-tools;28.0.3' 'ndk;21.1.6352462'

# you need to build lovr for android to get luajit. see https://lovr.org/docs/Compiling
zig build -Dandroid=true -Dandroid-ndk=/path/to/sdkroot/ndk/21.1.6352462 -Dluajit=/path/to/lovr/build-android/luajit/src/luajit

# you might have to do this if you're me
cp ./zig-out/lib/librtsp.so.0.0.1 /path/to/lovr/build-android/raw/lib/arm64-v8a/rtsp.so
```

## usage

recommended to run this piece of code in a separate lovr thread,
then communicate the `myImage` object and the rtsp url over lovr's Channel.

```lua
local rtsp = require "rtsp"
local stream = rtsp.open("rtsp://localhost:6969/some_stream")

-- blocks indefinitely in a loop of frame fetching to that myImage
-- assumes myImage is rgb24.
-- this is done because its a very hot path and i would rather have this
-- big hot path be implemented natively instead of having to go through the
-- lua<->native boundary (even though it might be pretty fast thanks to luajit)
rtsp.frameLoop(stream, myImage:getBlob():getPointer())
```
