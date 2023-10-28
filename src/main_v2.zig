const std = @import("std");

const c = @import("main.zig").c;
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

const log = std.log.scoped(.lovr_rtsp);

fn maybeAvError(ret: c_int) !void {
    if (ret < 0) {
        var buf: [512]u8 = undefined;
        _ = c.av_strerror(ret, &buf, 512);
        var err = std.mem.span(&buf);
        log.err("libav returned {d}", .{ret});
        log.err("av error: {s}", .{err});

        return error.AvError;
    }
}

const Filter = struct {
    source: *c.AVFilterContext,
    sink: *c.AVFilterContext,
};
const Slice = struct {
    offset: [2]usize,
    size: [2]usize,

    /// Output RGB frame that's alredy cropped
    output_pic: Pic,

    /// Output byte array that will be shown to the VR device.
    /// data here will be copied from output_pic.buffer
    /// on every frame loop tick.
    output_image: [*]u8,

    filter: Filter,
};

const SliceList = std.ArrayList(Slice);
const PicList = std.ArrayList(Pic);

pub const State = struct {
    slices: SliceList,
};

const PicCodec = enum(u8) { yuv, rgb };
const Pic = extern struct {
    codec: PicCodec,
    size: usize,
    buffer: [*]u8,
    frame: *c.AVFrame,

    const Self = @This();

    fn create(codec: PicCodec, width: usize, height: usize) !Self {
        var pixel_format = switch (codec) {
            .yuv => c.AV_PIX_FMT_RGB24,
            .rgb => c.AV_PIX_FMT_RGB24,
        };

        const pic_size = c.avpicture_get_size(pixel_format, @as(c_int, @intCast(width)), @as(c_int, @intCast(height)));
        log.info("pic size {d} {d} = {d}", .{ width, height, pic_size });
        const buffer = @as(
            [*]align(std.meta.alignment(u8)) u8,
            @ptrCast(@alignCast(
                c.av_malloc(@as(usize, @bitCast(@as(c_long, pic_size)))).?,
            )),
        );
        const frame: *c.AVFrame = c.av_frame_alloc().?;
        frame.width = @as(c_int, @intCast(width));
        frame.height = @as(c_int, @intCast(height));
        frame.format = pixel_format;

        try maybeAvError(c.av_image_fill_arrays(
            &frame.data,
            &frame.linesize,
            buffer,
            pixel_format,
            @as(c_int, @intCast(width)),
            @as(c_int, @intCast(height)),
            1,
        ));

        log.info("frame resolution {d} {d}", .{ frame.width, frame.height });
        if (frame.width != width or frame.height != height) {
            log.err("expected {d}x{d}, created {d}x{d}", .{ width, height, frame.width, frame.height });
            return error.UnexpectedFrameResolution;
        }

        return Self{
            .codec = codec,
            .size = @as(usize, @intCast(pic_size)),
            .buffer = buffer,
            .frame = frame,
        };
    }
};

const ContextHolder = extern struct {
    codec: *c.AVCodecContext,
    format: *c.AVFormatContext,
    /// Configured to do YUV->RGB conversion
    pixfmt: *c.SwsContext,
};

fn avError(errno_value: std.os.E) c_int {
    return c.AVERROR(@as(c_int, @intCast(@intFromEnum(errno_value))));
}

