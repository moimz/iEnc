#!/bin/zsh
# 소프트웨어 인코더(x264·x265, GPL)가 든 변환용 ffmpeg 실행 파일을 따로 만든다 → Vendor/ffmpeg-gpl/bin/ffmpeg
#
# - 정적 빌드: libav* 를 실행 파일 안에 넣는다. 앱이 링크하는 미리보기 라이브러리(Vendor/ffmpeg, LGPL)와 섞이지 않게
#   → 앱은 MIT 그대로, 이 실행 파일만 GPL (배포할 때 FFmpeg·x264·x265 소스 공개 의무).
# - x264·x265 는 Homebrew 의 정적 라이브러리(libx264.a·libx265.a)를 쓴다: brew install x264 x265
#   Homebrew 것이 macOS 27 용으로 빌드돼 있어 이 실행 파일도 macOS 27 이상에서만 돈다
#   (앱은 macOS 26 에서도 돌고, 26 에선 하드웨어 인코딩만 — Encoder.swift 가 고른다).
# - pkg-config 가 없어도 되게 x264·x265 만 답하는 작은 대역을 쓴다.
#
# 사용: Scripts/build-ffmpeg-gpl.sh [작업 폴더]   (기본: 임시 폴더, 끝나면 지움)
set -euo pipefail

VERSION=8.0
ROOT=${0:A:h:h}
OUT_DIR="$ROOT/Vendor/ffmpeg-gpl"
WORK=${1:-$(mktemp -d)}
BREW=/opt/homebrew
[[ -f $BREW/lib/libx264.a && -f $BREW/lib/libx265.a ]] || { echo "x264·x265 정적 라이브러리가 없음: brew install x264 x265"; exit 1; }

mkdir -p "$WORK"
cd "$WORK"
[[ -f ffmpeg-$VERSION.tar.xz ]] || curl -fsSL -o ffmpeg-$VERSION.tar.xz "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
rm -rf ffmpeg-$VERSION-gpl
mkdir ffmpeg-$VERSION-gpl
tar xf ffmpeg-$VERSION.tar.xz -C ffmpeg-$VERSION-gpl --strip-components 1
cd ffmpeg-$VERSION-gpl

# pkg-config 대역: x264·x265 를 정적(.a 경로)으로 링크하게 답한다
cat > pkgconf-shim <<SHIM
#!/bin/sh
[ "\$1" = "--version" ] && { echo 0.29; exit 0; }
for a in "\$@"; do case "\$a" in x264*) lib=x264;; x265*) lib=x265;; esac; done
[ -z "\$lib" ] && exit 1
case " \$* " in
  *" --exists "*) exit 0;;
  *" --modversion "*) [ \$lib = x264 ] && echo 0.165 || echo 4.3;;
  *" --cflags "*) echo "-I$BREW/include";;
  *" --libs "*) [ \$lib = x264 ] && echo "$BREW/lib/libx264.a" || echo "$BREW/lib/libx265.a -lc++";;
esac
exit 0
SHIM
chmod +x pkgconf-shim

./configure \
  --prefix="$OUT_DIR" \
  --arch=arm64 --target-os=darwin \
  --enable-static --disable-shared \
  --enable-gpl --enable-libx264 --enable-libx265 \
  --pkg-config="$PWD/pkgconf-shim" \
  --disable-autodetect \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-zlib --enable-bzlib \
  --disable-network --disable-indevs --disable-outdevs --disable-avdevice \
  --disable-ffplay --disable-ffprobe --disable-doc --disable-debug \
  --extra-cflags=-mmacosx-version-min=27.0 --extra-ldflags=-mmacosx-version-min=27.0

make -j"$(sysctl -n hw.ncpu)" ffmpeg
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/bin"
cp ffmpeg "$OUT_DIR/bin/ffmpeg"
strip -x "$OUT_DIR/bin/ffmpeg"
cp COPYING.GPLv2 "$OUT_DIR/LICENSE"
grep -E '^FFMPEG_CONFIGURATION' ffbuild/config.mak > "$OUT_DIR/BUILD.txt" || true
echo "ffmpeg $VERSION + x264 $(brew list --versions x264 | cut -d' ' -f2) + x265 $(brew list --versions x265 | cut -d' ' -f2) (Homebrew 정적 라이브러리)" >> "$OUT_DIR/BUILD.txt"

cd /
[[ -z ${1:-} ]] && rm -rf "$WORK"
echo "완료: $OUT_DIR/bin/ffmpeg"
