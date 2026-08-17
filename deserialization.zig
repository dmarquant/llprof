const std = @import("std");

const SampleData = @import("serialization.zig").SampleData;
const StringTableEntry = @import("serialization.zig").StringTableEntry;

const LocationType = @import("location_table.zig").LocationType;
const Location = @import("location_table.zig").Location;

const DefaultArrayList = @import("default_array_list.zig").DefaultArrayList;

pub const CallchainNode = struct {
    loc_ix: u32 = 0,

    inclusive_count: u64 = 0,
    exclusive_count: u64 = 0,

    // index into the list of nodes
    children: DefaultArrayList(u32, 8) = .empty,
};

pub const CallchainTree = struct {
    node_list: std.ArrayList(CallchainNode) = .empty,

    root_node: u32 = 0,

    //arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) !CallchainTree {
        var tree: CallchainTree = .{
            .allocator = gpa,
        };


        try tree.node_list.append(tree.allocator, .{});
        return tree;
    }

    pub fn deinit(tree: *CallchainTree) void {
        _ = tree;
        //tree.arena.deinit();
    }

    pub fn addNode(tree: *CallchainTree, parent: *CallchainNode, loc_ix: u32) !*CallchainNode {
        try tree.node_list.append(tree.allocator, .{ .loc_ix = loc_ix });
        try parent.children.append(tree.allocator, @intCast(tree.node_list.items.len - 1));
        return &tree.node_list.items[tree.node_list.items.len - 1];
    }

    pub fn addCallchain(tree: *CallchainTree, locations: []u32) !void {
        var node = &tree.node_list.items[0];
        node.inclusive_count += 1;

        var ix = locations.len;
        while (ix > 0) {
            ix -= 1;

            var next_node: ?*CallchainNode = null;
            for (node.children.items()) |child| {
                if (tree.node_list.items[child].loc_ix == locations[ix]) {
                    next_node = &tree.node_list.items[child];
                    break;
                }
            }

            node = next_node orelse try tree.addNode(node, locations[ix]);
            if (ix == 0) {
                node.exclusive_count += 1;
            }
            node.inclusive_count += 1;
        }
    }
};



/// Load binary samples into machine readable format.
///
fn readStringTableEntry(reader: *std.Io.Reader) !StringTableEntry {
    const str_offset = try reader.takeInt(u32, .little);
    const str_len = try reader.takeInt(u32, .little);
    return .{
        .offset = str_offset,
        .len = str_len
    };
}

fn lookupString(st: []const u8, entry: StringTableEntry) []const u8 {
    return st[entry.offset .. entry.offset + entry.len];
}

fn printLocation(loc: Location, string_table: []const u8) void {
    switch (loc) {
        .elf_file => |elf_file| {
            const name = lookupString(string_table, elf_file.name);
            std.debug.print("{s}@{x}\n", .{ name, elf_file.offset });
        },
        .symbol => |symbol| {
            const file_name = lookupString(string_table, symbol.file_name);
            const name = lookupString(string_table, symbol.name);
            std.debug.print("{s}:{s}\n", .{ file_name, name });
        },
        .address => |address| {
            std.debug.print("0x{x}\n", .{ address });
        }
    }
}

pub fn readSamples(reader: *std.Io.Reader, arena: std.mem.Allocator) !void {
    const major = try reader.takeInt(u16, .little);
    const minor = try reader.takeInt(u16, .little);
    if (major != 0 or minor != 2) {
        return error.UnsupportedVersion;
    }

    const string_table_bytes = try reader.takeInt(u32, .little);
    const location_table_length = try reader.takeInt(u32, .little);
    const num_samples = try reader.takeInt(u64, .little);
    const num_locations = try reader.takeInt(u64, .little);

    std.debug.print("Reading {} samples and {} locations\n", .{ num_samples, num_locations });

    const string_table = try reader.readAlloc(arena, string_table_bytes);

    // TODO: This can be fixed size...
    var location_table: std.ArrayList(Location) = .empty;

    for (0 .. location_table_length) |_| {
        const first_byte = try reader.takeByte();
        const location_type: LocationType = @enumFromInt(first_byte);

        switch (location_type) {
            .address => {
                try location_table.append(arena, .{ .address = try reader.takeInt(u64, .little) });
            },
            .elf_file => {
                const name = try readStringTableEntry(reader);
                const offset = try reader.takeInt(u64, .little);
                try location_table.append(arena, .{ 
                    .elf_file = .{ 
                        .name = name,
                        .offset = offset,
                    }
                });
            },
            .symbol => {
                const file_name = try readStringTableEntry(reader);
                const name = try readStringTableEntry(reader);
                try location_table.append(arena, .{ 
                    .symbol = .{ 
                        .file_name = file_name,
                        .name = name,
                    }
                });
            }
        }
    }

    const samples = try arena.alloc(SampleData, num_samples);
    for (0 .. num_samples) |i| {
        samples[i].time_ns = try reader.takeInt(u64, .little);
        samples[i].cpu = try reader.takeInt(u32, .little);
        samples[i].tid = try reader.takeInt(u32, .little);
        samples[i].num_frames = try reader.takeInt(u32, .little);
    }

    const locations = try arena.alloc(u32, num_locations);
    for (0 .. num_locations) |i| {
        locations[i] = try reader.takeInt(u32, .little);
    }


    var cc_tree = try CallchainTree.init(arena);
    defer cc_tree.deinit();

    var loc_start: usize = 0;
    for (samples) |sample| {
        const location_ixs = locations[loc_start .. loc_start + sample.num_frames];
        try cc_tree.addCallchain(location_ixs);

        loc_start += sample.num_frames;
    }

    // TODO: Properly walk the tree
    var node = &cc_tree.node_list.items[0];
    while (true) {
        if (node.children.items().len == 0) {
            break;
        }
        node = &cc_tree.node_list.items[node.children.items()[0]];

        std.debug.print("{} - ", .{ node. inclusive_count });
        printLocation(location_table.items[node.loc_ix], string_table);
    }
}

pub fn main(init: std.process.Init) !void {
    var cwd = std.Io.Dir.cwd();
    var samples_bin = try cwd.openFile(init.io, "./samples.bin", .{});

    var buffer: [16 * 4096]u8 = undefined;
    var samples_reader = samples_bin.reader(init.io, &buffer);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    try readSamples(&samples_reader.interface, arena.allocator());
}

