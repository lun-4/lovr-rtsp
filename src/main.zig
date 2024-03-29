const std = @import("std");
const main2 = @import("main_v2.zig");

pub const c = @cImport({
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
    @cInclude("libavfilter/avfilter.h");
    @cInclude("libavfilter/buffersrc.h");
    @cInclude("libavfilter/buffersink.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/imgutils.h");
});
const av_error_codes = [_]c_int{
    c.AVERROR_BSF_NOT_FOUND,
    c.AVERROR_BUG,
    c.AVERROR_BUFFER_TOO_SMALL,
    c.AVERROR_DECODER_NOT_FOUND,
    c.AVERROR_DEMUXER_NOT_FOUND,
    c.AVERROR_ENCODER_NOT_FOUND,
    c.AVERROR_EOF,
    c.AVERROR_EXIT,
    c.AVERROR_EXTERNAL,
    c.AVERROR_FILTER_NOT_FOUND,
    c.AVERROR_INVALIDDATA,
    c.AVERROR_MUXER_NOT_FOUND,
    c.AVERROR_OPTION_NOT_FOUND,
    c.AVERROR_PATCHWELCOME,
    c.AVERROR_PROTOCOL_NOT_FOUND,
    c.AVERROR_STREAM_NOT_FOUND,
    c.AVERROR_BUG2,
    c.AVERROR_UNKNOWN,
    c.AVERROR_EXPERIMENTAL,
    c.AVERROR_INPUT_CHANGED,
    c.AVERROR_OUTPUT_CHANGED,
    c.AVERROR_HTTP_BAD_REQUEST,
    c.AVERROR_HTTP_UNAUTHORIZED,
    c.AVERROR_HTTP_FORBIDDEN,
    c.AVERROR_HTTP_NOT_FOUND,
    c.AVERROR_HTTP_OTHER_4XX,
    c.AVERROR_HTTP_SERVER_ERROR,
};

const av_errors = [_][]const u8{
    "AVERROR_BSF_NOT_FOUND",
    "AVERROR_BUG",
    "AVERROR_BUFFER_TOO_SMALL",
    "AVERROR_DECODER_NOT_FOUND",
    "AVERROR_DEMUXER_NOT_FOUND",
    "AVERROR_ENCODER_NOT_FOUND",
    "AVERROR_EOF",
    "AVERROR_EXIT",
    "AVERROR_EXTERNAL",
    "AVERROR_FILTER_NOT_FOUND",
    "AVERROR_INVALIDDATA",
    "AVERROR_MUXER_NOT_FOUND",
    "AVERROR_OPTION_NOT_FOUND",
    "AVERROR_PATCHWELCOME",
    "AVERROR_PROTOCOL_NOT_FOUND",
    "AVERROR_STREAM_NOT_FOUND",
    "AVERROR_BUG2",
    "AVERROR_UNKNOWN",
    "AVERROR_EXPERIMENTAL",
    "AVERROR_INPUT_CHANGED",
    "AVERROR_OUTPUT_CHANGED",
    "AVERROR_HTTP_BAD_REQUEST",
    "AVERROR_HTTP_UNAUTHORIZED",
    "AVERROR_HTTP_FORBIDDEN",
    "AVERROR_HTTP_NOT_FOUND",
    "AVERROR_HTTP_OTHER_4XX",
    "AVERROR_HTTP_SERVER_ERROR",
};

fn libav_strerror(error_code: c_int) ?[]const u8 {
    var idx: usize = 0;
    while (idx < av_error_codes.len) : (idx += 1) {
        if (av_error_codes[idx] == error_code) return av_errors[idx];
    }

    return null;
}

pub const funny_stream_loop_t = extern struct {
    packet: c.AVPacket,
    oc: *c.AVFormatContext,
    stream: ?*c.AVStream = null,
    codec: *c.AVCodec,
    size: c_int,
    picture_buf: [*]u8,
    pic: *c.AVFrame,
    size2: c_int,
    picture_buf2: [*]u8,
    pic_rgb: *c.AVFrame,
};

pub const funny_stream_t = extern struct {
    img_convert_ctx: *c.SwsContext,
    context: *c.AVFormatContext,
    ccontext: *c.AVCodecContext,
    video_stream_index: usize,
    loop_ctx: funny_stream_loop_t,
    stop: bool = false,
};

// global funny_open mutex
var open_mutex = std.Thread.Mutex{};
const logger = std.log.scoped(.lovr_rtsp);

