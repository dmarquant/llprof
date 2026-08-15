const std = @import("std");

pub const StringTableEntry = struct {
    offset: u32,
    len: u32,
};

pub const SampleData = struct {
    top: bool, // top of the callchain, starts a new sample

    known_file: bool, // false if the elf file could not be identified: offset contains raw ip

    known_symbol: bool, // true if a symbol name could be gathered for this file

    was_inlined: bool, 
    
    cpu: u32 = 0,

    tid: u32 = 0,

    time_ns: u64 = 0,

    // Offset into the elf file
    offset: u64 = 0,

    // Elf binary file
    elf_file: StringTableEntry = .{ .offset = 0, .len = 0 }, 

    // Symbol name, 
    symbol_name: StringTableEntry = .{ .offset = 0, .len = 0 },
};


pub const SampleWriter = struct {
    // TODO: Probably for many strings a hash table is useful

    string_table: std.ArrayList(u8) = .empty,

    pub fn deinit(w: *SampleWriter, gpa: std.mem.Allocator) void {
        w.string_table.deinit(gpa);
    }

    pub fn writeSample(w: *SampleWriter, writer: *std.Io.Writer, sample: SampleData) !void {
        _ = w;

        var flags: u8 = 0;
        if (sample.top)
            flags |= 0x1;
        if (sample.known_file)
            flags |= 0x2;
        if (sample.known_symbol)
            flags |= 0x4;
        if (sample.was_inlined)
            flags |= 0x8;

        try writer.writeByte(flags);

        if (sample.top) {
            try writer.writeInt(u32, sample.cpu, .little);
            try writer.writeInt(u32, sample.tid, .little);
            try writer.writeInt(u64, sample.time_ns, .little);
        }

        try writer.writeInt(u64, sample.offset, .little);

        if (sample.known_file) {
            try writer.writeInt(u32, sample.elf_file.offset, .little);
            try writer.writeInt(u32, sample.elf_file.len, .little);
        }

        if (sample.known_symbol) {
            try writer.writeInt(u32, sample.symbol_name.offset, .little);
            try writer.writeInt(u32, sample.symbol_name.len, .little);
        }
    }
    
    pub fn addOrGet(w: *SampleWriter, gpa: std.mem.Allocator, str: []const u8) !StringTableEntry {
        var ix: usize = 0;
        while (ix < w.string_table.items.len) {
            if (std.mem.findScalar(u8, w.string_table.items[ix..], 0)) |next0| {
                const s = w.string_table.items[ix .. ix + next0];
                if (std.mem.eql(u8, str, s)) {
                    return .{
                        .offset = @intCast(ix), 
                        .len = @intCast(next0)
                    };
                }
                ix += next0 + 1;
            } else {
                std.debug.assert(false);
            }
        }
        try w.string_table.appendSlice(gpa, str);
        try w.string_table.append(gpa, 0);

        return .{
            .offset = @intCast(ix), 
            .len = @intCast(str.len)
        };
    }

    pub fn get(w: SampleWriter, e: StringTableEntry) []const u8 {
        return w.string_table.items[e.offset .. e.offset + e.len];
    }
};

test "single string can be added and retrieved" {
    const gpa = std.testing.allocator;

    var writer: SampleWriter = .{};
    defer writer.deinit(gpa);

    const e1 = try writer.addOrGet(gpa, "hello world");
    const e2 = try writer.addOrGet(gpa, "hello world");
    try std.testing.expectEqual(e1, e2);

    try std.testing.expectEqualSlices(u8, "hello world", writer.get(e1));
}

test "serialization of string table is as expected" {
    const gpa = std.testing.allocator;

    var writer: SampleWriter = .{};
    defer writer.deinit(gpa);

    _ = try writer.addOrGet(gpa, "str");
    _ = try writer.addOrGet(gpa, "string");
    _ = try writer.addOrGet(gpa, "s");

    try std.testing.expectEqualSlices(u8, "str\x00string\x00s\x00", writer.string_table.items);
}
