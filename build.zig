const std = @import("std");
const engine = @import("mehustin2");

pub fn build(b: *std.Build) void {
    // Initialize options and dependency
    const options = engine.Options.init(b);
    const engine_dep = b.dependency("mehustin2", options);
    const config = @import("src/config.zon");

    // Inject patched SDL3
    if (!options.system_sdl) {
        const patched_sdl_dep = b.dependency("sdl", .{
            .target = options.target,
            .optimize = options.optimize,
            .preferred_linkage = .static,
            .strip = options.optimize != .Debug,
            .sanitize_c = .off,
        });
        const patched_sdl_lib = patched_sdl_dep.artifact("SDL3");
        for (engine_dep.module("engine").link_objects.items) |*object| {
            switch (object.*) {
                .other_step => |step| if (std.mem.eql(u8, step.name, "SDL3")) {
                    object.* = .{ .other_step = patched_sdl_lib };
                },
                else => {},
            }
        }
    }

    // Create script module
    const script_mod = b.createModule(.{
        .root_source_file = b.path("src/script.zig"),
    });

    // Hook up module dependencies
    engine.importScript(engine_dep, script_mod);

    // Compile and install shaders
    engine.compileShaders(b, engine_dep, config);

    // Bake font atlases
    engine.bakeFontAtlases(b, engine_dep, config);

    // Install the build artifacts
    engine.install(b, engine_dep, options);

    // Get the main executable
    const exe = engine_dep.artifact(options.exe_name);

    // Load and parse timeline.zon at runtime
    const timeline = engine.parseZon(struct {
        tags: []const struct { name: []const u8 },
    }, b, "src/timeline.zon");

    const benchmark_step = b.step("benchmark", "Run all benchmarks");

    var seconds: []const u8 = "10";
    if (b.args) |args| seconds = args[0];
    var prev_step: ?*std.Build.Step = null;

    for (timeline.tags) |tag| {
        const run_step = b.addRunArtifact(exe);
        run_step.step.dependOn(b.getInstallStep());
        run_step.has_side_effects = true;
        run_step.setCwd(.{ .cwd_relative = b.exe_dir });
        run_step.addArgs(&.{
            "--tags-override",     tag.name,
            "--duration-override", seconds,
        });

        // Force sequential execution
        if (prev_step) |p| {
            run_step.step.dependOn(p);
        }

        // Capture CSV data
        const csv_output = run_step.captureStdOut(.{});

        // Install the captured CSV into zig-out/bin/
        const filename = b.fmt("{s}.csv", .{tag.name});
        const install_csv = b.addInstallBinFile(csv_output, filename);

        // Ensure the install step happens after the run step
        install_csv.step.dependOn(&run_step.step);
        benchmark_step.dependOn(&install_csv.step);
        prev_step = &run_step.step;
    }
}
