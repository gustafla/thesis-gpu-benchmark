const std = @import("std");
const Io = std.Io;

const timeline = @import("timeline.zon");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var write_buffer: [1024]u8 = undefined;

    var args = init.minimal.args.iterate();
    _ = args.skip();

    const exe_path = args.next() orelse return error.NoExePathArg;
    const results_path = args.next() orelse return error.NoResultsPathArg;
    const run_seconds = if (args.next()) |arg| try std.fmt.parseFloat(f64, arg) else null;
    const warmup_seconds = if (args.next()) |arg| try std.fmt.parseFloat(f64, arg) else 5;

    inline for (timeline.tags) |tag| {
        const run = try std.process.run(arena, io, .{
            .argv = &.{
                exe_path,
                "--tags-override",
                tag.name,
                "--duration-override",
                try std.fmt.allocPrint(
                    arena,
                    "{}",
                    .{(run_seconds orelse tag.duration) + warmup_seconds},
                ),
            },
        });

        var lines = std.mem.splitScalar(u8, run.stdout, '\n');
        const timestamp_ns = while (lines.next()) |line| {
            const tsp_key, const tsp_val = std.mem.cutScalar(u8, line, ':') orelse continue;
            if (!std.mem.eql(u8, tsp_key, "# TimestampPeriod")) continue;
            break try std.fmt.parseFloat(f32, std.mem.trim(u8, tsp_val, " "));
        } else return error.NoTimestampPeriod;

        const warmup_ns = warmup_seconds * std.time.ns_per_s;
        const warmup_ticks = warmup_ns / timestamp_ns;

        // Find the first valid row
        lines = std.mem.splitScalar(u8, run.stdout, '\n');
        const start_ticks = while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, ',');
            const pass = fields.next() orelse return error.NoPassIndex;
            const start = fields.next() orelse return error.NoStartField;
            std.debug.assert(std.mem.eql(u8, pass, "0"));
            break try std.fmt.parseInt(u64, start, 10);
        } else return error.NoStartField;

        // Find the first non-warmup row
        var warmup_rows: u64 = 1;
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var fields = std.mem.splitScalar(u8, line, ',');
            const pass = fields.next() orelse return error.NoPassIndex;
            const start = fields.next() orelse return error.NoStartField;
            if (std.mem.eql(u8, pass, "0")) {
                const this_ticks = try std.fmt.parseInt(u64, start, 10);
                const duration_ticks = this_ticks -| start_ticks;
                if (@as(f64, @floatFromInt(duration_ticks)) > warmup_ticks) break;
            }
            warmup_rows += 1;
        }

        // Install the captured CSV into results directory
        const results_dir = try Io.Dir.cwd().createDirPathOpen(io, results_path, .{});
        defer results_dir.close(io);
        const filename = try std.fmt.allocPrint(arena, "{s}.csv", .{tag.name});
        const file = try results_dir.createFile(io, filename, .{});
        defer file.close(io);
        var file_writer = file.writer(io, &write_buffer);

        file_writer.interface.print(
            "# WarmupDuration: {:.0}\n",
            .{warmup_ns},
        ) catch return file_writer.err.?;
        file_writer.interface.print(
            "# WarmupRows: {}\n",
            .{warmup_rows},
        ) catch return file_writer.err.?;
        file_writer.interface.writeAll(run.stdout) catch return file_writer.err.?;
        file_writer.interface.flush() catch return file_writer.err.?;
    }
}
