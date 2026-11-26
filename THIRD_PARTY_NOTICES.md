# 함께 쓰는 오픈소스

iEnc 코드는 MIT 라이선스입니다 ([LICENSE](LICENSE)). 앱에는 아래 오픈소스가 들어 있습니다. 앱 안의 정보 창(iEnc › iEnc에 관하여)에도 같은 내용이 있습니다 (`iEnc/AboutView.swift`, 하나를 고치면 같이 고친다).

| 이름 | 라이선스 | 쓰는 곳 | 소스 |
|---|---|---|---|
| FFmpeg 8.0 (libavformat·libavcodec·libavutil·libswscale·libswresample 등 + `ffmpeg` 실행 파일) | LGPL 2.1 이상 | 영상 열기·미리보기·파형, 하드웨어(VideoToolbox) 변환 | https://ffmpeg.org — 빌드: `Scripts/build-ffmpeg.sh` |
| `ffmpeg-gpl` (FFmpeg + x264 + x265, 정적) | GPL 2.0 이상 | CPU 변환 (H.264·HEVC) | https://ffmpeg.org · https://www.videolan.org/developers/x264.html · https://bitbucket.org/multicoreware/x265_git — 빌드: `Scripts/build-ffmpeg-gpl.sh` |
| 나눔글꼴 (나눔고딕·나눔바른고딕·나눔명조·나눔바른펜) | SIL OFL 1.1 | 자막 글꼴 | https://hangeul.naver.com — `iEnc/Fonts/Nanum-OFL.txt` |
| 마루부리 | SIL OFL 1.1 | 자막 글꼴 | https://hangeul.naver.com — `iEnc/Fonts/MaruBuri-OFL.txt` |

- FFmpeg 라이브러리는 앱 안 `Contents/Frameworks` 에 동적 라이브러리로, `ffmpeg` 은 `Contents/MacOS/ffmpeg` 실행 파일로 따로 들어 있어 바꿔 넣을 수 있습니다 (GPL·nonfree 구성 요소 없이 빌드).
- `ffmpeg-gpl` 은 앱 코드와 링크하지 않고 따로 실행하는 별개 프로그램(`Contents/MacOS/ffmpeg-gpl`)입니다. 이 실행 파일은 GPL 을 따릅니다.
- 라이선스 전문: `iEnc/Licenses/LGPL-2.1.txt`, `iEnc/Licenses/GPL-2.0.txt`, 글꼴은 위 OFL 파일.
