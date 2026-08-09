const std = @import("std");
const linux = std.os.linux;

const procmaps = @import("procmaps.zig");


const PerfSampler = struct {
    cpu: u64,
    fd: std.posix.fd_t,
    page_size: usize,
    ring_buffer_size: usize,
    buffer: []u8
};

fn openPid(pid: i32) !std.posix.fd_t {
    const rc = linux.pidfd_open(pid, 0);
    if (linux.errno(rc) == .SUCCESS) {
        return @intCast(rc);
    } else {
        return error.PidfOpenFailed;
    }
}
    
var first = true;
var global_pid: i32 = 0;

fn writeSamples(sampler: PerfSampler, writer: *std.Io.Writer, io: std.Io, gpa: std.mem.Allocator) !void {
    var metadata = std.mem.bytesAsValue(linux.perf_event_mmap_page, sampler.buffer[0 .. @sizeOf(linux.perf_event_mmap_page)]);
    const sampledata = sampler.buffer[sampler.page_size .. ];

    std.debug.print("Woken up to write samples for CPU({}. {} bytes available\n", .{
        sampler.cpu,
        metadata.data_head - metadata.data_tail
    });

    var tail = metadata.data_tail;
    while (tail < metadata.data_head) {
        if (first) {
            // TODO: Remove this debug output
            // TODO: Attach region information to the samples
            first = false;
            var regions = try procmaps.readExecutableRegions(io, gpa, global_pid);
            defer regions.deinit(gpa);

            for (regions.regions) |*region| {
                std.debug.print("0x{x}-0x{x} mapped from {s}@{x}\n", .{ region.start, region.end, region.file_name, region.offset });
            }
        }
        const readp = tail % sampler.ring_buffer_size;
        const header = std.mem.bytesToValue(linux.perf_event_header, sampledata[readp .. readp + @sizeOf(linux.perf_event_header)]);
        const ip = std.mem.bytesToValue(u64, sampledata[readp + @sizeOf(linux.perf_event_header) .. readp + header.size]);

        try writer.print("{},0x{x}\n", .{ sampler.cpu, ip });

        tail += header.size;
    }
    // notify the kernel about that data was read
    metadata.data_tail = tail;
}

pub fn main(init: std.process.Init) !void {
    var pipes: [2]i32 = undefined;
    _ = linux.pipe(&pipes); // TODO: Handle error

    // TODO: Check the clone syscall. perf is using that
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        std.debug.print("Failed to fork\n", .{});
        return;
    }
    const pid: i32 = @intCast(rc);
    global_pid = pid;

    if (pid == 0) {
        std.debug.print("Child!\n", .{});
        _ = linux.close(pipes[1]);

        var ch: [1]u8 = undefined;
        _ = linux.read(pipes[0], &ch, 1);
        _ = linux.close(pipes[0]);

        std.debug.print("Child ready to execute!\n", .{});

        // TODO: Take this seriously ;)
        var argv = try init.gpa.allocSentinel(?[*:0]const u8, 1, null);
        argv[0] = "./test";

        const env = try init.gpa.allocSentinel(?[*:0]const u8, 0, null);

        _ = linux.execve("./test", argv, env);
        return;
    } 

    std.debug.print("Forked at {}!\n", .{pid});

    const childfd = try openPid(pid);

    _ = linux.close(pipes[0]);
    try init.io.sleep(std.Io.Duration.fromMilliseconds(200), .real);


    var perf_attr = linux.perf_event_attr{
        .type = .HARDWARE,
        .config = 0, // PERF_COUNT_HW_CPU_CYCLES
        .sample_period_or_freq = 4000,
        .sample_type = linux.PERF.SAMPLE.IP,

        .flags = .{
            .disabled = true,
            .inherit = true,
            .exclude_kernel = true,
            .exclude_hv = true,
            .freq = true,
            .precise_ip = 0, // TODO: Is 2 ok? :)
            .enable_on_exec = true,
        }
    };

    const numCpus = try std.Thread.getCpuCount();

    const samplers = try init.gpa.alloc(PerfSampler, numCpus);
    defer init.gpa.free(samplers);

    // TODO: Error checking
    const epoll_fd: i32 = @intCast(linux.epoll_create1(0));
    var epoll_event: linux.epoll_event = .{
        .events = linux.EPOLL.IN,
        .data = .{
            .fd = childfd
        }
    };
    _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, childfd, &epoll_event);

    const page_size = std.heap.pageSize();

    // Must be a power of 2 multiple of the page size
    const ring_buffer_size = page_size * 128;

    // One extra page is needed for the metadata (head, tail)
    const mmap_size = ring_buffer_size + page_size;

    for (samplers, 0..) |*sampler, cpu| {
        sampler.cpu = cpu;
        sampler.fd = try std.posix.perf_event_open(&perf_attr, pid, @intCast(cpu), -1, 0);
        sampler.buffer = try std.posix.mmap(null, mmap_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, sampler.fd, 0);
        sampler.page_size = page_size;
        sampler.ring_buffer_size = ring_buffer_size;

        var perf_epoll_event: linux.epoll_event = .{
            .events = linux.EPOLL.IN,
            .data = .{
                .fd = sampler.fd
            }
        };
        _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, sampler.fd, &perf_epoll_event);
    }


    var cwd = std.Io.Dir.cwd();
    var outFile = try cwd.createFile(init.io, "./samples.txt", .{});

    
    var outbuffer: [4096 * 4]u8 = undefined;
    var fwriter = outFile.writer(init.io, &outbuffer);
    var writer = &fwriter.interface;


    // Signal child to continue with execve
    _ = linux.close(pipes[1]);


    var events: [128]linux.epoll_event = undefined;
    outer: while (true) {
        const nfds = linux.epoll_wait(epoll_fd, &events, events.len, -1);

        for (0 .. nfds) |i| {
            if (events[i].data.fd == childfd) {
                std.debug.print("Process {} has terminated\n", .{pid});

                var buf: [4096]u8 = undefined;
                var stdin_reader = std.Io.File.stdin().reader(init.io, &buf);
                const r = &stdin_reader.interface;
                _ = try r.takeByte();

                break :outer;
            } else {
                // Before the process closes epoll triggers all of the events 
                // TODO: Find documentation for that
                for (samplers) |sampler| {
                    if (sampler.fd == events[i].data.fd) {
                        try writeSamples(sampler, writer, init.io, init.gpa);
                    }
                }
            }
        }
    }

    // TODO: Configure watermark to get woken up? Seems to do it automatically
    try writer.flush();
    outFile.close(init.io);    
}
