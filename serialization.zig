const std = @import("std");

const LocationTable = @import("location_table.zig").FillingLocationTable;

// Sample data:
// - header
// - string table
// - location table
// - samples
// - call chains / location lists

pub const ProfilingDataHeader = packed struct {
    major: u16 = 0,
    minor: u16 = 2,

    // number of bytes in the location table
    string_table_bytes: u32,

    // number of entries in the location table
    location_table_length: u32,

    // number to total samples in the file
    num_samples: u64,

    // number of locations recorded for all callchains, indices into location table
    num_locations: u64, 
};

pub const StringTableEntry = struct {
    offset: u32,
    len: u32,
};

pub const SampleData = struct {
    time_ns: u64 = 0,
    cpu: u32 = 0,
    tid: u32 = 0,
    num_frames: u32 = 0,
};

pub fn writeSamples(writer: *std.Io.Writer, st: StringTable, lt: LocationTable, samples: []SampleData, callchains: []u32) !void {
    const header: ProfilingDataHeader = .{
        .string_table_bytes = @intCast(st.table.items.len),
        .location_table_length = lt.serializedSize(),
        .num_samples = samples.len,
        .num_locations = callchains.len,
    };

    try writer.writeStruct(header, .little);
    try writer.writeAll(st.table.items);
    
    var loc_ix: u32 = 0;
    while (loc_ix < lt.next) : (loc_ix += 1) {
        // TODO: Find a better way to do it?
        var it = lt.hash_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == loc_ix) {
                const loc = entry.key_ptr.*;
                try writer.writeByte(@intFromEnum(loc));
                switch (loc) {
                    .address => |address| {
                        try writer.writeInt(u64, address, .little);
                    },
                    .elf_file => |elf_file| {
                        try writer.writeInt(u32, elf_file.name.offset, .little);
                        try writer.writeInt(u32, elf_file.name.len, .little);
                        try writer.writeInt(u64, elf_file.offset, .little);
                    },
                    .symbol => |symbol| {
                        try writer.writeInt(u32, symbol.file_name.offset, .little);
                        try writer.writeInt(u32, symbol.file_name.len, .little);
                        try writer.writeInt(u32, symbol.name.offset, .little);
                        try writer.writeInt(u32, symbol.name.len, .little);
                    }
                }
                continue;
            }
        }
    }

    for (samples) |sample| {
        try writer.writeInt(u64, sample.time_ns, .little);
        try writer.writeInt(u32, sample.cpu, .little);
        try writer.writeInt(u32, sample.tid, .little);
        try writer.writeInt(u32, sample.num_frames, .little);
    }

    for (callchains) |callchain_loc| {
        try writer.writeInt(u32, callchain_loc, .little);
    }

    try writer.flush();
}

pub const StringTable = struct {
    // TODO: Probably for many strings a hash table is useful
    table: std.ArrayList(u8) = .empty,

    pub fn deinit(st: *StringTable, gpa: std.mem.Allocator) void {
        st.table.deinit(gpa);
    }

    pub fn addOrGet(st: *StringTable, gpa: std.mem.Allocator, str: []const u8) !StringTableEntry {
        var ix: usize = 0;
        while (ix < st.table.items.len) {
            if (std.mem.findScalar(u8, st.table.items[ix..], 0)) |next0| {
                const s = st.table.items[ix .. ix + next0];
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
        try st.table.appendSlice(gpa, str);
        try st.table.append(gpa, 0);

        return .{
            .offset = @intCast(ix), 
            .len = @intCast(str.len)
        };
    }

    pub fn get(st: StringTable, e: StringTableEntry) []const u8 {
        return st.table.items[e.offset .. e.offset + e.len];
    }
};


test "single string can be added and retrieved" {
    const gpa = std.testing.allocator;

    var st: StringTable = .{};
    defer st.deinit(gpa);

    const e1 = try st.addOrGet(gpa, "hello world");
    const e2 = try st.addOrGet(gpa, "hello world");
    try std.testing.expectEqual(e1, e2);

    try std.testing.expectEqualSlices(u8, "hello world", st.get(e1));
}

test "serialization of string table is as expected" {
    const gpa = std.testing.allocator;

    var st: StringTable = .{};
    defer st.deinit(gpa);

    _ = try st.addOrGet(gpa, "str");
    _ = try st.addOrGet(gpa, "string");
    _ = try st.addOrGet(gpa, "s");

    try std.testing.expectEqualSlices(u8, "str\x00string\x00s\x00", st.table.items);
}