fn possible_av_error(L: *c.lua_State, ret: c_int) !void {
    if (ret < 0) {
        //const maybe_av_error_name = libav_strerror(ret);
        const maybe_av_error_name = null;
        std.log.err("av error: {d}", .{ret});
        if (maybe_av_error_name) |error_name| {
            std.log.err("av error str: {s}", .{error_name});
        }
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
    var context = @as(*c.AVFormatContext, @ptrCast(context_cptr));

    const codec = c.avcodec_find_decoder(@as(c_uint, @bitCast(c.AV_CODEC_ID_H264))) orelse {
        c.lua_pushstring(L, "could not find h264 decoder");
        return c.lua_error(L);
    };

    var codec_context_cptr = c.avcodec_alloc_context3(codec).?;
    var codec_context = @as(*c.AVCodecContext, @ptrCast(codec_context_cptr));

    var opts: ?*c.AVDictionary = null;
    try possible_av_error(L, c.av_dict_set(&opts, "reorder_queue_size", "100000", 0));

    if (c.avformat_open_input(&context_cptr, rtsp_url.ptr, null, &opts) != @as(c_int, 0)) {
        c.lua_pushstring(L, "c.avformat_open_input error");
        _ = c.lua_error(L);
        return error.AvError;
    }

    // set it again just in case avformat_open_input changed the pointer value!!!
    context = @as(*c.AVFormatContext, @ptrCast(context_cptr));

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
    codec_context = @as(*c.AVCodecContext, @ptrCast(codec_context_cptr));

    const stream_codec_context = context.streams[@as(usize, @intCast(video_stream_index))].*.codec.?;
    //const actual_stream_codec = stream_codec_context.*.codec.?;
    try possible_av_error(L, c.avcodec_copy_context(codec_context_cptr, stream_codec_context));
    codec_context = @as(*c.AVCodecContext, @ptrCast(codec_context_cptr));

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
        c.AV_PIX_FMT_RGBA,
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
    const pic1_buf: [*c]align(std.meta.alignment(u8)) u8 =
        @ptrCast(
        @alignCast(
            c.av_malloc(
                @as(
                    usize,
                    @bitCast(
                        @as(c_long, pic1_size),
                    ),
                ),
            ),
        ),
    );
    const pic1 = c.av_frame_alloc();
    try possible_av_error(L, c.avpicture_fill(
        @as(*c.AVPicture, @ptrCast(pic1)),
        pic1_buf,
        c.AV_PIX_FMT_YUV420P,

        codec_context.width,
        codec_context.height,
    ));

    const pic2_size = c.avpicture_get_size(
        c.AV_PIX_FMT_RGBA,
        codec_context.width,
        codec_context.height,
    );
    const pic2_buf = @as(
        [*c]align(std.meta.alignment(u8)) u8,
        @ptrCast(@alignCast(c.av_malloc(@as(usize, @bitCast(@as(c_long, pic2_size)))))),
    );
    const pic2 = c.av_frame_alloc();
    try possible_av_error(L, c.avpicture_fill(
        @as(*c.AVPicture, @ptrCast(pic2)),
        pic2_buf,
        c.AV_PIX_FMT_RGBA,
        codec_context.width,
        codec_context.height,
    ));

    var funny_stream_1: *funny_stream_t = @as(
        *align(std.meta.alignment(funny_stream_t)) funny_stream_t,
        @ptrCast(@alignCast(c.lua_newuserdata(L, @sizeOf(funny_stream_t)).?)),
    );
    c.lua_getfield(L, -@as(c_int, 10000), "funny_stream");
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

fn rtsp_fetch_frame(L: *c.lua_State, funny_stream_1: *funny_stream_t, blob: []u8) !f64 {
    var timer = try std.time.Timer.start();

    if (c.av_read_frame(funny_stream_1.*.context, &funny_stream_1.*.loop_ctx.packet) < @as(c_int, 0)) {
        c.lua_pushstring(L, "c.av_read_frame return less than 0");
        _ = c.lua_error(L);
    }
    if (funny_stream_1.*.loop_ctx.packet.stream_index == funny_stream_1.*.video_stream_index) {
        if (funny_stream_1.*.loop_ctx.stream == null) {
            std.log.info("creating stream", .{});

            const codec_context = funny_stream_1.context.streams[funny_stream_1.video_stream_index].*.codec.?;
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
        _ = c.avcodec_decode_video2(funny_stream_1.*.ccontext, funny_stream_1.*.loop_ctx.pic, &check, &funny_stream_1.*.loop_ctx.packet);
        if (check != @as(c_int, 0)) {
            _ = c.sws_scale(
                funny_stream_1.*.img_convert_ctx,
                @as([*c][*c]align(std.meta.alignment([*c][*c]u8)) u8, @ptrCast(@alignCast(&funny_stream_1.*.loop_ctx.pic.*.data))),
                @as([*c]align(std.meta.alignment(c_int)) c_int, @ptrCast(@alignCast(&funny_stream_1.*.loop_ctx.pic.*.linesize))),
                @as(c_int, 0),
                funny_stream_1.*.ccontext.*.height,
                @as([*c][*c]align(std.meta.alignment(u8)) u8, @ptrCast(@alignCast(&funny_stream_1.*.loop_ctx.pic_rgb.*.data))),
                @as([*c]align(std.meta.alignment(c_int)) c_int, @ptrCast(@alignCast(&funny_stream_1.*.loop_ctx.pic_rgb.*.linesize))),
            );

            const picbuf_size = @as(c_ulong, @bitCast(@as(c_long, funny_stream_1.*.loop_ctx.size2)));
            std.debug.assert(blob.len == picbuf_size);
            logger.info("blob bytes {x}", .{
                std.fmt.fmtSliceHexLower(blob[0..30]),
            });
            logger.info("frame bytes {x}", .{
                std.fmt.fmtSliceHexLower(funny_stream_1.*.loop_ctx.picture_buf2[0..30]),
            });
            std.mem.copy(u8, blob, funny_stream_1.*.loop_ctx.picture_buf2[0..picbuf_size]);
        }
    }
    //c.av_free_packet(&funny_stream_1.*.loop_ctx.packet);
    c.av_init_packet(&funny_stream_1.*.loop_ctx.packet);

    const elapsed: f64 = @as(f64, @floatFromInt(timer.read())) / @as(f64, @floatFromInt(std.time.ns_per_s));
    return elapsed;
}

export fn rtsp_stop_wrapper(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;
    if (c.lua_gettop(L) != @as(c_int, 2)) {
        return c.luaL_error(L, "rtsp_stop_wrapper expecting exactly 2 arguments");
    }

    const rtsp_stream_voidptr = c.luaL_checkudata(L, @as(c_int, 1), "funny_stream");
    var rtsp_stream: *funny_stream_t = @as(
        *align(std.meta.alignment(funny_stream_t)) funny_stream_t,
        @ptrCast(@alignCast(rtsp_stream_voidptr.?)),
    );

    rtsp_stream.stop = true;
    return 0;
}

export fn rtsp_frame_loop_wrapper(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;

    return rtsp_frame_loop(L) catch |err| {
        logger.err("error happened shit {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        c.lua_pushstring(L, "error in native rtsp library");
        _ = c.lua_error(L);
        return 1;
    };
}

const FPS_TARGET: f64 = 45;
const FPS_BUDGET: f64 = (1.0 / FPS_TARGET);

const Blob = struct {
    ptr: [*]u8,
    len: usize,
};

fn rtsp_frame_loop(L: *c.lua_State) !c_int {
    if (c.lua_gettop(L) != @as(c_int, 3)) {
        return c.luaL_error(L, "rtsp_frame_loop expecting exactly 3 arguments");
    }

    const rtsp_stream_voidptr = c.luaL_checkudata(L, @as(c_int, 1), "funny_stream");
    var rtsp_stream: *funny_stream_t = @as(
        *align(std.meta.alignment(funny_stream_t)) funny_stream_t,
        @ptrCast(@alignCast(rtsp_stream_voidptr.?)),
    );

    var unchecked_blob_ptr: ?[*]u8 = @as(?[*]u8, @ptrCast(c.lua_touserdata(L, @as(c_int, 2))));
    const blob_ptr_size: usize = @as(usize, @intFromFloat(c.luaL_checknumber(L, 3)));
    logger.info("blob ptr size {d}", .{blob_ptr_size});

    const blob = unchecked_blob_ptr.?[0..blob_ptr_size];

    while (true) {
        if (rtsp_stream.stop) {
            logger.info("stream loop stopping", .{});
            break;
        }

        const time_receiving_frame: f64 = try rtsp_fetch_frame(L, rtsp_stream, blob);
        const remaining_time = FPS_BUDGET - time_receiving_frame;
        std.log.info("timings {d:.6} {d:.6} {d:.6}", .{ FPS_BUDGET, time_receiving_frame, remaining_time });

        if (remaining_time > 0) {
            // good case: we decoded fast
            // we can sleep the rest of the ms knowing we're on 60fps target
            //std.time.sleep(@floatToInt(u64, remaining_time * std.time.ns_per_s));
        }
    }

    return 0;
}

const funny_lib = [_]c.luaL_Reg{
    c.luaL_Reg{ .name = "open", .func = funny_open },
    c.luaL_Reg{ .name = "frameLoop", .func = rtsp_frame_loop_wrapper },
    c.luaL_Reg{ .name = "stop", .func = rtsp_stop_wrapper },

    // v2 api
    c.luaL_Reg{ .name = "create", .func = main2.create },
    c.luaL_Reg{ .name = "open_v2", .func = main2.open },
    c.luaL_Reg{ .name = "addSlice", .func = main2.addSlice },
    c.luaL_Reg{ .name = "addDebugFrame", .func = main2.addDebugFrame },
    c.luaL_Reg{ .name = "runMainLoop", .func = main2.runMainLoop },

    // marker to stop the list here lol c moment
    c.luaL_Reg{ .name = null, .func = null },
};

export fn luaopen_rtsp(L: ?*c.lua_State) c_int {
    open_mutex.lock();
    defer open_mutex.unlock();

    _ = c.avformat_network_init();
    //_ = c.av_log_set_level(c.AV_LOG_DEBUG);
    _ = c.luaL_newmetatable(L, "funny_stream");
    _ = c.luaL_newmetatable(L, "rtsp_stream");
    c.luaL_register(L, "rtsp", &funny_lib);

    return 1;
}
