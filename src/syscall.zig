const this = @This();

const std = @import("std");
const linux = @import("std").os.linux;

const logging = @import("logging.zig");

const errors = error{NoSyscallArgTypeMapping};

pub const SyscallArg = union(enum) {
    empty,
    null: []const u8,
    string: std.ArrayList(u8),
    int: i64,
    raw: u64,
};

pub fn readTraceeNullTerminatedString(gpa: std.mem.Allocator, pid: i32, addr: c_ulonglong) !std.ArrayList(u8) {
    var res : std.ArrayList(u8) = .empty;
    errdefer res.deinit(gpa);
    var addr_var = addr;

    var word: usize = undefined;
    logging.debug("reading word at {d}", .{addr_var});
    var success = linux.ptrace(linux.PTRACE.PEEKDATA, pid, addr_var, @intFromPtr(&word), 0);
    read_words: while (success == 0) {
        const bytes: []u8 = std.mem.asBytes(&word);
        for (bytes) |byte| {
            if (byte == 0) {
                break :read_words;
            }
            res.append(gpa, byte) catch {
                if (res.items.len >= 3) {
                    @memset(res.items[res.items.len - 3 ..], '.');
                }
                break :read_words;
            };
        }
        addr_var += @sizeOf(usize);
        logging.debug("reading word at {d}", .{addr_var});
        success = linux.ptrace(linux.PTRACE.PEEKDATA, pid, addr_var, @intFromPtr(&word), 0);
    }

    return res;
}

fn decodeOpenat(gpa: std.mem.Allocator, pid: i32, args: [6]c_ulonglong) ![6]SyscallArg {
    var ret: [6]SyscallArg = undefined;
    for (args, 0..6) |arg, i| {
        ret[i] = switch (i) {
            0 => .{ .int = @intCast(arg) },
            1 => .{ .string = try readTraceeNullTerminatedString(gpa, pid, arg) },
            2 => .{ .int = @intCast(arg) },
            3 => .empty,
            4 => .empty,
            5 => .empty,
            else => unreachable,
        };
    }

    return ret;
}

fn decodeUnknown(args: [6]c_ulonglong) [6]SyscallArg {
    var ret: [6]SyscallArg = undefined;
    inline for (args, 0..) |arg, i| {
        ret[i] = .{ .raw = @bitCast(arg) };
    }
    return ret;
}

pub fn decodeArgs(gpa: std.mem.Allocator, pid: i32, nr: linux.SYS, args: [6]c_ulonglong) ![6]SyscallArg {
    return switch (nr) {
        .openat => try decodeOpenat(gpa, pid, args),
        else => decodeUnknown(args),
    };
}
