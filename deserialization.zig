const std = @import("std");

const SampleData = @import("serialization.zig").SampleData;
const StringTableEntry = @import("serialization.zig").StringTableEntry;


/// Load binary samples into machine readable format.
///


const LocationType = enum {
    Raw, // only ip
    Elf, // only elf file + offset
    Symbol, // function was resolved
};

const Location = struct {
    type: LocationType,
    name: StringTableEntry, // File or Symbol
    offset: u64, // 0 if has_symbol
};

const SampleCount = struct {
    inclusive: u64,
    exclusive: u64,
};

const LocationSampled = struct {
    location: Location,
    inclusive: u64,
    exclusive: u64,
};

pub fn readSamples(file_reader: *std.Io.File.Reader, gpa: std.mem.Allocator) !void {
    var reader = &file_reader.interface;

    const major = try reader.takeInt(u32, .little);
    const minor = try reader.takeInt(u32, .little);
    if (major != 0 or minor != 1) {
        return error.UnsupportedVersion;
    }

    const string_table_offset = try reader.takeInt(u64, .little);
    try file_reader.seekTo(string_table_offset);

    const string_table = try reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(string_table);
    std.debug.print("String table: {any}\n", .{ string_table });

    // after header
    try file_reader.seekTo(16);

    var counter: std.AutoHashMapUnmanaged(Location, SampleCount) = .{};
    defer counter.clearAndFree(gpa);

    var ix: usize = 0;
    while (file_reader.logicalPos() < string_table_offset) {
        const flags = try reader.takeByte();

        var sample = SampleData{
            .top = flags & 0x01 > 0,
            .known_file = flags & 0x02 > 0,
            .known_symbol = flags & 0x04 > 0,
            .was_inlined = flags & 0x08 > 0,
        };


        if (sample.top) {
            sample.cpu = try reader.takeInt(u32, .little);
            sample.tid = try reader.takeInt(u32, .little);
            sample.time_ns = try reader.takeInt(u64, .little);
        }

        sample.offset = try reader.takeInt(u64, .little);

        if (sample.known_file) {
            sample.elf_file = .{
                .offset = try reader.takeInt(u32, .little),
                .len = try reader.takeInt(u32, .little),
            };
        }

        if (sample.known_symbol) {
            sample.symbol_name = .{
                .offset = try reader.takeInt(u32, .little),
                .len = try reader.takeInt(u32, .little),
            };
        }

        var location: Location = undefined;
        if (sample.known_symbol) {
            location.type = .Symbol;
            location.name = sample.symbol_name;
            location.offset = 0;
        } else if (sample.known_file) {
            location.type = .Elf;
            location.name = sample.elf_file;
            location.offset = sample.offset;
        } else {
            location.type = .Raw;
            location.name.offset = 0;
            location.name.len = 0;
            location.offset = sample.offset;
        }
        ix += 1;

        const entry = try counter.getOrPutValue(gpa, location, .{ .inclusive = 0, .exclusive = 0 });
        entry.value_ptr.inclusive += 1;
        if (sample.top) {
            entry.value_ptr.exclusive += 1;
        }
    }

    var it = counter.iterator();
    while (it.next()) |entry| {
        const loc = entry.key_ptr;
        const count = entry.value_ptr;

        if (loc.type == .Symbol) {
            const name = string_table[loc.name.offset .. loc.name.offset + loc.name.len];
            std.debug.print("'{s}': inclusive({}), exclusive({})\n", .{ name, count.inclusive, count.exclusive });
        } else if (loc.type == .Elf) {
            const name = string_table[loc.name.offset .. loc.name.offset + loc.name.len];
            std.debug.print("'{s}@{x}': inclusive({}), exclusive({})\n", .{ name, loc.offset, count.inclusive, count.exclusive });
        } else {
            std.debug.print("'0x{x}': inclusive({}), exclusive({})\n", .{ loc.offset, count.inclusive, count.exclusive });
        }
    }
}


pub fn main(init: std.process.Init) !void {
    var cwd = std.Io.Dir.cwd();
    var samples_file = try cwd.openFile(init.io, "./samples.bin", .{});

    var read_buffer: [8 * 4096]u8 = undefined;
    var file_reader = samples_file.reader(init.io, &read_buffer);

    try readSamples(&file_reader, init.gpa);
}

