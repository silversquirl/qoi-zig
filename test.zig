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
