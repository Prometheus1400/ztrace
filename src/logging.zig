const std = @import("std");

const this = @This();

var enabled = false;

pub fn enable() void {
    this.enabled = true;
}

pub const Level = enum {
    debug,
    info,
    warn,
};

var set_log_level = Level.info;

pub fn setLevel(level: Level) void {
    this.set_log_level = level;
}

var enable_ansii = true;

const gray = "\x1b[38;5;250m";
const green = "\x1b[38;5;120m";
const yellow = "\x1b[38;5;229m";
const reset = "\x1b[0m";

fn logColor(comptime level: Level) []const u8 {
    return switch (level) {
        .debug => gray,
        .info => green,
        .warn => yellow,
    };
}

fn logPrefix(comptime level: Level) []const u8 {
    return switch (level) {
        .debug => "[DEBUG]",
        .info => "[INFO]",
        .warn => "[WARN]",
    };
}

pub fn log(comptime format: []const u8, args: anytype, comptime level: Level) void {
    if (!this.enabled) {
        return;
    }
    if (@backingInt(level) < @backingInt(this.set_log_level)) {
        return;
    }

    const prefix = comptime logPrefix(level);

    if (this.enable_ansii) {
        const color = comptime logColor(level);
        std.debug.print("{s}" ++ prefix ++ "{s}" ++ " " ++ format ++ "\n", .{ color, reset } ++ args);
    } else {
        std.debug.print(prefix ++ " " ++ format ++ "\n", args);
    }
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    log(format, args, Level.debug);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    log(format, args, Level.info);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    log(format, args, Level.warn);
}
