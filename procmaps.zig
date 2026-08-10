const std = @import("std");

const MmapRegion = struct {
    start: u64,
    end: u64,
    offset: u64,
    file_name: []const u8,

    pub fn deinit(self: *MmapRegion, gpa: std.mem.Allocator) void {
        gpa.free(self.file_name);
    }
};

pub const MappedRegions = struct {
    regions: []MmapRegion,

    pub fn deinit(self: *MappedRegions, gpa: std.mem.Allocator) void {
        for (self.regions) |*region| {
            region.deinit(gpa);
        }
        gpa.free(self.regions);
    }

    pub fn lookupAddress(self: MappedRegions, addr: u64) ?MmapRegion {
        // TODO: sort the list for faster lookup
        for (self.regions) |region| {
            if (region.start <= addr and addr < region.end) {
                return region;
            }
        }
        return null;
    }
};

pub fn readExecutableRegions(io: std.Io, gpa: std.mem.Allocator, pid: i32) !MappedRegions {
    const mmap_path = try std.fmt.allocPrint(gpa, "/proc/{}/maps", .{pid});
    defer gpa.free(mmap_path);

    var file = try std.Io.Dir.openFileAbsolute(io, mmap_path, .{});

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    var reader = &file_reader.interface;

    var regions: std.ArrayList(MmapRegion) = .empty;

    while (true) {
        const b = reader.peekByte();
        if (b == error.EndOfStream)
            break;

        var start_addr: u64 = 0;
        while (true) {
            const h = try reader.takeByte();
            const d = switch (h) {
                '0'...'9' => h - '0',
                'a'...'f' => h - 'a' + 10,
                'A'...'F' => h - 'A' + 10,
                '-' => break,
                else => break, // TODO: Error
            };
            start_addr = start_addr * 16 + d;
        }

        var end_addr: u64 = 0;
        while (true) {
            const h = try reader.takeByte();
            const d = switch (h) {
                '0'...'9' => h - '0',
                'a'...'f' => h - 'a' + 10,
                'A'...'F' => h - 'A' + 10,
                ' ' => break,
                else => break, // TODO: Error
            };
            end_addr = end_addr * 16 + d;
        }

        reader.toss(2);
        const executable = try reader.takeByte() == 'x';
        reader.toss(2);

        var offset: u64 = 0;
        while (true) {
            const h = try reader.takeByte();
            const d = switch (h) {
                '0'...'9' => h - '0',
                'a'...'f' => h - 'a' + 10,
                'A'...'F' => h - 'A' + 10,
                ' ' => break,
                else => break, // TODO: Error
            };
            offset = offset * 16 + d;
        }

        // Skip device and inode
        while (try reader.peekByte() != ' ') {
            reader.toss(1);
        }
        reader.toss(1);
        while (try reader.peekByte() != ' ') {
            reader.toss(1);
        }
        while (try reader.peekByte() == ' ') {
            reader.toss(1);
        }

        var file_name: std.ArrayList(u8) = .empty;
        defer file_name.deinit(gpa);

        while (try reader.peekByte() != '\n') {
            try file_name.append(gpa, try reader.takeByte());
        }
        reader.toss(1);

        if (executable) {
            try regions.append(gpa, .{ .start = start_addr, .end = end_addr, .offset = offset, .file_name = try file_name.toOwnedSlice(gpa) });
        }
    }
    return .{ .regions = try regions.toOwnedSlice(gpa) };
}

