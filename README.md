# Blur Filter Benchmark Suite

This project is a shader benchmark suite built on a custom [SDL3 GPU engine](https://github.com/gustafla/mehustin2).
It utilizes the Zig build system and injects a custom [GPU profiling fork of SDL3](https://github.com/gustafla/thesis-SDL)
into the engine's dependency tree.

The benchmark provides per-pass GPU nanosecond-precision timing data, allowing for analysis of various real-time blur filter
implementations across Vulkan compute and graphics pipelines.

## Directory Layout
```
📁 thesis-gpu-benchmark/  <-- You are here
├── 📁 zig-out/
│   ├── 📁 bin/           <-- Output binaries are generated here
│   └── 📁 results/       <-- Output CSVs are generated here
├── 📁 shaders/
│   └── 📄 bloom.glsl     <-- Blur filter implementations (multiple shaders)
├── 📁 src/
│   └── 📄 config.zon
│   └── 📄 timeline.zon
│   └── 📄 render.zon
├── 📄 build.zig
└── 📄 build.zig.zon
```

## Prerequisites

To successfully compile this benchmark, ensure the following dependencies are installed and available in your system's PATH:

* **Zig Compiler v0.16.0:** Building with an older zig version will result in build errors. Conversely, a more recent (e.g. nightly) version may work, but isn't recommended.
  * Arch Linux / CachyOS: `sudo pacman -S zig`
  * Other Linux OS: Download from [ziglang.org](https://ziglang.org/download/#release-0.16.0):
    ```bash
    cd ~
    curl -O "https://ziglang.org/download/0.16.0/zig-$(uname -m)-linux-0.16.0.tar.xz"
    tar -xJf "zig-$(uname -m)-linux-0.16.0.tar.xz"
    # Run the compiler from anywhere
    ~/zig-$(uname -m)-linux-0.16.0/zig zen
    ```
* **Google Shaderc (`glslc`):** The build process requires shaderc to compile the GLSL source files into SPIR-V binaries.
  * Arch Linux / CachyOS: `sudo pacman -S shaderc`
  * Ubuntu / Debian: `sudo apt install glslc`
* Check the engine [README](https://github.com/gustafla/mehustin2) if missing dependencies are encountered.

## Execution and Build Commands

The custom [`build.zig`](build.zig) handles compiling shaders and directing benchmark runs.
* **Compile:** `zig build` - Outputs binaries to `zig-out`.
* **Run the demo:** `zig build run` - Outputs binaries to `zig-out` and spins up the interactive testing.
  See the [engine README](https://github.com/gustafla/mehustin2) file for usage.
* **Run automated benchmarks:** `zig build benchmark` -
  Directs a fully automated, serialized profiling routine.
  It generates precise GPU timing data per each **tag** on the [`timeline`](#srctimelinezon).
  By default, it profiles each **tag** configuration for 10 seconds, with a 5 second warm-up period.
  You can override the testing duration directly from the command line interface:
  ```bash
  # Run every configured variant sequentially for 30 seconds, with a 2 second warm-up
  zig build -Doptimize=ReleaseFast benchmark -- 30 2
  ```

## Build Options

To query the full list of build options, run `zig build --help`.

For accurate results, never benchmark with a debug binary.
Use `-Doptimize`:
```bash
zig build -Doptimize=ReleaseFast benchmark
```

By default, the target architecture is the host CPU and its feature set.
To build for another architecture, such as generic x86_64, use `-Dtarget`:
```bash
# Generic x86_64
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu

# Generic aarch64
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
```

**Note:** *Each `zig build` command overwrites the binaries generated previously.*
Remember to output the correct binaries if you intend to export the build artifacts to another host,
i.e. don't forget to run `zig build` with the intended `-Doptimize` and `-Dtarget` options.

## Using the Built Binaries

This subsection documents the binaries emitted by `zig build`.
If you intend to run the benchmark on the same host as the build process, you can ignore this subsection and just use the `zig build` commands documented above.

The `benchmark` binary requires two positional arguments and additionally has two optional arguments.
1. Demo binary path (relative or absolute, use "./"-prefix if in the working directory).
2. CSV results output path (relative or absolute).
3. Run duration (in seconds, default = 10).
4. Warm-up duration override (in seconds, default = 5).
```bash
cd zig-out/bin
# Run the benchmark for 30 seconds with a 2 second warm-up, output CSVs to /mnt/results
./benchmark ./demo /mnt/results 30 2
```

The `demo` binary has two two optional flags.
* `--tags-override [tag1,...]`: Fix the set of runtime tags to a comma-separated list, ignore the [timeline](#srctimelinezon).
* `--duration-override [seconds]`: Quit after running for `seconds`, ignore the [timeline](#srctimelinezon).
```bash
cd zig-out/bin
# Run the demo for 30 seconds, output CSV to stdout
./demo --duration-override 30
```


## CSV Data Schema

When executing `zig build benchmark`, the stdout streams are captured into separate files
matching their **tag** identities inside `zig-out/results/[tag].csv`.

The CSV data uses the following schema:

| Column Index | Field Name | Data Type | Description |
| :--- | :--- | :--- | :--- |
| **0** | `PassIndex` | `integer` | Sequential index to the **tag**-culled `src/render.zon` pass list. [See below](#srcrenderzon). |
| **1** | `StartTicks` | `uint64` | Raw counter ticks at the start of pass execution on the GPU. |
| **2** | `EndTicks` | `uint64` | Raw counter ticks at the end of pass execution on the GPU. |
| **3** | `DurationNanos` | `float` | Pass start to end duration in nanoseconds. |

The initial rows contain per-run constants in comments, formatted `# [Field]: [value]`:
* `# WarmupDuration`: The total warm-up duration in nanoseconds.
* `# WarmupRows`: The number of initial data rows that are warming up the GPU. **Ignore** this number of initial rows.
* `# TimestampPeriod`: The GPU counter tick period in nanoseconds.

## Project Configuration Layout

The execution flow and parameters are managed entirely via static configuration declarations using the Zig Object Notation (`.zon`) format.

### [`src/config.zon`](src/config.zon)
This file contains global engine and shader options:
* `width` / `height`: Internal render resolution (1920x1080).
* `blur_radius`: Default blur kernel pixel radius.
* `blur_sigma`: Default standard deviation applied to Gaussian kernels.

### [`src/timeline.zon`](src/timeline.zon)
This file is the source of truth for **tags**.
It specifies the sequence of unique variant workloads targeted by the benchmarking suite. 
```zig
.{
    .tags = .{
        .{ .name = "comp_naive", .duration = 10, .t = .seq },
        .{ .name = "comp_2pass_separable", .duration = 10, .t = .seq },
        .{ .name = "comp_2pass_separable_cache", .duration = 10, .t = .seq },
        // ...
    },
}
```

### [`src/render.zon`](src/render.zon)
This file declares the per-frame pass list (render graph). Pass execution can be conditionally culled via the `require_all_tags` array field:
* If specified, a pass will only execute if the active **tag** matches one of the required values.
* If omitted, the pass executes unconditionally on every frame (e.g., UI or final post processing).
```zig
.{
    // .color_targets, .depth_targets, .samplers ...
    .passes = .{
        // Main render pass
        .{ .render = .{
            .drawcalls = .{
                .{
                    .pipelines = .{.{
                        .shader = .{ .all = .{
                            .file = "shaders.glsl",
                            .params = .{"main"},
                        } },
                        .depth_test = .{},
                    }},
                    // ..
                },
            },
            .color_targets = .{.{
                // ...
            }},
            // ...
        } },

        // Compute naive
        .{ .compute = .{
            .require_all_tags = .{.comp_naive},
            .dispatches = .{.{
                .comp = .{
                    .file = "bloom.glsl",
                    .params = .{ "naive", "blur_radius=20", "blur_sigma=5" },
                },
                .dimensions = .{
                    .threads = .{ .x = 8, .y = 8 },
                    .groups = .resolution_by_threads,
                },
                .readonly_storage_textures = .{"color_targets[1]"},
            }},
            .readwrite_storage_textures = .{"color_targets[3]"},
        } },

        // More passes...
    },
}
```
