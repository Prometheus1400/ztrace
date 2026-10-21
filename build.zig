const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const ptrace_info = b.addTranslateC(.{
        .root_source_file = b.path("src/ptrace_info.h"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    root_module.addImport("ptrace_info", ptrace_info.createModule());

    const exe = b.addExecutable(.{
        .name = "ztrace",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    run_exe.addPassthruArgs(); 

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}
