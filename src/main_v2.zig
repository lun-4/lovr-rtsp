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
        const maybe_av_error_name = libav_strerror(ret);
        if (maybe_av_error_name) |error_name| {
            log.err("av error: {s}", .{error_name});
        } else {
            log.err("libav returned {d}", .{ret});
        }
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
        var actual_codec = switch (codec) {
            .yuv => c.AV_PIX_FMT_RGB24,
            .rgb => c.AV_PIX_FMT_RGB24,
        };
        const pic_size = c.avpicture_get_size(actual_codec, @intCast(c_int, width), @intCast(c_int, height));
        const buffer = @ptrCast(
            [*]u8,
            @alignCast(
                std.meta.alignment(u8),
                c.av_malloc(@bitCast(usize, @as(c_long, pic_size))).?,
            ),
        );
        const pic = c.av_frame_alloc();
        try maybeAvError(c.avpicture_fill(
            @ptrCast(*c.AVPicture, pic),
            buffer,
            actual_codec,
            @intCast(c_int, width),
            @intCast(c_int, height),
        ));

        return Self{
            .codec = codec,
            .size = @intCast(usize, pic_size),
            .buffer = buffer,
            .frame = pic,
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
    return c.AVERROR(@intCast(c_int, @enumToInt(errno_value)));
}

