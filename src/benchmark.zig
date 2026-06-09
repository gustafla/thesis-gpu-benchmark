const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const schema = engine.schema;
const script = @import("script");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args = init.minimal.args.iterate();
    _ = args.skip();

    const exe_path = args.next() orelse return error.NoExePathArg;
    const results_path = args.next() orelse return error.NoResultsPathArg;
    const run_seconds = if (args.next()) |arg| try std.fmt.parseFloat(f64, arg) else null;
    const warmup_seconds = if (args.next()) |arg| try std.fmt.parseFloat(f64, arg) else 5;

    const results_dir = try Io.Dir.cwd().createDirPathOpen(io, results_path, .{});
    defer results_dir.close(io);

    inline for (script.config.timeline.tags) |tag| {
        if (tag.t != .seq) break;
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

        if (run.term.exited == 0) try processSuccess(
            io,
            arena,
            results_dir,
            run,
            tag.name,
            warmup_seconds,
        ) else {
            std.log.err("Run {s} failed. Saving stderr.", .{tag.name});
            const stderr_name = try std.fmt.allocPrint(arena, "{s}.stderr", .{tag.name});
            const stderr_file = try results_dir.createFile(io, stderr_name, .{});
            defer stderr_file.close(io);
            try stderr_file.writeStreamingAll(io, run.stderr);
        }

        _ = init.arena.reset(.retain_capacity);
    }
}

fn processSuccess(
    io: Io,
    arena: Allocator,
    results_dir: Io.Dir,
    run: std.process.RunResult,
    comptime tag_name: []const u8,
    warmup_seconds: f64,
) !void {
    var write_buffer: [1024]u8 = undefined;

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
    const filename = try std.fmt.allocPrint(arena, "{s}.csv", .{tag_name});
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
    lines = std.mem.splitScalar(u8, run.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            file_writer.interface.print("{s}\n", .{line}) catch return file_writer.err.?;
        } else {
            var fields = std.mem.splitScalar(u8, line, ',');
            const pass = fields.next() orelse return error.NoPassIndex;
            const i = try std.fmt.parseInt(u64, pass, 10);
            var buf1: [1024]u8 = undefined;
            var buf2: [1024]u8 = undefined;
            const desc = passDescription(&buf1, i, tag_name);
            file_writer.interface.print("{},{},\"{s}\",{s}\n", .{
                desc.p,
                desc.q,
                cleanName(&buf2, desc.name),
                line,
            }) catch return file_writer.err.?;
        }
    }
    file_writer.interface.flush() catch return file_writer.err.?;
}

fn cleanName(buffer: []u8, name: []const u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    const no_spv = std.mem.cutSuffix(u8, name, ".spv") orelse name;
    var iterator = std.mem.splitScalar(u8, no_spv, ',');
    writer.writeAll(iterator.next().?) catch unreachable;
    while (iterator.next()) |str| {
        // Skip numbers
        for (str) |c| {
            if (!std.ascii.isDigit(c)) break;
        } else continue;
        writer.print(" {s}", .{str}) catch unreachable;
    }
    return writer.buffered();
}

fn parseIndex(str: []const u8) ?u64 {
    const bracket = std.mem.indexOfScalar(u8, str, '[') orelse return null;
    const close = std.mem.indexOfScalar(u8, str, ']') orelse return null;
    if (close + 1 <= bracket) return null;
    return std.fmt.parseInt(u64, str[bracket + 1 .. close], 10) catch return null;
}

fn resolveRes(pass: anytype, comptime out_field: []const u8) struct { u32, u32 } {
    const outs = @field(pass, out_field);
    if (outs.len == 1) {
        if (!std.mem.startsWith(u8, outs[0].texture, "color_targets")) {
            return .{ 1, 1 };
        }
        const output_idx = parseIndex(outs[0].texture) orelse @panic("List index syntax error");
        const target = script.config.render.color_targets[output_idx];
        return .{ target.p, target.q };
    }
    return .{ 1, 1 };
}

