# Blur Filter Benchmark Suite

This project is a shader benchmark suite built on a custom [SDL3 GPU engine](https://github.com/gustafla/mehustin2).
It utilizes the Zig build system and injects a custom [GPU profiling fork of SDL3](https://github.com/gustafla/thesis-SDL)
into the engine's dependency tree.

The benchmark provides per-pass GPU microsecond-precision timing data, allowing for analysis of various blur filter
implementations (e.g., naive gaussian convolution, Dual Kawase) across Vulkan compute and graphics pipelines.

## Prerequisites

To successfully compile and run this benchmark, your local development environment must be set up with the engine and tools.

### Directory Layout
Currently, this project relies on a relative local path to resolve the engine dependency.
Clone the engine repository directly into a sibling directory named `mehustin2` relative to this project root:
```bash
cd .. && git clone https://github.com/gustafla/mehustin2 && cd -
```

```
📁 my_thesis_workspace/
├── 📁 thesis-gpu-benchmark/  <-- You are here (Current Project Root)
│   ├── 📄 build.zig
│   └── 📄 build.zig.zon
└── 📁 mehustin2/             <-- Engine Source Tree
    ├── 📄 build.zig
    └── 📄 build.zig.zon
```

### System Toolchain Requirements

Before executing `zig build`, ensure the following dependencies are installed and available in your system's PATH:
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
  * Ubuntu / Debian: `sudo apt install shaderc`
* Check the engine [README](https://github.com/gustafla/mehustin2) if missing dependencies are encountered.

## Execution and Build Commands

The custom [`build.zig`](build.zig) handles compiling shaders and directing benchmark runs.
* **Run the demo:** `zig build run` -- Compiles and spins up the interactive testing.
  See the [engine README](https://github.com/gustafla/mehustin2) file for usage.
* **Run automated benchmarks:** `zig build benchmark` --
  Directs a fully automated, serialized profiling routine.
  It parses `src/timeline.zon` and generates precise GPU timing data per each **tag** on the `timeline`.
  By default, it profiles each **tag** configuration for 10 seconds.
  You can override the testing duration directly from the command line interface:
  ```bash
  # Run every configured variant sequentially for 30 seconds each
  zig build -Doptimize=ReleaseFast benchmark -- 30
  ```

## Build Options

To query the full list of build options, run `zig build --help`.

For accurate results, never benchmark with a debug binary.
Use `-Doptimize`:
```bash
zig build -Doptimize=ReleaseFast benchmark
```

## CSV Data Schema

When executing `zig build benchmark`, the stdout streams are captured into separate files
matching their **tag** identities inside `zig-out/results/[tag].csv`.

The CSV data format tracks the GPU pass execution timeline. It uses the following schema:

| Column Index | Field Name | Data Type | Description |
| :--- | :--- | :--- | :--- |
| **0** | `FrameCounter` | `integer` | Identifies frames (0 or 1, by default). |
| **1** | `PassIndex` | `integer` | Sequential index to the **tag**-culled `src/render.zon` pass list. [See below](#srcrenderzon). |
| **2** | `TimestampPeriod` | `float` | Hardware scale factor (nanoseconds per tick) copied from device limits. |
| **3** | `StartTicks` | `uint64` | Raw counter ticks at the start of pass execution on the GPU. |
| **4** | `EndTicks` | `uint64` | Raw counter ticks at the end of pass execution on the GPU. |
| **5** | `DurationMicros` | `float` | Total duration converted to microseconds. |

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
        .{ .name = "comp_naive", .duration = 100, .t = .seq },
        .{ .name = "comp_2pass_separable", .duration = 100, .t = .seq },
        .{ .name = "comp_2pass_separable_cache", .duration = 100, .t = .seq },
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
