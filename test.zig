const std = @import("std");
const qoi = @import("qoi.zig");
const png = @import("zpng");

test "decode: dice" {
    try testDecode("dice");
}
test "decode: kodim10" {
    try testDecode("kodim10");
}
test "decode: kodim23" {
    try testDecode("kodim23");
}
test "decode: qoi_logo" {
    try testDecode("qoi_logo");
}
test "decode: testcard" {
    try testDecode("testcard");
}
test "decode: testcard_rgba" {
    try testDecode("testcard_rgba");
}
test "decode: wikipedia_008" {
    try testDecode("wikipedia_008");
}

test "encode: dice" {
    try testEncode("dice");
}
test "encode: kodim10" {
    try testEncode("kodim10");
}
test "encode: kodim23" {
    try testEncode("kodim23");
}
test "encode: qoi_logo" {
    try testEncode("qoi_logo");
}
test "encode: testcard" {
    try testEncode("testcard");
}
test "encode: testcard_rgba" {
    try testEncode("testcard_rgba");
}
test "encode: wikipedia_008" {
    try testEncode("wikipedia_008");
}

fn testDecode(comptime stem: []const u8) !void {
    const path_qoi = std.fmt.comptimePrint("qoi_test_images/{s}.qoi", .{stem});
    const path_png = std.fmt.comptimePrint("qoi_test_images/{s}.png", .{stem});

    const img_qoi = blk: {
        const f = try std.fs.cwd().openFile(path_qoi, .{});
        defer f.close();
        var bf = std.io.bufferedReader(f.reader());
        break :blk try qoi.readAlloc(std.testing.allocator, bf.reader());
    };
    defer std.testing.allocator.free(img_qoi.pixels);

    const img_png = blk: {
        const f = try std.fs.cwd().openFile(path_png, .{});
        defer f.close();
        var bf = std.io.bufferedReader(f.reader());
        break :blk try png.Image.read(std.testing.allocator, bf.reader());
    };
    defer img_png.deinit(std.testing.allocator);

    try std.testing.expectEqual(img_png.width, img_qoi.header.width);
    try std.testing.expectEqual(img_png.height, img_qoi.header.height);
    // TODO: check channels and colorspace

    for (img_png.pixels) |px, i| {
        errdefer std.debug.print("{}\n", .{i});
        try std.testing.expectEqual([4]u8{
            @intCast(u8, px[0] >> 8), @intCast(u8, px[1] >> 8),
            @intCast(u8, px[2] >> 8), @intCast(u8, px[3] >> 8),
        }, img_qoi.pixels[i]);
    }
}

fn testEncode(comptime stem: []const u8) !void {
    const path = std.fmt.comptimePrint("qoi_test_images/{s}.qoi", .{stem});

    const input = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 10 << 20);
    defer std.testing.allocator.free(input);
    var stream = std.io.fixedBufferStream(input);
    const img = try qoi.readAlloc(std.testing.allocator, stream.reader());
    defer std.testing.allocator.free(img.pixels);

    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try qoi.write(buf.writer(), img.header, img.pixels);

    try expectEqualBytes(input, buf.items);
}

fn expectEqualBytes(expected: []const u8, actual: []const u8) !void {
    for (actual) |b, i| {
        if (i >= expected.len) {
            break;
        }
        if (expected[i] != b) {
            std.debug.print("difference at byte 0x{x}: expected 0x{x}, found 0x{x}\n", .{ i, expected[i], b });

            const line_start = i & ~@as(usize, 15);
            const start = line_start -| 16;
            const end = line_start +| 2 * 16;
            hexDump(start, expected[start..@min(end, expected.len)]);
            std.debug.print("{s}\n", .{"-" ** 69});
            hexDump(start, actual[start..@min(end, actual.len)]);

            return error.TestExpectedEqual;
        }
    }
    if (expected.len != actual.len) {
        std.debug.print("lengths differ: expected {}, found {}\n", .{ expected.len, actual.len });
        return error.TestExpectedEqual;
    }
}
fn hexDump(offset: usize, bytes: []const u8) void {
    var base: usize = 0;
    while (base < bytes.len) : (base += 16) {
        const end = base + 16;

        std.debug.print("{x:0>8}:", .{base + offset});
        var i = base;
        while (i < end) : (i += 1) {
            if (i & 7 == 0) std.debug.print(" ", .{});
            if (i & 1 == 0) std.debug.print(" ", .{});
            if (i < bytes.len) {
                std.debug.print("{x:0>2}", .{bytes[i]});
            } else {
                std.debug.print("  ", .{});
            }
        }

        std.debug.print("  ", .{});
        for (bytes[base..@min(end, bytes.len)]) |b| {
            std.debug.print("{c}", .{
                if (std.ascii.isPrint(b)) b else '.',
            });
        }

        std.debug.print("\n", .{});
    }
}
