const std = @import("std");
const logging = @import("logging.zig");

const errors = error{CommandNotFound};

pub fn lookup(gpa: std.mem.Allocator, io: std.Io, path: []const u8, command: []const u8) ![]const u8 {
    logging.debug("looking up {s} in {s}", .{ command, path });
    var iter = std.mem.splitSequence(u8, path, ":");

    while (iter.next()) |p| {
        logging.debug("checking for {s} in {s}", .{ command, p });
        const dir = std.Io.Dir.cwd().openDir(io, p, .{}) catch {
            logging.debug("unable to open {s}", .{ p });
            continue;
        };
        defer dir.close(io);
        dir.access(io, command, .{}) catch {
            logging.debug("{s} not found in {s}", .{ command, p });
            continue;
        };

        const realpath = try std.mem.concat(gpa, u8, &[_][]const u8{ p, "/", command });
        return realpath;
    }

    return errors.CommandNotFound;
}
