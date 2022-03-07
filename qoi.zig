const std = @import("std");

pub fn readAlloc(allocator: std.mem.Allocator, r: anytype) !Image {
    var dec = Decoder(@TypeOf(r)){ .r = r };
    const header = try dec.readHeader();
    const pixels = try allocator.alloc([4]u8, @as(usize, header.width) * header.height);
    for (pixels) |*px| {
        px.* = try dec.readPixel();
    }
    try dec.readEnd();
    return Image{
        .header = header,
        .pixels = pixels,
    };
}
pub const Image = struct {
    header: Header,
    pixels: [][4]u8,
};

pub const Header = struct {
    width: u32,
    height: u32,
    channels: Channels,
    colorspace: ColorSpace,
};

pub const Channels = enum(u3) {
    rgb = 3,
    rgba = 4,
};
pub const ColorSpace = enum(u1) { srgb, linear };

pub fn decoder(r: anytype) Decoder(@TypeOf(r)) {
    return .{ .r = r };
}

pub fn Decoder(comptime R: type) type {
    return struct {
        r: R,
        ppx: [4]u8 = .{ 0, 0, 0, 255 }, // Previous pixel
        run: u6 = 0, // Current run length
        map: [64][4]u8 = std.mem.zeroes([64][4]u8), // Pixel hash map

        const Self = @This();

        pub fn readHeader(self: Self) !Header {
            if (!try self.r.isBytes("qoif")) {
                return error.InvalidMagic;
            }
            return Header{
                .width = try self.r.readIntBig(u32),
                .height = try self.r.readIntBig(u32),
                .channels = try std.meta.intToEnum(
                    Channels,
                    try self.r.readByte(),
                ),
                .colorspace = try std.meta.intToEnum(
                    ColorSpace,
                    try self.r.readByte(),
                ),
            };
        }

        pub fn readPixel(self: *Self) ![4]u8 {
            if (self.run > 0) {
                self.run -= 1;
                self.map[pixelHash(self.ppx)] = self.ppx;
                return self.ppx;
            }
            const op = try self.r.readByte();
            if (op == 0xff) { // RGBA
                try self.r.readNoEof(self.ppx[0..4]);
            } else if (op == 0xfe) { // RGB
                try self.r.readNoEof(self.ppx[0..3]);
            } else if (op >> 6 == 0) { // INDEX
                self.ppx = self.map[@truncate(u6, op)];
            } else if (op >> 6 == 1) { // DIFF
                self.ppx[0] = self.ppx[0] -% 2 +% @truncate(u2, op >> 4);
                self.ppx[1] = self.ppx[1] -% 2 +% @truncate(u2, op >> 2);
                self.ppx[2] = self.ppx[2] -% 2 +% @truncate(u2, op >> 0);
            } else if (op >> 6 == 2) { // LUMA
                const op2 = try self.r.readByte();
                const dg = @truncate(u6, op);
                const dr = @intCast(u4, op2 >> 4);
                const db = @truncate(u4, op2);

                self.ppx[0] = self.ppx[0] -% 40 +% dr +% dg;
                self.ppx[1] = self.ppx[1] -% 32 +% dg;
                self.ppx[2] = self.ppx[2] -% 40 +% db +% dg;
            } else if (op >> 6 == 3) { // RUN
                self.run = @truncate(u6, op);
            }

            self.map[pixelHash(self.ppx)] = self.ppx;
            return self.ppx;
        }

        pub fn readEnd(self: Self) !void {
            const marker = [1]u8{0} ** 7 ++ [1]u8{1};
            if (!try self.r.isBytes(&marker)) {
                return error.InvalidEndMarker;
            }
        }
    };
}

fn pixelHash(px: [4]u8) u6 {
    const hash =
        px[0] *% 3 +%
        px[1] *% 5 +%
        px[2] *% 7 +%
        px[3] *% 11;
    return @truncate(u6, hash);
}
