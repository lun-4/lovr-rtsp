const std = @import("std");

const c_args = [_][]const u8{
    "-Wunreachable-code",
    "-Wall",
    "-Wpedantic",
    "-fPIC",
};

pub fn build(b: *std.build.Builder) void {
    const is_android = b.option(bool, "android", "building for the quest 2") orelse false;
    const android_ndk: ?[]const u8 = b.option([]const u8, "android-ndk", "building for the quest 2") orelse if (is_android) @panic("need android ndk") else null;
    const luajit_path: ?[]const u8 = b.option([]const u8, "luajit", "path to luajit target binary (required if cross compiling to quest 2)") orelse if (is_android) @panic("need luajit path") else null;

    var target: std.zig.CrossTarget = undefined;

    if (is_android) {
        // snapdragon xr2 is based on kryo
        // see https://en.wikipedia.org/wiki/List_of_Qualcomm_Snapdragon_processors#Snapdragon_XR1_and_XR2
        target = b.standardTargetOptions(.{
            .default_target = .{
                .cpu_arch = .aarch64,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.kryo },
                .os_tag = .linux,
                .abi = .android,
            },
        });
    } else {
        target = b.standardTargetOptions(.{});
    }

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addSharedLibrary(.{
        .name = "rtsp",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
        .target = target,
        .version = std.SemanticVersion{
            .major = 0,
            .minor = 0,
            .patch = 0,
        },
    });
    b.installArtifact(lib);

    lib.addCSourceFile(.{
        .file = .{ .path = "src/funny.c" },
        .flags = &c_args,
    });

    if (!is_android) {
        lib.linkLibC();
        lib.addIncludePath(.{ .path = "/usr/include/lua5.1" });
        lib.linkSystemLibrary("lua5.1");
        lib.linkSystemLibrary("avformat");
        lib.linkSystemLibrary("avutil");
        lib.linkSystemLibrary("avcodec");
        lib.linkSystemLibrary("avfilter");
        lib.linkSystemLibrary("swresample");
        lib.linkSystemLibrary("swscale");
    } else {
        lib.force_pic = true;
        lib.link_function_sections = true;
        lib.bundle_compiler_rt = true;

        std.log.info("got ndk '{?s}'", .{android_ndk});

        const sysroot =
            std.fs.path.join(b.allocator, &[_][]const u8{ android_ndk.?, "/toolchains/llvm/prebuilt/linux-x86_64/sysroot" }) catch unreachable;
        const include_generic =
            std.fs.path.join(b.allocator, &[_][]const u8{ sysroot, "/usr/include" }) catch unreachable;
        const include_arch_dependent =
            std.fs.path.join(b.allocator, &[_][]const u8{ sysroot, "/usr/include/aarch64-linux-android" }) catch unreachable;
        const libgcc_lib_path =
            std.fs.path.join(b.allocator, &[_][]const u8{ android_ndk.?, "/toolchains/llvm/prebuilt/linux-x86_64/lib/gcc/aarch64-linux-android/4.9.x" }) catch unreachable;

        std.log.info("sysroot '{s}'", .{sysroot});
        std.log.info("include_generic '{s}'", .{include_generic});
        std.log.info("include_arch_dependent '{s}'", .{include_arch_dependent});

        lib.defineCMacro("ANDROID", null);
        b.sysroot = sysroot;
        lib.setLibCFile(std.build.FileSource{ .path = "./android_libc.txt" });
        lib.addIncludePath(.{ .path = include_generic });
        lib.addIncludePath(.{ .path = include_arch_dependent });
        lib.linkLibC();

        lib.addIncludePath(.{ .path = "/usr/include/lua5.1" });
        lib.addIncludePath(.{ .path = "./q2_include" });

        lib.linkSystemLibrary("c");
        lib.linkSystemLibrary("./q2_lib/libavcodec.so");
        lib.linkSystemLibrary("./q2_lib/libavformat.so");
        lib.linkSystemLibrary("./q2_lib/libavutil.so");
        lib.linkSystemLibrary("./q2_lib/libswresample.so");
        lib.linkSystemLibrary("./q2_lib/libswscale.so");

        lib.addLibraryPath(.{ .path = std.fs.path.dirname(luajit_path.?).? });
        lib.linkSystemLibrary("luajit");
        lib.addLibraryPath(.{ .path = libgcc_lib_path });
        lib.linkSystemLibrary("gcc");
    }

    const exe_tests = b.addTest(
        .{
            .root_source_file = .{ .path = "src/main.zig" },
            .optimize = optimize,
            .target = target,
        },
    );

    const run_unit_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