const PassDescription = struct {
    name: []const u8,
    p: u32 = 1,
    q: u32 = 1,
};

fn passDescription(buffer: []u8, i: u64, comptime tag: []const u8) PassDescription {
    const passes = comptime filterPasses(unrollPasses(script.config.render), tag);
    if (i == passes.len) return .{ .name = "final_scaling" };
    const pass = passes[i];
    switch (pass) {
        .render => |rpass| {
            std.debug.assert(rpass.drawcalls.len > 0);
            std.debug.assert(rpass.drawcalls[0].pipelines.len == 1);
            std.debug.assert(rpass.drawcalls[0].pipelines[0].variants.len == 0);
            const stages = rpass.drawcalls[0].pipelines[0].shader.resolve();
            const frag_spv_filename = std.fmt.bufPrint(
                buffer,
                "{f}",
                .{stages.frag.spvFilenameFmt(.fragment, null, &.{})},
            ) catch @panic("Filename too long");
            const p, const q = resolveRes(rpass, "color_targets");
            return .{ .name = frag_spv_filename, .p = p, .q = q };
        },
        .compute => |cpass| {
            std.debug.assert(cpass.dispatches.len == 1);
            std.debug.assert(cpass.dispatches[0].variants.len == 0);
            const disp = cpass.dispatches[0];
            const comp = disp.comp;
            const comp_spv_filename = std.fmt.bufPrint(
                buffer,
                "{f}",
                .{comp.spvFilenameFmt(.compute, disp.threads, &.{})},
            ) catch @panic("Filename too long");
            const p, const q = resolveRes(cpass, "readwrite_storage_textures");
            return .{ .name = comp_spv_filename, .p = p, .q = q };
        },
        .unroll => unreachable,
    }
}

fn unrollPasses(comptime config: schema.Render) []const schema.Render.Pass {
    var num_passes = 0;
    for (config.passes) |pass| {
        switch (pass) {
            .unroll => |unroll| {
                const tmpl = schema.template.get(
                    schema.Render.Pass,
                    config.templates,
                    unroll.template,
                );
                num_passes += unroll.args.len * tmpl.passes.len;
            },
            else => num_passes += 1,
        }
    }

    @setEvalBranchQuota(1024 * config.passes.len * config.templates.len);
    var unrolled_passes: [num_passes]schema.Render.Pass = undefined;
    var i = 0;

    for (config.passes) |pass| {
        switch (pass) {
            .unroll => |unroll| {
                const template = schema.template.get(
                    schema.Render.Pass,
                    config.templates,
                    unroll.template,
                );
                const params = template.params;
                for (unroll.args) |args| {
                    for (template.passes) |tpass| {
                        unrolled_passes[i] = schema.template.applySubstitution(
                            schema.template.SliceAllocatorComptime,
                            tpass,
                            params,
                            args,
                        ) catch unreachable;
                        i += 1;
                    }
                }
            },
            else => {
                unrolled_passes[i] = pass;
                i += 1;
            },
        }
    }

    const final_passes = unrolled_passes;
    return &final_passes;
}

fn filterPasses(
    comptime passes: []const schema.Render.Pass,
    comptime tag: []const u8,
) []const schema.Render.Pass {
    var filtered_passes: [passes.len]schema.Render.Pass = undefined;
    var i = 0;

    for (passes) |pass| {
        const require_all_tags, const require_any_tags = switch (pass) {
            .unroll => unreachable,
            inline else => |p| .{ p.require_all_tags, p.require_any_tags },
        };
        if (require_all_tags.len > 1) continue;
        if (require_all_tags.len == 1 and !std.mem.eql(u8, require_all_tags[0], tag)) continue;
        if (require_any_tags.len > 0) {
            for (require_any_tags) |req_tag| {
                if (std.mem.eql(u8, req_tag, tag)) break;
            } else continue;
        }

        filtered_passes[i] = pass;
        i += 1;
    }

    const final_passes = filtered_passes[0..i].*;
    return &final_passes;
}
