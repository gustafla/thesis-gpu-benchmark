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
                .other_step => |ostep| {
                    if (std.mem.eql(u8, ostep.name, "SDL3")) {
                        object.* = .{ .other_step = patched_sdl_lib };
                    }
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
}
