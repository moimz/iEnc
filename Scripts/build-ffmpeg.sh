#!/bin/zsh
# iEnc 에 넣을 FFmpeg 공유 라이브러리(LGPL)를 공식 소스로 빌드한다. (iRayer Scripts/build-ffmpeg.sh 방식)
#
# - 미리보기: 앱이 libavformat·libavcodec 을 직접 링크해 프레임을 풀고 AVSampleBufferDisplayLayer 로 그린다.
# - 옛 영상까지 열어야 하므로 디먹서·디코더·파서는 FFmpeg 안의 것을 모두 켠다. 네트워크·장치 입력은 끈다.
# - GPL·nonfree 는 켜지 않는다 (LGPL). 하드웨어 디코딩·인코딩은 VideoToolbox·AudioToolbox.
# - 외부 라이브러리는 macOS 에 들어 있는 zlib·bzip2 만 쓴다 (Homebrew 것은 autodetect 를 꺼서 막는다).
#   iconv(자막 문자셋 변환)는 켜면 libavcodec 링크에 -liconv 가 빠져 실패한다. 미리보기엔 필요 없어 뺐다.
# - 결과: Vendor/ffmpeg/{include,lib,bin} (git 에서 빠짐). lib 의 dylib 은 install name 이 @rpath/… 라 앱 Frameworks 에 넣는다.
# - 변환(인코딩·자르기)은 같은 라이브러리를 쓰는 ffmpeg 실행 파일(bin/ffmpeg)을 앱 Contents/MacOS 에 넣어 따로 실행한다.
#   (앱 코드와 섞이지 않아 나중에 GPL ffmpeg 로 바꿔도 앱은 MIT 유지). rpath = @executable_path/../Frameworks
#
# 사용: Scripts/build-ffmpeg.sh [작업 폴더]   (기본: 임시 폴더, 끝나면 지움)
set -euo pipefail

VERSION=8.0
ROOT=${0:A:h:h}
OUT_DIR="$ROOT/Vendor/ffmpeg"
WORK=${1:-$(mktemp -d)}

mkdir -p "$WORK"
cd "$WORK"
[[ -f ffmpeg-$VERSION.tar.xz ]] || curl -fsSL -o ffmpeg-$VERSION.tar.xz "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
rm -rf ffmpeg-$VERSION
tar xf ffmpeg-$VERSION.tar.xz
cd ffmpeg-$VERSION

rm -rf "$OUT_DIR"
./configure \
  --prefix="$OUT_DIR" \
  --arch=arm64 --target-os=darwin \
  --enable-shared --disable-static \
  --install-name-dir='@rpath' \
  --disable-autodetect \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-zlib --enable-bzlib \
  --disable-network --disable-indevs --disable-outdevs \
  --disable-ffplay --disable-ffprobe --disable-doc --disable-debug \
  --disable-avdevice \
  --extra-cflags=-mmacosx-version-min=26.0 --extra-ldflags="-mmacosx-version-min=26.0 -Wl,-rpath,@executable_path/../Frameworks"

make -j"$(sysctl -n hw.ncpu)"
make install
cp COPYING.LGPLv2.1 "$OUT_DIR/LICENSE"
grep -E '^(FFMPEG_CONFIGURATION|CONFIG_GPL|CONFIG_NONFREE)' ffbuild/config.mak config.h 2>/dev/null > "$OUT_DIR/BUILD.txt" || true
echo "ffmpeg $VERSION" >> "$OUT_DIR/BUILD.txt"
rm -rf "$OUT_DIR/share" "$OUT_DIR/lib/pkgconfig"

cd /
[[ -z ${1:-} ]] && rm -rf "$WORK"
echo "완료: $OUT_DIR"
