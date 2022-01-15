const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("time.h");

    @cInclude("lauxlib.h");
    @cInclude("lua.h");
    @cInclude("lualib.h");

    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavformat/avio.h");
    @cInclude("libswscale/swscale.h");
});

pub const funny_stream_loop_t = extern struct {
    packet: c.AVPacket,
    oc: *c.AVFormatContext,
    stream: ?*c.AVStream = null,
    codec: *c.AVCodec,
    size: c_int,
    picture_buf: [*c]u8,
    pic: *c.AVFrame,
    size2: c_int,
    picture_buf2: [*c]u8,
    pic_rgb: *c.AVFrame,
};

pub const funny_stream_t = extern struct {
    img_convert_ctx: *c.SwsContext,
    context: *c.AVFormatContext,
    ccontext: *c.AVCodecContext,
    video_stream_index: usize,
    loop_ctx: funny_stream_loop_t,
};

// global funny_open mutex
var open_mutex = std.Thread.Mutex{};
const logger = std.log.scoped(.lovr_rtsp);

fn possible_av_error(L: *c.lua_State, ret: c_int) !void {
    if (ret < 0) {
        c.lua_pushstring(L, "libav issue");
        _ = c.lua_error(L);
        return error.AvError;
    }
}

export fn funny_open(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;

    var rtsp_url_len: usize = undefined;
    var rtsp_url = c.luaL_checklstring(L, @as(c_int, 1), &rtsp_url_len);
    return funny_open_wrapped(L, rtsp_url[0..rtsp_url_len :0]) catch |err| {
        logger.err("error happened shit {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        c.lua_pushstring(L, "error in native rtsp library");
        _ = c.lua_error(L);
        return 1;
    };
}

fn funny_open_wrapped(L: *c.lua_State, rtsp_url: [:0]const u8) !c_int {
    open_mutex.lock();
    defer open_mutex.unlock();

    var context_cptr = c.avformat_alloc_context().?;
    var context = @ptrCast(*c.AVFormatContext, context_cptr);

    const codec = c.avcodec_find_decoder(@bitCast(c_uint, c.AV_CODEC_ID_H264)) orelse {
        c.lua_pushstring(L, "could not find h264 decoder");
        return c.lua_error(L);
    };

    var codec_context_cptr = c.avcodec_alloc_context3(codec).?;
    var codec_context = @ptrCast(*c.AVCodecContext, codec_context_cptr);

    if (c.avformat_open_input(&context_cptr, rtsp_url.ptr, null, null) != @as(c_int, 0)) {
        c.lua_pushstring(L, "c.avformat_open_input error");
        _ = c.lua_error(L);
        return error.AvError;
    }

    // set it again just in case avformat_open_input changed the pointer value!!!
    context = @ptrCast(*c.AVFormatContext, context_cptr);

    if (c.avformat_find_stream_info(context, null) < 0) {
        c.lua_pushstring(L, "c.avformat_find_stream_info error");
        _ = c.lua_error(L);
        return error.AvError;
    }

    var maybe_video_stream_index: ?usize = null;
    {
        var i: usize = 0;
        while (i < context.nb_streams) : (i += 1) {
            if (context.streams[i].*.codec.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
                maybe_video_stream_index = i;
            }
        }
    }
    var video_stream_index: usize = maybe_video_stream_index.?;

    var packet: c.AVPacket = undefined;
    c.av_init_packet(&packet);
    var inner_loop_context = c.avformat_alloc_context();
    try possible_av_error(L, c.av_read_play(context));
    try possible_av_error(L, c.avcodec_get_context_defaults3(codec_context_cptr, codec));
    codec_context = @ptrCast(*c.AVCodecContext, codec_context_cptr);

    const stream_codec_context = context.streams[@intCast(usize, video_stream_index)].*.codec.?;
    //const actual_stream_codec = stream_codec_context.*.codec.?;
    try possible_av_error(L, c.avcodec_copy_context(codec_context_cptr, stream_codec_context));
    codec_context = @ptrCast(*c.AVCodecContext, codec_context_cptr);

    try possible_av_error(L, c.avcodec_open2(
        codec_context,
        codec,
        null,
    ));
    var img_convert_ctx = c.sws_getContext(
        codec_context.width,
        codec_context.height,
        codec_context.pix_fmt,
        codec_context.width,
        codec_context.height,
        c.AV_PIX_FMT_RGB24,
        @as(c_int, 4),
        null,
        null,
        null,
    ) orelse {
        c.lua_pushstring(L, "failed to load sws context");
        return c.lua_error(L);
    };

    // pic1 contains incoming yuv data, pic2 contains rgb24 data

    const pic1_size = c.avpicture_get_size(
        c.AV_PIX_FMT_YUV420P,
        codec_context.width,
        codec_context.height,
    );
    const pic1_buf = @ptrCast(
        [*c]u8,
        @alignCast(std.meta.alignment(u8), c.av_malloc(@bitCast(usize, @as(c_long, pic1_size)))),
    );
    const pic1 = c.av_frame_alloc();
    try possible_av_error(L, c.avpicture_fill(
        @ptrCast(*c.AVPicture, pic1),
        pic1_buf,
        c.AV_PIX_FMT_YUV420P,

        codec_context.width,
        codec_context.height,
    ));

    const pic2_size = c.avpicture_get_size(
        c.AV_PIX_FMT_RGB24,
        codec_context.width,
        codec_context.height,
    );
    const pic2_buf = @ptrCast(
        [*c]u8,
        @alignCast(std.meta.alignment(u8), c.av_malloc(@bitCast(usize, @as(c_long, pic2_size)))),
    );
    const pic2 = c.av_frame_alloc();
    try possible_av_error(L, c.avpicture_fill(
        @ptrCast(*c.AVPicture, pic2),
        pic2_buf,
        c.AV_PIX_FMT_RGB24,
        codec_context.width,
        codec_context.height,
    ));

    var funny_stream_1: *funny_stream_t = @ptrCast(
        *funny_stream_t,
        @alignCast(std.meta.alignment(funny_stream_t), c.lua_newuserdata(L, @sizeOf(funny_stream_t)).?),
    );
    _ = c.lua_getfield(L, -@as(c_int, 10000), "funny_stream");
    _ = c.lua_setmetatable(L, -@as(c_int, 2));

    funny_stream_1.* = funny_stream_t{
        .img_convert_ctx = img_convert_ctx,
        .context = context,
        .ccontext = codec_context,
        .video_stream_index = video_stream_index,
        .loop_ctx = funny_stream_loop_t{
            .packet = packet,
            .oc = inner_loop_context,
            .codec = codec,
            .size = pic1_size,
            .picture_buf = pic1_buf,
            .pic = pic1,

            .size2 = pic2_size,
            .picture_buf2 = pic2_buf,
            .pic_rgb = pic2,
        },
    };

    _ = c.printf("init done!\n");
    return 1;
}

export fn funny_fetch_frame(arg_L: ?*c.lua_State) callconv(.C) c_int {
    open_mutex.lock();
    defer open_mutex.unlock();

    var L = arg_L;
    var begin: c.timespec = undefined;
    var end: c.timespec = undefined;
    _ = c.clock_gettime(@as(c_int, 1), &begin);
    _ = c.printf("fetch frame!\n");
    if (c.lua_gettop(L) != @as(c_int, 2)) {
        return c.luaL_error(L, "expecting exactly 2 arguments");
    }

    const funny_stream_voidptr = c.luaL_checkudata(L, @as(c_int, 1), "funny_stream");
    var funny_stream_1: *funny_stream_t = @ptrCast(
        *funny_stream_t,
        @alignCast(std.meta.alignment(funny_stream_t), funny_stream_voidptr.?),
    );

    var blob_ptr: ?*anyopaque = c.lua_touserdata(L, @as(c_int, 2));
    _ = (funny_stream_1 != @ptrCast([*c]funny_stream_t, @alignCast(@import("std").meta.alignment(funny_stream_t), @intToPtr(?*anyopaque, @as(c_int, 0))))) or (c.luaL_argerror(L, @as(c_int, 1), "'funny_stream' expected") != 0);
    if (c.av_read_frame(funny_stream_1.*.context, &funny_stream_1.*.loop_ctx.packet) < @as(c_int, 0)) {
        c.lua_pushstring(L, "c.av_read_frame return less than 0");
        _ = c.lua_error(L);
    }
    if (funny_stream_1.*.loop_ctx.packet.stream_index == funny_stream_1.*.video_stream_index) {
        _ = c.printf("video!\n");
        if (funny_stream_1.*.loop_ctx.stream == null) {
            std.log.info("creating stream", .{});

            const codec_context = funny_stream_1.context.streams[@intCast(usize, funny_stream_1.video_stream_index)].*.codec.?;
            const actual_codec = codec_context.*.codec;
            funny_stream_1.*.loop_ctx.stream = c.avformat_new_stream(funny_stream_1.*.loop_ctx.oc, actual_codec);

            if (c.avcodec_copy_context(funny_stream_1.*.loop_ctx.stream.?.codec, codec_context) < 0) {
                c.lua_pushstring(L, "failed to initialize av stream");
                _ = c.lua_error(L);
            }

            funny_stream_1.*.loop_ctx.stream.?.sample_aspect_ratio =
                codec_context.?.*.sample_aspect_ratio;
        }
        var check: c_int = 0;
        funny_stream_1.*.loop_ctx.packet.stream_index = funny_stream_1.*.loop_ctx.stream.?.id;
        _ = c.printf("decoding frame\n");
        var result: c_int = c.avcodec_decode_video2(funny_stream_1.*.ccontext, funny_stream_1.*.loop_ctx.pic, &check, &funny_stream_1.*.loop_ctx.packet);
        _ = c.printf("decoded %d bytes. check %d\n", result, check);
        if (check != @as(c_int, 0)) {
            _ = c.sws_scale(
                funny_stream_1.*.img_convert_ctx,
                @ptrCast([*c][*c]u8, @alignCast(std.meta.alignment([*c][*c]u8), &funny_stream_1.*.loop_ctx.pic.*.data)),
                @ptrCast([*c]c_int, @alignCast(std.meta.alignment(c_int), &funny_stream_1.*.loop_ctx.pic.*.linesize)),
                @as(c_int, 0),
                funny_stream_1.*.ccontext.*.height,
                @ptrCast([*c][*c]u8, @alignCast(std.meta.alignment([*c][*c]u8), &funny_stream_1.*.loop_ctx.pic_rgb.*.data)),
                @ptrCast([*c]c_int, @alignCast(std.meta.alignment(c_int), &funny_stream_1.*.loop_ctx.pic_rgb.*.linesize)),
            );
            _ = c.printf("width %d height %d\n", funny_stream_1.*.ccontext.*.width, funny_stream_1.*.ccontext.*.height);
            _ = c.memcpy(blob_ptr, @ptrCast(?*const anyopaque, funny_stream_1.*.loop_ctx.picture_buf2), @bitCast(c_ulong, @as(c_long, funny_stream_1.*.loop_ctx.size2)));
        }
    }
    c.av_free_packet(&funny_stream_1.*.loop_ctx.packet);
    c.av_init_packet(&funny_stream_1.*.loop_ctx.packet);
    _ = c.clock_gettime(@as(c_int, 1), &end);
    var seconds: c_long = end.tv_sec - begin.tv_sec;
    var nanoseconds: c_long = end.tv_nsec - begin.tv_nsec;
    var elapsed: f64 = @intToFloat(f64, seconds) + (@intToFloat(f64, nanoseconds) * 0.000000001);
    c.lua_pushnumber(L, elapsed);
    return 1;
}

const funny_lib = [_]c.luaL_Reg{
    c.luaL_Reg{ .name = "open", .func = funny_open },
    c.luaL_Reg{ .name = "fetchFrame", .func = funny_fetch_frame },
    c.luaL_Reg{ .name = null, .func = null },
};

export fn luaopen_funny(L: ?*c.lua_State) c_int {
    open_mutex.lock();
    defer open_mutex.unlock();

    _ = c.avformat_network_init();
    _ = c.luaL_newmetatable(L, "funny_stream");
    c.luaL_register(L, "funny", &funny_lib);

    return 1;
}
