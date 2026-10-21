const linux = @import("std").os.linux;
const std = @import("std");
const logging = @import("logging.zig");
const utils = @import("utils.zig");
const ptrace_info = @import("ptrace_info");
const sys = @import("syscall.zig");

const Args = std.process.Args;

// const errors = error{ MissingTracee, EmptyPath, PtraceFailed, ExecveFailed, PipeFailed};

fn printSyscall(pid: i32, syscall: linux.SYS, args: [6]c_ulonglong) !void {
    // buffer to store the syscall string arguments (copy from tracee address space to here)
    var str_arg_buf: [512]u8 = undefined;
    // buffer to store the formatted syscall print line
    var buf: [512 * 4]u8 = undefined;

    var fba = std.heap.FixedBufferAllocator.init(&str_arg_buf);
    const decoded_args = try sys.decodeArgs(fba.allocator(), pid, syscall, args);

    var written = (try std.mem.print(&buf, "-> {s}(", .{@tagName(syscall)})).len;

    for (decoded_args) |arg| {
        switch (arg) {
            .string => {
                const wrote = (try std.mem.print(buf[written..], "{q}", .{arg.string.items})).len;
                written += wrote;
            },
            .int => {
                const wrote = (try std.mem.print(buf[written..], "{d}", .{arg.int})).len;
                written += wrote;
            },
            .raw => {
                const wrote = (try std.mem.print(buf[written..], "0x{x}", .{arg.raw})).len;
                written += wrote;
            },
            .null => {
                const wrote = (try std.mem.print(buf[written..], "NULL", .{})).len;
                written += wrote;
            },
            .empty => {
                continue;
            },
        }

        const wrote = (try std.mem.print(buf[written..], ", ", .{})).len;
        written += wrote;
    }

    if (std.mem.endsWith(u8, buf[0..written], ", ")) {
        written -= 2;
    }

    const wrote = (try std.mem.print(buf[written..], ")", .{})).len;
    written += wrote;

    logging.info("{s}", .{buf[0..written]});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena;
    const io = init.io;

    logging.enable();
    // logging.setLevel(logging.Level.debug);

    var argIter = init.minimal.args.iterate();
    _ = argIter.next();

    var maybe_tracee: ?[:0]const u8 = null;

    while (argIter.next()) |a| {
        maybe_tracee = a;
    }

    if (maybe_tracee == null) {
        return error.MissingTracee;
    }

    const tracee = maybe_tracee.?;
    logging.debug("tracee: {s}", .{tracee});

    // 0 -> read end : 1 -> write end
    var pipe_fds: [2]linux.fd_t = undefined;
    if (linux.pipe2(&pipe_fds, .{ .CLOEXEC = true }) != 0) {
        return error.PipeFailed;
    }

    const pid: i32 = @intCast(linux.fork());
    if (pid == 0) {
        logging.info("I'm child!", .{});

        if (linux.errno(linux.dup2(pipe_fds[1], linux.STDOUT_FILENO)) != .SUCCESS) {
            return error.Dup2Failed;
        }
        _ = linux.close(pipe_fds[0]);
        _ = linux.close(pipe_fds[1]);

        if (init.environ_map.get("PATH")) |path| {
            const zig_realpath_slice = try utils.lookup(arena.allocator(), io, path, tracee);
            const c_str_realpath = try arena.allocator().dupeSentinel(u8, zig_realpath_slice, 0);

            var argv_list: std.ArrayList(?[*:0]const u8) = .empty;
            try argv_list.append(arena.allocator(), c_str_realpath);
            const argv = try argv_list.toOwnedSliceSentinel(arena.allocator(), null);

            const envp: [:null]?[*:0]const u8 = blk: {
                const gpa = arena.allocator();
                var env_list: std.ArrayList(?[*:0]const u8) = .empty;
                var iter = init.environ_map.iterator();
                while (iter.next()) |entry| {
                    const envvar_str = try gpa.printSentinel("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0);
                    try env_list.append(gpa, envvar_str);
                }
                break :blk try env_list.toOwnedSliceSentinel(gpa, null);
            };

            logging.info("about to trace {s}", .{zig_realpath_slice});
            if (linux.ptrace(linux.PTRACE.TRACEME, 0, 0, 0, 0) != 0) {
                return error.PtraceFailed;
            }
            _ = linux.execve(c_str_realpath, argv, envp.ptr);

            return error.ExecveFailed;
        } else {
            return error.EmptyPath;
        }
    } else {
        logging.info("I'm parent!", .{});
        _ = linux.close(pipe_fds[1]);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        const WatchStdout = struct {
            fn run(gpa: std.mem.Allocator, fd: linux.fd_t, buf_ref: *std.ArrayList(u8)) !void {
                defer _ = linux.close(fd);

                var buf_temp: [256]u8 = undefined;
                var bytes = linux.read(fd, &buf_temp, 256);
                if (linux.errno(bytes) != .SUCCESS) {
                    return error.ReadFailed;
                }
                while (bytes != 0) {
                    try buf_ref.appendSlice(gpa, buf_temp[0..bytes]);
                    bytes = linux.read(fd, &buf_temp, 256);
                    if (linux.errno(bytes) != .SUCCESS) {
                        return error.ReadFailed;
                    }
                }
            }
        };

        const t1 = try std.Thread.spawn(.{}, WatchStdout.run, .{ allocator, pipe_fds[0], &buf });

        while (true) {
            var status: i32 = undefined;
            _ = linux.waitpid(pid, &status, 0);
            if (linux.W.IFEXITED(@intCast(status))) {
                logging.debug("tracee exited", .{});
                break;
            }
            if (linux.W.IFSIGNALED(@intCast(status))) {
                logging.debug("tracee signaled", .{});
            }
            if (linux.W.IFSTOPPED(@intCast(status))) {
                logging.debug("tracee stopped", .{});
                var info: ptrace_info.ptrace_syscall_info = .{};
                const info_size = @sizeOf(ptrace_info.ptrace_syscall_info);
                if (linux.ptrace(linux.PTRACE.GET_SYSCALL_INFO, pid, info_size, @intFromPtr(&info), 0) == 0) {
                    return error.PtraceFailed;
                }

                logging.debug("op: {}", .{info.op});

                if (ptrace_info.PTRACE_SYSCALL_INFO_NONE == info.op) {
                    _ = linux.ptrace(linux.PTRACE.SETOPTIONS, pid, 0, linux.PTRACE.O.TRACESYSGOOD, 0);
                    _ = linux.ptrace(linux.PTRACE.SYSCALL, pid, 0, 0, 0);
                }
                if (ptrace_info.PTRACE_SYSCALL_INFO_ENTRY == info.op) {
                    const entry = info.unnamed_0.entry;
                    const syscall_nr = entry.nr;
                    const syscall_args = entry.args;
                    const syscall: linux.SYS = @fromBackingInt(syscall_nr);

                    try printSyscall(pid, syscall, syscall_args);
                    _ = linux.ptrace(linux.PTRACE.SYSCALL, pid, 0, 0, 0);
                }
                if (ptrace_info.PTRACE_SYSCALL_INFO_EXIT == info.op) {
                    const exit = info.unnamed_0.exit;
                    logging.debug("<- (error: {})", .{exit.is_error != 0});
                    _ = linux.ptrace(linux.PTRACE.SYSCALL, pid, 0, 0, 0);
                }
            }
        }

        std.Thread.join(t1);
        std.debug.print("{s}", .{buf.items});
    }
}
