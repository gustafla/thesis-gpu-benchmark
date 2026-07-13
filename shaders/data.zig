const std = @import("std");

const getParam = @import("genglsl").getParam;

pub const kernel = struct {
    const size = getParam("blur_radius");
    const sigma: comptime_float = getParam("blur_sigma");

    pub fn gaussian() [size + 1]f32 {
        var buffer: [size + 1]f32 = undefined;

        for (0..buffer.len) |i| buffer[i] = g(i);
        return buffer;
    }

    pub fn lso_m() u32 {
        return (size + 1) / 2;
    }

    pub fn lso_w_gaussian() [1 + lso_m()]f32 {
        var buffer: [1 + lso_m()]f32 = undefined;

        buffer[0] = g(0);

        var i: u32 = 1;
        while (i < size) : (i += 2) {
            buffer[1 + (i - 1) / 2] = g(i) + g(i + 1);
        }
        if (i == size) {
            buffer[1 + (i - 1) / 2] = g(i);
        }

        return buffer;
    }

    pub fn lso_o_gaussian() [1 + lso_m()]f32 {
        var buffer: [1 + lso_m()]f32 = undefined;

        buffer[0] = 0;

        var i: u32 = 1;
        while (i < size) : (i += 2) {
            const x0: f32 = @floatFromInt(i);
            const x1: f32 = @floatFromInt(i + 1);
            const w0 = g(x0);
            const w1 = g(x1);
            buffer[1 + (i - 1) / 2] = (w0 * x0 + w1 * x1) / (w0 + w1);
        }
        if (i == size) {
            buffer[1 + (i - 1) / 2] = @floatFromInt(i);
        }

        return buffer;
    }

    fn g(x: anytype) f32 {
        const x_f32: f32 = if (@TypeOf(x) == f32) x else @floatFromInt(x);
        return (1.0 / (sigma * @sqrt(2.0 * std.math.pi))) *
            (@exp((-1.0 / 2.0) * ((x_f32 * x_f32) / (sigma * sigma))));
    }
};
