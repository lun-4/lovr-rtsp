# lovr-rtsp

streaming rtsp to a lovr Image object, courtesy of ffmpeg

## how to build

```
# clone to a different folder
# DO NOT DO THIS ON CURRENT DIRECTORY
# allonet is NOT a submodule.
git clone https://github.com/alloverse/allonet

git clone https://github.com/lun-4/lovr-rtsp
cd lovr-rtsp
./copy_vendored_ffmpeg.sh path/to/allonet/repository/clone

# for x86
zig build
cp ./zig-out/lib/librtsp.so.0.0.1 path/to/your/game/or/lovr/folder/rtsp.so

# for android
# (will not support independent builds of rtsp for android at the moment,
# many paths are hardcoded. if you want to add support, feel free!)
# (you will need to build lovr for android to get luajit. see https://lovr.org/docs/Compiling)
# (you also need android NDK, you can get that via android's commandlinetoools)
path/to/android/commandlinetools/bin/sdkmanager --sdk_root=/path/to/sdkroot 'platforms;android-28' 'build-tools;28.0.3' 'ndk;21.1.6352462'
zig build -Dandroid=true -Dandroid-ndk=/path/to/sdkroot/ndk/21.1.6352462 -Dluajit=/path/to/lovr/build-android/luajit/src/luajit
cp ./zig-out/lib/librtsp.so.0.0.1 /path/to/lovr/build-android/raw/lib/arm64-v8a/rtsp.so
```

## usage

recommended to run this piece of code in a separate lovr thread,
then communicate the `myImage` object and the rtsp url over lovr's Channel.

```lua
local rtsp = require "rtsp"
local stream = rtsp.open("rtsp://localhost:6969/some_stream")

-- blocks indefinitely in a loop of frame fetching
rtsp.frameLoop(stream, myImage:getBlob():getPointer())
```
