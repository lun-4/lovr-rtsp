#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libswscale/swscale.h>

struct funny_stream_loop_context {
  AVPacket packet;
  AVFormatContext *oc;
  AVStream *stream;
  AVCodec *codec;
  int size;
  uint8_t *picture_buf;
  AVFrame *pic;
  int size2;
  uint8_t *picture_buf2;
  AVFrame *pic_rgb;
};

typedef struct funny_stream_loop_context funny_stream_loop_t;

struct funny_stream {
  struct SwsContext *img_convert_ctx;
  AVFormatContext *context;
  AVCodecContext *ccontext;
  int video_stream_index;

  funny_stream_loop_t loop_ctx;
};

typedef struct funny_stream funny_stream_t;

static int funny_open(lua_State *L) {
  size_t rtsp_url_len;
  const char *rtsp_url = luaL_checklstring(L, 1, &rtsp_url_len);

  funny_stream_t *funny_stream = lua_newuserdata(L, sizeof(funny_stream_t));
  luaL_getmetatable(L, "funny_stream");
  lua_setmetatable(L, -2);
  funny_stream->context = avformat_alloc_context();

  funny_stream->loop_ctx.codec = avcodec_find_decoder(AV_CODEC_ID_H264);
  if (!funny_stream->loop_ctx.codec) {
    lua_pushstring(L, "could not find h264 decoder");
    lua_error(L);
  }

  funny_stream->ccontext = avcodec_alloc_context3(funny_stream->loop_ctx.codec);

  // open rtsp
  if (avformat_open_input(&funny_stream->context, rtsp_url, NULL, NULL) != 0) {
    lua_pushstring(L, "avformat_open_input error");
    lua_error(L);
  }

  if (avformat_find_stream_info(funny_stream->context, NULL) < 0) {
    lua_pushstring(L, "avformat_find_stream_info error");
    lua_error(L);
  }

  // search video stream
  for (int i = 0; i < funny_stream->context->nb_streams; i++) {
    if (funny_stream->context->streams[i]->codec->codec_type ==
        AVMEDIA_TYPE_VIDEO)
      funny_stream->video_stream_index = i;
  }

  av_init_packet(&funny_stream->loop_ctx.packet);
  funny_stream->loop_ctx.oc = avformat_alloc_context();

  av_read_play(funny_stream->context);

  avcodec_get_context_defaults3(funny_stream->ccontext,
                                funny_stream->loop_ctx.codec);
  avcodec_copy_context(
      funny_stream->ccontext,
      funny_stream->context->streams[funny_stream->video_stream_index]->codec);

  if (avcodec_open2(funny_stream->ccontext, funny_stream->loop_ctx.codec,
                    NULL) < 0) {
    lua_pushstring(L, "avcodec_open fail");
    lua_error(L);
  }

  funny_stream->img_convert_ctx = sws_getContext(
      funny_stream->ccontext->width, funny_stream->ccontext->height,
      funny_stream->ccontext->pix_fmt, funny_stream->ccontext->width,
      funny_stream->ccontext->height, AV_PIX_FMT_RGB24, SWS_BICUBIC, NULL, NULL,
      NULL);

  funny_stream->loop_ctx.size =
      avpicture_get_size(AV_PIX_FMT_YUV420P, funny_stream->ccontext->width,
                         funny_stream->ccontext->height);
  funny_stream->loop_ctx.picture_buf =
      (uint8_t *)(av_malloc(funny_stream->loop_ctx.size));
  funny_stream->loop_ctx.pic = av_frame_alloc();
  avpicture_fill((AVPicture *)funny_stream->loop_ctx.pic,
                 funny_stream->loop_ctx.picture_buf, AV_PIX_FMT_YUV420P,
                 funny_stream->ccontext->width, funny_stream->ccontext->height);

  funny_stream->loop_ctx.size2 =
      avpicture_get_size(AV_PIX_FMT_RGB24, funny_stream->ccontext->width,
                         funny_stream->ccontext->height);
  funny_stream->loop_ctx.picture_buf2 =
      (uint8_t *)(av_malloc(funny_stream->loop_ctx.size2));
  funny_stream->loop_ctx.pic_rgb = av_frame_alloc();
  avpicture_fill((AVPicture *)funny_stream->loop_ctx.pic_rgb,
                 funny_stream->loop_ctx.picture_buf2, AV_PIX_FMT_RGB24,
                 funny_stream->ccontext->width, funny_stream->ccontext->height);

  printf("init done!\n");
  return 1;
}

