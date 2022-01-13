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
    stream: *c.AVStream,
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
    context: ?*c.AVFormatContext,
    ccontext: *c.AVCodecContext,
    video_stream_index: c_int,
    loop_ctx: funny_stream_loop_t,
};

export fn funny_open(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L;
    var rtsp_url_len: usize = undefined;
    var rtsp_url: [*c]const u8 = c.luaL_checklstring(L, @as(c_int, 1), &rtsp_url_len);
    var funny_stream_1: *funny_stream_t = @ptrCast(
        *funny_stream_t,
        @alignCast(std.meta.alignment(funny_stream_t), c.lua_newuserdata(L, @sizeOf(funny_stream_t)).?),
    );
    _ = c.lua_getfield(L, -@as(c_int, 10000), "funny_stream");
    _ = c.lua_setmetatable(L, -@as(c_int, 2));
    funny_stream_1.context = c.avformat_alloc_context();
    funny_stream_1.loop_ctx.codec = c.avcodec_find_decoder(@bitCast(c_uint, c.AV_CODEC_ID_H264)) orelse {
        c.lua_pushstring(L, "could not find h264 decoder");
        return c.lua_error(L);
    };
    funny_stream_1.*.ccontext = c.avcodec_alloc_context3(funny_stream_1.*.loop_ctx.codec);
    if (c.avformat_open_input(&funny_stream_1.*.context, rtsp_url, null, null) != @as(c_int, 0)) {
        c.lua_pushstring(L, "c.avformat_open_input error");
        _ = c.lua_error(L);
    }
    if (c.avformat_find_stream_info(funny_stream_1.*.context, null) < @as(c_int, 0)) {
        c.lua_pushstring(L, "c.avformat_find_stream_info error");
        _ = c.lua_error(L);
    }
    {
        var i: c_int = 0;
        while (@bitCast(c_uint, i) < funny_stream_1.*.context.?.nb_streams) : (i += 1) {
            if ((blk: {
                const tmp = i;
                if (tmp >= 0) break :blk funny_stream_1.*.context.?.streams + @intCast(usize, tmp) else break :blk funny_stream_1.*.context.?.streams - ~@bitCast(usize, @intCast(isize, tmp) +% -1);
            }).*.*.codec.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
                funny_stream_1.*.video_stream_index = i;
            }
        }
    }
    c.av_init_packet(&funny_stream_1.*.loop_ctx.packet);
    funny_stream_1.*.loop_ctx.oc = c.avformat_alloc_context();
    _ = c.av_read_play(funny_stream_1.context);
    _ = c.avcodec_get_context_defaults3(funny_stream_1.*.ccontext, funny_stream_1.*.loop_ctx.codec);
    _ = c.avcodec_copy_context(funny_stream_1.*.ccontext, (blk: {
        const tmp = funny_stream_1.*.video_stream_index;
        if (tmp >= 0) break :blk funny_stream_1.context.?.streams + @intCast(usize, tmp) else break :blk funny_stream_1.context.?.streams - ~@bitCast(usize, @intCast(isize, tmp) +% -1);
    }).*.*.codec);

    {
        var m = std.Thread.Mutex{};
        m.lock();
        defer m.unlock();

        if (c.avcodec_open2(
            funny_stream_1.*.ccontext,
            funny_stream_1.*.loop_ctx.codec,
            null,
        ) < @as(c_int, 0)) {
            c.lua_pushstring(L, "c.avcodec_open fail");
            _ = c.lua_error(L);
        }
    }
    funny_stream_1.*.img_convert_ctx = c.sws_getContext(
        funny_stream_1.*.ccontext.*.width,
        funny_stream_1.*.ccontext.*.height,
        funny_stream_1.*.ccontext.*.pix_fmt,
        funny_stream_1.*.ccontext.*.width,
        funny_stream_1.*.ccontext.*.height,
        c.AV_PIX_FMT_RGB24,
        @as(c_int, 4),
        null,
        null,
        null,
    ) orelse {
        c.lua_pushstring(L, "failed to load sws context");
        return c.lua_error(L);
    };

    funny_stream_1.*.loop_ctx.size = c.avpicture_get_size(c.AV_PIX_FMT_YUV420P, funny_stream_1.*.ccontext.*.width, funny_stream_1.*.ccontext.*.height);
    funny_stream_1.*.loop_ctx.picture_buf = @ptrCast([*c]u8, @alignCast(@import("std").meta.alignment(u8), c.av_malloc(@bitCast(usize, @as(c_long, funny_stream_1.*.loop_ctx.size)))));
    funny_stream_1.*.loop_ctx.pic = c.av_frame_alloc();
    _ = c.avpicture_fill(@ptrCast([*c]c.AVPicture, @alignCast(@import("std").meta.alignment(c.AVPicture), funny_stream_1.*.loop_ctx.pic)), funny_stream_1.*.loop_ctx.picture_buf, c.AV_PIX_FMT_YUV420P, funny_stream_1.*.ccontext.*.width, funny_stream_1.*.ccontext.*.height);
    funny_stream_1.*.loop_ctx.size2 = c.avpicture_get_size(c.AV_PIX_FMT_RGB24, funny_stream_1.*.ccontext.*.width, funny_stream_1.*.ccontext.*.height);
    funny_stream_1.*.loop_ctx.picture_buf2 = @ptrCast([*c]u8, @alignCast(@import("std").meta.alignment(u8), c.av_malloc(@bitCast(usize, @as(c_long, funny_stream_1.*.loop_ctx.size2)))));
    funny_stream_1.*.loop_ctx.pic_rgb = c.av_frame_alloc();
    _ = c.avpicture_fill(
        @ptrCast([*c]c.AVPicture, @alignCast(@import("std").meta.alignment(c.AVPicture), funny_stream_1.*.loop_ctx.pic_rgb)),
        funny_stream_1.*.loop_ctx.picture_buf2,
        c.AV_PIX_FMT_RGB24,
        funny_stream_1.*.ccontext.*.width,
        funny_stream_1.*.ccontext.*.height,
    );
    _ = c.printf("init done!\n");
    return 1;
}

