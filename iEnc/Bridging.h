// FFmpeg C API 를 Swift 에서 쓰기 위한 브리징 헤더.
// 함수 모양 매크로(AVERROR 등)는 Swift 로 안 넘어오므로 static inline 함수로 감싼다.
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/pixdesc.h>
#include <libavutil/hwcontext.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

static inline int ienc_eagain(void) { return AVERROR(EAGAIN); }
static inline int ienc_eof(void) { return AVERROR_EOF; }
static inline int64_t ienc_nopts(void) { return AV_NOPTS_VALUE; }
static inline int ienc_time_base(void) { return AV_TIME_BASE; }

static inline const char *ienc_err(int code, char *buf, size_t size) {
    av_strerror(code, buf, size);
    return buf;
}

/// get_format 콜백: VideoToolbox 가 목록에 있으면 고르고, 없으면 첫 소프트웨어 형식.
/// (VideoToolbox 초기화가 실패하면 FFmpeg 가 그 형식을 빼고 다시 부른다 → 자동으로 소프트웨어)
static inline enum AVPixelFormat ienc_get_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    }
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*p);
        if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
    }
    return fmts[0];
}

static inline void ienc_use_hw(AVCodecContext *ctx) { ctx->get_format = ienc_get_format; }
