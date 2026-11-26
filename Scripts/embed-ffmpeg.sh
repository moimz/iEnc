#!/bin/sh
# Vendor/ffmpeg/lib 의 FFmpeg 공유 라이브러리를 앱 Frameworks 에 넣고 서명한다 (빌드 단계).
# 라이브러리끼리·앱이 @rpath/libavcodec.62.dylib 처럼 주 번호 이름으로 찾으므로 그 이름으로 복사한다 (심볼릭 링크는 따라가 실제 파일을).
set -e
L="$SRCROOT/Vendor/ffmpeg/lib"
[ -d "$L" ] || { echo "error: $L 가 없음 — Scripts/build-ffmpeg.sh 를 먼저 돌린다"; exit 1; }
ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
F="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$F"
for d in "$L"/lib*.dylib; do
	n=$(basename "$d")
	echo "$n" | grep -Eq '^lib[a-z]+\.[0-9]+\.dylib$' || continue
	cp -fL "$d" "$F/$n"
	codesign --force --sign "$ID" --options runtime --timestamp=none "$F/$n"
done
echo "FFmpeg 라이브러리 넣음: $(ls "$F" | tr '\n' ' ')"
