const std = @import("std");

pub fn readAlloc(allocator: std.mem.Allocator, r: anytype) !Image {
    var dec = decoder(r);
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

pub fn write(w: anytype, header: Header, pixels: []const [4]u8) !void {
    var enc = encoder(w);
    try enc.writeHeader(header);
    for (pixels) |px| {
        try enc.writePixel(px);
    }
    try enc.writeEnd();
}

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
pub fn encoder(w: anytype) Encoder(@TypeOf(w)) {
    return .{ .w = w };
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
            if (!try self.r.isBytes(&end_marker)) {
                return error.InvalidEndMarker;
            }
        }
    };
}

pub fn Encoder(comptime W: type) type {
    return struct {
        w: W,
        ppx: [4]u8 = .{ 0, 0, 0, 255 }, // Previous pixel
        run: u6 = 0, // Current run length
        map: [64][4]u8 = std.mem.zeroes([64][4]u8), // Pixel hash map

        const Self = @This();

        pub fn writeHeader(self: Self, hdr: Header) !void {
            try self.w.writeAll("qoif");
            try self.w.writeIntBig(u32, hdr.width);
            try self.w.writeIntBig(u32, hdr.height);
            try self.w.writeByte(@enumToInt(hdr.channels));
            try self.w.writeByte(@enumToInt(hdr.colorspace));
        }

        pub fn writePixel(self: *Self, px: [4]u8) !void {
            defer {
                // Set previous pixel
                self.ppx = px;
                // Store pixel in hashmap
                self.map[pixelHash(px)] = px;
            }

            if (std.meta.eql(px, self.ppx) and self.run < 62) {
                // Add to the run length
                self.run += 1;
                return;
            }

            if (self.run > 0) {
                // Write a RUN chunk
                try self.w.writeByte(@as(u8, 0xc0) | (self.run - 1));
                self.run = 0;

                if (std.meta.eql(px, self.ppx)) {
                    // This is the case where we overflowed one RUN chunk,
                    // so we need to start another directly after
                    self.run += 1;
                    return;
                }
            }

            const idx = pixelHash(px);
            if (std.meta.eql(px, self.map[idx])) {
                // Write an INDEX chunk
                try self.w.writeByte(@as(u8, 0x00) | idx);
                return;
            }

            if (px[3] == self.ppx[3]) {
                const dr = @bitCast(i8, px[0] -% self.ppx[0]);
                const dg = @bitCast(i8, px[1] -% self.ppx[1]);
                const db = @bitCast(i8, px[2] -% self.ppx[2]);

                if (dr > -3 and dr < 2 and
                    dg > -3 and dg < 2 and
                    db > -3 and db < 2)
                {
                    // Write a DIFF chunk
                    try self.w.writeByte(@as(u8, 0x40) |
                        @intCast(u8, dr + 2) << 4 |
                        @intCast(u8, dg + 2) << 2 |
                        @intCast(u8, db + 2));
                    return;
                }

                const dr_g = dr -% dg;
                const db_g = db -% dg;
                if (dr_g > -9 and dr_g < 8 and
                    dg > -33 and dg < 32 and
                    db_g > -9 and db_g < 8)
                {
                    // Write a LUMA chunk
                    try self.w.writeByte(@as(u8, 0x80) | @intCast(u8, dg + 32));
                    try self.w.writeByte(@intCast(u8, dr_g + 8) << 4 | @intCast(u8, db_g + 8));
                    return;
                }

                // Write RGB chunk
                try self.w.writeByte(0xfe);
                try self.w.writeAll(px[0..3]);
            } else {
                // Write RGBA chunk
                try self.w.writeByte(0xff);
                try self.w.writeAll(px[0..4]);
            }
        }

        pub fn writeEnd(self: Self) !void {
            if (self.run > 0) {
                // Write the last RUN chunk
                try self.w.writeByte(@as(u8, 0xc0) | (self.run - 1));
            }

            try self.w.writeAll(&end_marker);
        }
    };
}

const end_marker = [1]u8{0} ** 7 ++ [1]u8{1};

fn pixelHash(px: [4]u8) u6 {
    const hash =
        px[0] *% 3 +%
        px[1] *% 5 +%
        px[2] *% 7 +%
        px[3] *% 11;
    return @truncate(u6, hash);
}