static int funny_clean(lua_State *L) {
  const void *funny_stream = luaL_checkudata(L, 1, "funny_stream");
  // av_free(funny_stream->loop_ctx.pic);
  // av_free(funny_stream->loop_ctx.picture_buf);

  // av_read_pause(context);
  // avio_close(oc->pb);
  // avformat_free_context(oc);
}

static int funny_fetch_frame(lua_State *L) {
  struct timespec begin, end;
  clock_gettime(CLOCK_MONOTONIC, &begin);

  printf("fetch frame!\n");
  if (lua_gettop(L) != 2) {
    return luaL_error(L, "expecting exactly 2 arguments");
  }

  funny_stream_t *funny_stream =
      (funny_stream_t *)luaL_checkudata(L, 1, "funny_stream");
  void *blob_ptr = (void *)lua_touserdata(L, 2);

  luaL_argcheck(L, funny_stream != NULL, 1, "'funny_stream' expected");

  if (av_read_frame(funny_stream->context, &funny_stream->loop_ctx.packet) <
      0) {
    lua_pushstring(L, "av_read_frame return less than 0");
    lua_error(L);
  }

  if (funny_stream->loop_ctx.packet.stream_index ==
      funny_stream->video_stream_index) {

    printf("video!\n");
    if (funny_stream->loop_ctx.stream == NULL) { // create stream in file
      printf("creating stream\n");
      funny_stream->loop_ctx.stream = avformat_new_stream(
          funny_stream->loop_ctx.oc,
          funny_stream->context->streams[funny_stream->video_stream_index]
              ->codec->codec);
      avcodec_copy_context(
          funny_stream->loop_ctx.stream->codec,
          funny_stream->context->streams[funny_stream->video_stream_index]
              ->codec);
      funny_stream->loop_ctx.stream->sample_aspect_ratio =
          funny_stream->context->streams[funny_stream->video_stream_index]
              ->codec->sample_aspect_ratio;
    }
    int check = 0;
    funny_stream->loop_ctx.packet.stream_index =
        funny_stream->loop_ctx.stream->id;
    printf("decoding frame\n");
    int result = avcodec_decode_video2(funny_stream->ccontext,
                                       funny_stream->loop_ctx.pic, &check,
                                       &funny_stream->loop_ctx.packet);
    printf("decoded %d bytes. check %d\n", result, check);

    // frame!!!
    if (check != 0) {

      sws_scale(funny_stream->img_convert_ctx, funny_stream->loop_ctx.pic->data,
                funny_stream->loop_ctx.pic->linesize, 0,
                funny_stream->ccontext->height,
                funny_stream->loop_ctx.pic_rgb->data,
                funny_stream->loop_ctx.pic_rgb->linesize);

      printf("width %d height %d\n", funny_stream->ccontext->width,
             funny_stream->ccontext->height);
      memcpy(blob_ptr, funny_stream->loop_ctx.picture_buf2,
             funny_stream->loop_ctx.size2);
    }
  }

  av_free_packet(&funny_stream->loop_ctx.packet);
  av_init_packet(&funny_stream->loop_ctx.packet);

  clock_gettime(CLOCK_MONOTONIC, &end);

  long seconds = end.tv_sec - begin.tv_sec;
  long nanoseconds = end.tv_nsec - begin.tv_nsec;
  double elapsed = seconds + nanoseconds * 1e-9;

  lua_pushnumber(L, elapsed);
  return 1;
}

static const luaL_Reg syslib[] = {
    {"open", funny_open},
    {"fetchFrame", funny_fetch_frame},
    {NULL, NULL},
};

LUALIB_API int luaopen_funny(lua_State *L) {
  avformat_network_init();
  luaL_newmetatable(L, "funny_stream");
  luaL_register(L, LUA_OSLIBNAME, syslib);
  return 1;
}