export fn funny_fetch_frame(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L;
    var begin: c.timespec = undefined;
    var end: c.timespec = undefined;
    _ = c.clock_gettime(@as(c_int, 1), &begin);
    _ = c.printf("fetch frame!\n");
    if (c.lua_gettop(L) != @as(c_int, 2)) {
        return c.luaL_error(L, "expecting exactly 2 arguments");
    }
    var funny_stream_1: [*c]funny_stream_t = @ptrCast([*c]funny_stream_t, @alignCast(@import("std").meta.alignment(funny_stream_t), c.luaL_checkudata(L, @as(c_int, 1), "funny_stream")));
    var blob_ptr: ?*anyopaque = c.lua_touserdata(L, @as(c_int, 2));
    _ = (funny_stream_1 != @ptrCast([*c]funny_stream_t, @alignCast(@import("std").meta.alignment(funny_stream_t), @intToPtr(?*anyopaque, @as(c_int, 0))))) or (c.luaL_argerror(L, @as(c_int, 1), "'funny_stream' expected") != 0);
    if (c.av_read_frame(funny_stream_1.*.context, &funny_stream_1.*.loop_ctx.packet) < @as(c_int, 0)) {
        c.lua_pushstring(L, "c.av_read_frame return less than 0");
        _ = c.lua_error(L);
    }
    if (funny_stream_1.*.loop_ctx.packet.stream_index == funny_stream_1.*.video_stream_index) {
        _ = c.printf("video!\n");
        if (funny_stream_1.*.loop_ctx.stream == @ptrCast([*c]c.AVStream, @alignCast(@import("std").meta.alignment(c.AVStream), @intToPtr(?*anyopaque, @as(c_int, 0))))) {
            _ = c.printf("creating stream\n");
            funny_stream_1.*.loop_ctx.stream = c.avformat_new_stream(funny_stream_1.*.loop_ctx.oc, (blk: {
                const tmp = funny_stream_1.*.video_stream_index;
                if (tmp >= 0) break :blk funny_stream_1.*.context.?.streams + @intCast(usize, tmp) else break :blk funny_stream_1.*.context.?.streams - ~@bitCast(usize, @intCast(isize, tmp) +% -1);
            }).*.*.codec.*.codec);
            _ = c.avcodec_copy_context(funny_stream_1.*.loop_ctx.stream.*.codec, (blk: {
                const tmp = funny_stream_1.*.video_stream_index;
                if (tmp >= 0) break :blk funny_stream_1.*.context.?.streams + @intCast(usize, tmp) else break :blk funny_stream_1.*.context.?.streams - ~@bitCast(usize, @intCast(isize, tmp) +% -1);
            }).*.*.codec);
            funny_stream_1.*.loop_ctx.stream.*.sample_aspect_ratio = (blk: {
                const tmp = funny_stream_1.*.video_stream_index;
                if (tmp >= 0) break :blk funny_stream_1.*.context.?.streams + @intCast(usize, tmp) else break :blk funny_stream_1.*.context.?.streams - ~@bitCast(usize, @intCast(isize, tmp) +% -1);
            }).*.*.codec.*.sample_aspect_ratio;
        }
        var check: c_int = 0;
        funny_stream_1.*.loop_ctx.packet.stream_index = funny_stream_1.*.loop_ctx.stream.*.id;
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
    _ = c.avformat_network_init();
    _ = c.luaL_newmetatable(L, "funny_stream");
    c.luaL_register(L, "funny", &funny_lib);

    return 1;
}