pub const Stream = extern struct {
    /// Represents private state that isn't C ABI compatible.
    state: *State,

    ctx: ContextHolder,
    video_stream_index: usize,

    /// Allocated YUV frame.
    /// Will be written to as part of the main loop.
    /// Allocated RGB24 frame.
    /// Will be converted from an YUV frame in main loop.
    /// Contains full screen.
    fullscreen_rgb_pic: Pic,
    fullscreen_rgb_output: ?[*]u8 = null,

    const Self = @This();

    pub fn open(self: *Self, url: [:0]const u8) !void {
        var context_cptr = c.avformat_alloc_context().?;
        var context = @as(*c.AVFormatContext, @ptrCast(context_cptr));

        const codec =
            c.avcodec_find_decoder(@as(c_uint, @bitCast(c.AV_CODEC_ID_H264))) orelse return error.CodecNotFound;

        var codec_context_cptr = c.avcodec_alloc_context3(codec).?;
        var codec_context = @as(*c.AVCodecContext, @ptrCast(codec_context_cptr));

        var opts: ?*c.AVDictionary = null;
        try maybeAvError(c.av_dict_set(&opts, "reorder_queue_size", "100000", 0));

        log.info("open input", .{});
        if (c.avformat_open_input(&context_cptr, url.ptr, null, &opts) != @as(c_int, 0)) {
            return error.OpenInputError;
        }

        // set it again just in case avformat_open_input changed the pointer value!!!
        context = @as(*c.AVFormatContext, @ptrCast(context_cptr));
        self.ctx.format = context;

        log.info("stream info", .{});
        if (c.avformat_find_stream_info(context, null) < 0) {
            return error.FindStreamError;
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
        var video_stream_index: usize = maybe_video_stream_index orelse return error.NoVideoStreamFound;
        self.video_stream_index = video_stream_index;

        //var inner_loop_context = c.avformat_alloc_context();
        log.info("av read play", .{});
        // try maybeAvError(c.av_read_play(context));
        log.info("codec ctx get default", .{});
        try maybeAvError(c.avcodec_get_context_defaults3(codec_context_cptr, codec));
        codec_context = @as(*c.AVCodecContext, @ptrCast(codec_context_cptr));

        const stream_codec_context = context.streams[@as(usize, @intCast(video_stream_index))].*.codec.?;
        //const actual_stream_codec = stream_codec_context.*.codec.?;
        log.info("codec copy ctx", .{});
        try maybeAvError(c.avcodec_copy_context(codec_context_cptr, stream_codec_context));
        codec_context = @as(*c.AVCodecContext, @ptrCast(codec_context_cptr));
        self.ctx.codec = codec_context;

        log.info("codec open2", .{});
        try maybeAvError(c.avcodec_open2(self.ctx.codec, codec, null));

        // processing graph
        // YUV -> RGB (swscale)	-> RGB(1) 1st screen (filter)
        // 			-> RGB(2) 2nd screen (filter)
        //
        //
        // we don't know how many output screens we'll have right now so
        // just allocate what we can -- the yuv and fullscreen rgb frames

        self.ctx.pixfmt = c.sws_getContext(
            self.ctx.codec.width,
            self.ctx.codec.height,
            self.ctx.codec.pix_fmt, // pix fmt set by server codec setting
            self.ctx.codec.width,
            self.ctx.codec.height,
            c.AV_PIX_FMT_RGB24,
            4,
            null,
            null,
            null,
        ) orelse {
            return error.SwsFail;
        };

        std.debug.assert(self.ctx.codec.width > 0);
        std.debug.assert(self.ctx.codec.height > 0);

        self.fullscreen_rgb_pic = try Pic.create(.rgb, @as(usize, @intCast(self.ctx.codec.width)), @as(usize, @intCast(self.ctx.codec.height)));

        std.debug.assert(self.fullscreen_rgb_pic.frame.width > 0);
        std.debug.assert(self.fullscreen_rgb_pic.frame.height > 0);
    }

    pub fn addSlice(self: *Self, offset: [2]usize, size: [2]usize, output_image_pointer: [*]u8) !void {
        // each slice of the fullscreen RGB picture is a filter
        // that receives the fullscreen and writes to the createc Pic object
        // insice Slice.

        const alloc = std.heap.c_allocator;
        var graph = c.avfilter_graph_alloc().?;

        // create filter source (fullscreen_rgb_pic written on tick)

        var source: ?*c.AVFilterContext = null;
        log.info("set filter src", .{});

        var time_base: c.AVRational = self.ctx.format.streams[self.video_stream_index].*.time_base;
        const source_args = try std.fmt.allocPrint(
            alloc,
            "video_size={d}x{d}:pix_fmt={d}:time_base={d}/{d}:pixel_aspect={d}/{d}\x00",
            .{
                self.ctx.codec.width,
                self.ctx.codec.height,
                c.AV_PIX_FMT_RGB24,
                time_base.num,
                time_base.den,
                self.ctx.codec.sample_aspect_ratio.num,
                self.ctx.codec.sample_aspect_ratio.den,
            },
        );
        log.info("source {s}", .{source_args});
        try maybeAvError(
            c.avfilter_graph_create_filter(&source, c.avfilter_get_by_name("buffer").?, null, @as([*c]u8, @ptrCast(source_args.ptr)), null, graph),
        );
        std.debug.assert(source != null);

        // filter sink (our rgb24 pic)

        log.info("set filter sink", .{});
        var sink: ?*c.AVFilterContext = null;
        try maybeAvError(
            c.avfilter_graph_create_filter(&sink, c.avfilter_get_by_name("buffersink").?, null, null, null, graph),
        );
        //var pix_fmts = [_]c.AVPixelFormat{c.AV_PIX_FMT_RGB24};
        ////try maybeAvError(c.av_opt_set_int_list(sink, "pix_fmts", pix_fmts, c.AV_PIX_FMT_NONE, c.AV_OPT_SEARCH_CHILDREN));
        //try maybeAvError(
        //    c.av_opt_set_bin(sink, "pix_fmts", std.mem.asBytes(&pix_fmts), @sizeOf(c.AVPixelFormat), c.AV_OPT_SEARCH_CHILDREN),
        //);
        std.debug.assert(sink != null);

        // crop filter
        log.info("set filter crop", .{});
        const args = try std.fmt.allocPrint(
            alloc,
            "{d}:{d}:{d}:{d}\x00",
            .{ size[0], size[1], offset[0], offset[1] },
        );

        var crop: ?*c.AVFilterContext = null;
        try maybeAvError(
            c.avfilter_graph_create_filter(&crop, c.avfilter_get_by_name("crop").?, null, @as([*c]u8, @ptrCast(args.ptr)), null, graph),
        );
        std.debug.assert(crop != null);

        // source -> crop -> sink
        try maybeAvError(c.avfilter_link(source, 0, crop, 0));
        try maybeAvError(c.avfilter_link(crop, 0, sink, 0));
        try maybeAvError(c.avfilter_graph_config(graph, null));

        try self.state.slices.append(Slice{
            .offset = offset,
            .size = size,
            .output_pic = try Pic.create(.rgb, size[0], size[1]),
            .output_image = output_image_pointer,
            .filter = Filter{
                .source = source.?,
                .sink = sink.?,
            },
        });
    }

    pub fn addDebugFrame(self: *Self, output_image_pointer: [*]u8) !void {
        self.fullscreen_rgb_output = output_image_pointer;
    }

    pub fn runMainLoop(self: Self) !void {
        var packet: *c.AVPacket = c.av_packet_alloc().?;
        var frame: *c.AVFrame = c.av_frame_alloc().?;
        frame.width = @as(c_int, @intCast(self.ctx.codec.width));
        frame.height = @as(c_int, @intCast(self.ctx.codec.height));
        frame.format = c.AV_PIX_FMT_YUV420P;

        while (true) {
            defer c.av_packet_unref(packet);
            defer c.av_frame_unref(frame);

            try maybeAvError(c.av_read_frame(self.ctx.format, packet));

            if (packet.stream_index == self.video_stream_index) {
                var response = c.avcodec_send_packet(self.ctx.codec, packet);
                if (response < 0) {
                    var buf: [512]u8 = undefined;
                    _ = c.av_strerror(response, &buf, 512);
                    var err = std.mem.span(&buf);
                    log.err("send packet error: {s}", .{err});
                    return error.SendPacketError;
                }

                while (response >= 0) {
                    response = c.avcodec_receive_frame(self.ctx.codec, frame);
                    if (response == avError(.AGAIN)) break else try maybeAvError(response);
                    if (response >= 0) {
                        log.info("frame {d} type {s} size {d} format {d} pts {d} keyframe {d} dts {d}", .{
                            self.ctx.codec.frame_number,
                            &[_]u8{c.av_get_picture_type_char(frame.pict_type)},
                            frame.pkt_size,
                            frame.format,
                            frame.pts,
                            frame.key_frame,
                            frame.coded_picture_number,
                        });

                        if (frame.format != c.AV_PIX_FMT_YUV420P) {
                            log.err("invalid pixel format, expected yuv420p", .{});
                            return error.InvalidPixelFormat;
                        }

                        // frame contains YUV data. we must convert it to rgb24
                        try maybeAvError(c.sws_scale(
                            self.ctx.pixfmt,
                            &frame.data,
                            &frame.linesize,
                            @as(c_int, 0),
                            self.ctx.codec.height,
                            &self.fullscreen_rgb_pic.frame.data,
                            &self.fullscreen_rgb_pic.frame.linesize,
                        ));

                        if (self.fullscreen_rgb_output) |out_ptr| {
                            log.info("rgb copy", .{});
                            std.mem.copy(
                                u8,
                                out_ptr[0..self.fullscreen_rgb_pic.size],
                                self.fullscreen_rgb_pic.buffer[0..self.fullscreen_rgb_pic.size],
                            );
                        }

                        // from fullscreen_rgb_pic, spit slices
                        for (self.state.slices.items) |slice| {
                            log.info("add frame flags {d} {d}", .{ self.fullscreen_rgb_pic.frame.height, self.fullscreen_rgb_pic.frame.width });
                            try maybeAvError(
                                c.av_buffersrc_add_frame_flags(slice.filter.source, self.fullscreen_rgb_pic.frame, c.AV_BUFFERSRC_FLAG_KEEP_REF),
                            );

                            while (true) {
                                log.info("buffersink get frame", .{});
                                const sink_frame_ret = c.av_buffersink_get_frame(slice.filter.sink, slice.output_pic.frame);
                                if (sink_frame_ret == avError(.AGAIN)) break else try maybeAvError(sink_frame_ret);
                                defer c.av_frame_unref(slice.output_pic.frame);

                                // from the frame, write to output lovr image ptr

                                log.info("mem copy", .{});
                                std.mem.copy(
                                    u8,
                                    slice.output_image[0..slice.output_pic.size],
                                    slice.output_pic.buffer[0..slice.output_pic.size],
                                );
                            }
                        }
                    }
                }
            }
        }
    }
};

pub export fn create(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;

    var stream = @as(*align(std.meta.alignment(Stream)) Stream, @ptrCast(@alignCast(c.lua_newuserdata(
        L,
        @sizeOf(Stream),
    ) orelse @panic("failed to allocate stream userdata"))));
    c.lua_getfield(L, -@as(c_int, 10000), "rtsp_stream");
    _ = c.lua_setmetatable(L, -@as(c_int, 2));

    var allocator = std.heap.c_allocator;

    var state = allocator.create(State) catch unreachable;
    state.* = State{
        .slices = SliceList.init(allocator),
    };
    stream.* = Stream{
        .fullscreen_rgb_pic = undefined,
        .fullscreen_rgb_output = null,
        .ctx = undefined,
        .video_stream_index = 0,
        .state = state,
    };

    return 1;
}

fn luaString(L: *c.lua_State, comptime index: comptime_int) ?[:0]const u8 {
    var text_length: usize = undefined;
    var text = c.luaL_checklstring(L, @as(c_int, index), &text_length) orelse return null;
    return text[0..text_length :0];
}

pub fn open(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;
    if (c.lua_gettop(L) != @as(c_int, 2)) {
        return c.luaL_error(L, "expecting exactly 2 arguments");
    }

    const stream_unusable = c.luaL_checkudata(L, @as(c_int, 1), "rtsp_stream");
    var stream = @as(
        *align(std.meta.alignment(Stream)) Stream,
        @ptrCast(@alignCast(stream_unusable.?)),
    );

    const url = luaString(L, 2) orelse unreachable; // TODO error interface

    stream.open(url) catch |err| {
        log.err("error happened shit {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        c.lua_pushstring(L, "error happened inside native loop");
        _ = c.lua_error(L);
        return 1;
    };
    return 0;
}

pub fn addSlice(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;
    if (c.lua_gettop(L) != @as(c_int, 6)) {
        return c.luaL_error(L, "expecting exactly 6 arguments");
    }

    const stream_unusable = c.luaL_checkudata(L, @as(c_int, 1), "rtsp_stream");
    var stream = @as(
        *align(std.meta.alignment(Stream)) Stream,
        @ptrCast(@alignCast(stream_unusable.?)),
    );

    // args
    const offset_x = @as(usize, @intCast(c.luaL_checkint(L, 2)));
    const offset_y = @as(usize, @intCast(c.luaL_checkint(L, 3)));
    const size_x = @as(usize, @intCast(c.luaL_checkint(L, 4)));
    const size_y = @as(usize, @intCast(c.luaL_checkint(L, 5)));
    var blob_ptr = @as([*]u8, @ptrCast(c.lua_touserdata(L, 6) orelse @panic("invalid blob ptr")));

    // call

    stream.addSlice([_]usize{ offset_x, offset_y }, [_]usize{ size_x, size_y }, blob_ptr) catch |err| {
        log.err("error happened shit {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        c.lua_pushstring(L, "error happened inside native loop");
        _ = c.lua_error(L);
        return 1;
    };
    return 0;
}

pub fn addDebugFrame(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;
    if (c.lua_gettop(L) != @as(c_int, 2)) {
        return c.luaL_error(L, "expecting exactly 2 arguments");
    }

    const stream_unusable = c.luaL_checkudata(L, @as(c_int, 1), "rtsp_stream");
    var stream = @as(
        *align(std.meta.alignment(Stream)) Stream,
        @ptrCast(@alignCast(stream_unusable.?)),
    );

    // args
    var blob_ptr = @as([*]u8, @ptrCast(c.lua_touserdata(L, 2) orelse @panic("invalid blob ptr")));

    // call

    stream.addDebugFrame(blob_ptr) catch |err| {
        log.err("error happened shit {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        c.lua_pushstring(L, "error happened inside native loop");
        _ = c.lua_error(L);
        return 1;
    };
    return 0;
}

pub fn runMainLoop(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;
    if (c.lua_gettop(L) != @as(c_int, 1)) {
        return c.luaL_error(L, "expecting exactly 1 arguments");
    }

    const stream_unusable = c.luaL_checkudata(L, @as(c_int, 1), "rtsp_stream");
    var stream = @as(
        *align(std.meta.alignment(Stream)) Stream,
        @ptrCast(@alignCast(stream_unusable.?)),
    );

    // call
    stream.runMainLoop() catch |err| {
        log.err("error happened shit {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        c.lua_pushstring(L, "error happened inside native loop");
        _ = c.lua_error(L);
        return 1;
    };
    return 0;
}