pub const Stream = extern struct {
    /// Represents private state that isn't C ABI compatible.
    state: *State,

    ctx: ContextHolder,
    video_stream_index: usize,

    /// Allocated YUV frame.
    /// Will be written to as part of the main loop.
    yuv_pic: Pic,

    /// Allocated RGB24 frame.
    /// Will be converted from yuv_pic directly.
    /// Contains full screen.
    fullscreen_rgb_pic: Pic,

    const Self = @This();

    pub fn open(self: *Self, url: [:0]const u8) !void {
        _ = self;

        var context_cptr = c.avformat_alloc_context().?;
        var context = @ptrCast(*c.AVFormatContext, context_cptr);

        const codec =
            c.avcodec_find_decoder(@bitCast(c_uint, c.AV_CODEC_ID_H264)) orelse return error.CodecNotFound;

        var codec_context_cptr = c.avcodec_alloc_context3(codec).?;
        var codec_context = @ptrCast(*c.AVCodecContext, codec_context_cptr);

        var opts: ?*c.AVDictionary = null;
        try maybeAvError(c.av_dict_set(&opts, "reorder_queue_size", "100000", 0));

        if (c.avformat_open_input(&context_cptr, url.ptr, null, &opts) != @as(c_int, 0)) {
            return error.OpenInputError;
        }

        // set it again just in case avformat_open_input changed the pointer value!!!
        context = @ptrCast(*c.AVFormatContext, context_cptr);
        self.ctx.format = context;

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
        try maybeAvError(c.av_read_play(context));
        try maybeAvError(c.avcodec_get_context_defaults3(codec_context_cptr, codec));
        codec_context = @ptrCast(*c.AVCodecContext, codec_context_cptr);

        const stream_codec_context = context.streams[@intCast(usize, video_stream_index)].*.codec.?;
        //const actual_stream_codec = stream_codec_context.*.codec.?;
        try maybeAvError(c.avcodec_copy_context(codec_context_cptr, stream_codec_context));
        codec_context = @ptrCast(*c.AVCodecContext, codec_context_cptr);
        self.ctx.codec = codec_context;

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

        self.yuv_pic = try Pic.create(.yuv, @intCast(usize, self.ctx.codec.width), @intCast(usize, self.ctx.codec.height));
        self.fullscreen_rgb_pic = try Pic.create(.rgb, @intCast(usize, self.ctx.codec.width), @intCast(usize, self.ctx.codec.height));
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
                self.ctx.codec.pix_fmt,
                time_base.num,
                time_base.den,
                self.ctx.codec.sample_aspect_ratio.num,
                self.ctx.codec.sample_aspect_ratio.den,
            },
        );
        try maybeAvError(
            c.avfilter_graph_create_filter(&source, c.avfilter_get_by_name("buffer"), null, @ptrCast([*c]u8, source_args.ptr), null, graph),
        );

        // filter sink (our rgb24 pic)

        log.info("set filter sink", .{});
        var sink: ?*c.AVFilterContext = null;
        try maybeAvError(
            c.avfilter_graph_create_filter(&sink, c.avfilter_get_by_name("buffersink"), null, null, null, graph),
        );
        var pix_fmts = [_]c.AVPixelFormat{c.AV_PIX_FMT_RGB24};
        //try maybeAvError(c.av_opt_set_int_list(sink, "pix_fmts", pix_fmts, c.AV_PIX_FMT_NONE, c.AV_OPT_SEARCH_CHILDREN));
        try maybeAvError(
            c.av_opt_set_bin(sink, "pix_fmts", std.mem.asBytes(&pix_fmts), @sizeOf(c.AVPixelFormat), c.AV_OPT_SEARCH_CHILDREN),
        );

        // crop filter
        log.info("set filter crop", .{});
        const args = try std.fmt.allocPrint(
            alloc,
            "{d}:{d}:{d}:{d}\x00",
            .{ size[0], size[1], offset[0], offset[1] },
        );

        var crop: ?*c.AVFilterContext = null;
        try maybeAvError(
            c.avfilter_graph_create_filter(&crop, c.avfilter_get_by_name("crop").?, null, @ptrCast([*c]u8, args.ptr), null, graph),
        );

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

    pub fn runMainLoop(self: Self) !void {
        var packet: c.AVPacket = undefined;
        var frame: *c.AVFrame = c.av_frame_alloc().?;

        var reading_state = false;

        while (true) {
            c.av_init_packet(&packet);

            while (true) {
                log.info("read frame", .{});
                if (reading_state) {
                    const send_packet_ret = (c.avcodec_send_packet(self.ctx.codec, &packet));
                    if (send_packet_ret == avError(.AGAIN)) {
                        break;
                    } else try maybeAvError(send_packet_ret);
                }

                try maybeAvError(c.av_read_frame(self.ctx.format, &packet));
                if (packet.stream_index == self.video_stream_index) {
                    const send_packet_ret = (c.avcodec_send_packet(self.ctx.codec, &packet));
                    if (send_packet_ret == avError(.AGAIN)) {
                        reading_state = true;
                        break;
                    } else try maybeAvError(send_packet_ret);
                }
            }

            while (true) {
                log.info("recv frame", .{});
                const recv_frame_ret = c.avcodec_receive_frame(self.ctx.codec, frame);
                if (recv_frame_ret == avError(.AGAIN)) break else try maybeAvError(recv_frame_ret);

                // this frame contains YUV data. we must convert it to rgb24

                // from fullscreen_rgb_pic, spit slices
                for (self.state.slices.items) |slice| {
                    log.info("add frame flags", .{});
                    try maybeAvError(
                        c.av_buffersrc_add_frame_flags(slice.filter.source, self.fullscreen_rgb_pic.frame, c.AV_BUFFERSRC_FLAG_KEEP_REF),
                    );

                    while (true) {
                        log.info("buffersink get frame", .{});
                        const sink_frame_ret = c.av_buffersink_get_frame(slice.filter.sink, slice.output_pic.frame);
                        if (sink_frame_ret == avError(.AGAIN)) break else try maybeAvError(sink_frame_ret);

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
};

pub export fn create(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;

    var stream = @ptrCast(*Stream, @alignCast(std.meta.alignment(Stream), c.lua_newuserdata(
        L,
        @sizeOf(Stream),
    ) orelse @panic("failed to allocate stream userdata")));
    c.lua_getfield(L, -@as(c_int, 10000), "rtsp_stream");
    _ = c.lua_setmetatable(L, -@as(c_int, 2));

    var allocator = std.heap.c_allocator;

    var state = allocator.create(State) catch unreachable;
    state.* = State{
        .slices = SliceList.init(allocator),
    };
    stream.* = Stream{
        .yuv_pic = undefined,
        .fullscreen_rgb_pic = undefined,
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
    var stream = @ptrCast(
        *Stream,
        @alignCast(std.meta.alignment(Stream), stream_unusable.?),
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
    var stream = @ptrCast(
        *Stream,
        @alignCast(std.meta.alignment(Stream), stream_unusable.?),
    );

    // args
    const offset_x = @intCast(usize, c.luaL_checkint(L, 2));
    const offset_y = @intCast(usize, c.luaL_checkint(L, 3));
    const size_x = @intCast(usize, c.luaL_checkint(L, 4));
    const size_y = @intCast(usize, c.luaL_checkint(L, 5));
    var blob_ptr = @ptrCast([*]u8, c.lua_touserdata(L, 6) orelse @panic("invalid blob ptr"));

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

pub fn runMainLoop(arg_L: ?*c.lua_State) callconv(.C) c_int {
    var L = arg_L.?;
    if (c.lua_gettop(L) != @as(c_int, 1)) {
        return c.luaL_error(L, "expecting exactly 1 arguments");
    }

    const stream_unusable = c.luaL_checkudata(L, @as(c_int, 1), "rtsp_stream");
    var stream = @ptrCast(
        *Stream,
        @alignCast(std.meta.alignment(Stream), stream_unusable.?),
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
