#!/bin/sh
#
# copy_vendored_ffmpeg.sh - self-explanatory name
#
# usage: ./copy_vendored_ffmpeg.sh path/to/allonet/cloned/repo

set -eux

allonet_path=$1

ffmpeg_path="${allonet_path}/bindeps/ffmpeg"
binary_ffmpeg_path="${ffmpeg_path}/android-arm64-v8a/lib"

library_checksums="ba2a482d5fd7be9c54820d535c8341a503b722e49e53dfdefc8bea8877e27660 ${binary_ffmpeg_path}/libavcodec.so
6ab80ceb02a1c5fff5ba773ff759e85a7370382867fc24490b649ed4b9766968 ${binary_ffmpeg_path}/libavformat.so
aec3f050025c7cd89701c280827df72443fe744104c2cdb5f5ede9353bb1678e ${binary_ffmpeg_path}/libavutil.so
4630a8631d68a19035bdac0bfe48e48a7e9a1358513ef773179de2e27829e95f ${binary_ffmpeg_path}/libswresample.so
2938c85be965cfa4660a172a84dee1f35d103991423391680b7059d1deb90db0 ${binary_ffmpeg_path}/libswscale.so"

# if the check fails, we crash, simple as that!
echo "${library_checksums}" | sha256sum --strict --check -

cp -vr "${ffmpeg_path}/include"/* ./q2_include/
cp -vr "${binary_ffmpeg_path}"/* ./q2_lib/
