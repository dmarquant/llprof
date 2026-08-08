const std = @import("std");
const linux = std.os.linux;


const PerfSampler = struct {
    cpu: u64,
    fd: std.posix.fd_t,
    buffer: []u8
};

pub fn main(init: std.process.Init) !void {
    var pipes: [2]i32 = undefined;
    _ = linux.pipe(&pipes); // TODO: Handle error

    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        std.debug.print("Failed to fork\n", .{});
        return;
    }
    const pid: i32 = @intCast(rc);

    if (pid == 0) {
        std.debug.print("Child!\n", .{});
        _ = linux.close(pipes[1]);

        var ch: [1]u8 = undefined;
        _ = linux.read(pipes[0], &ch, 1);
        _ = linux.close(pipes[0]);

        std.debug.print("Child ready to execute!\n", .{});

        var argv = try init.gpa.allocSentinel(?[*:0]const u8, 1, null);
        argv[0] = "./test";

        const env = try init.gpa.allocSentinel(?[*:0]const u8, 0, null);

        _ = linux.execve("./test", argv, env);
        return;
    } 

    std.debug.print("Forked at {}!\n", .{pid});

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

    for (samplers, 0..) |*sampler, cpu| {
        sampler.cpu = cpu;
        sampler.fd = try std.posix.perf_event_open(&perf_attr, pid, @intCast(cpu), -1, 0);
        sampler.buffer = try std.posix.mmap(null, 528384, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, sampler.fd, 0);
    }

    // Signal child to continue with execve
    _ = linux.close(pipes[1]);


    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, 0);

    // TODO: Get the actual page size
    // TODO: Consider actual ringbufer structure (modulo of size)
    // TODO: Use epoll or similar to wait for events
    // TODO: Configure watermark to get woken up
    for (samplers) |sampler| {
        const metadata = std.mem.bytesToValue(linux.perf_event_mmap_page, sampler.buffer[0 .. @sizeOf(linux.perf_event_mmap_page)]);

        std.debug.print("Have {} bytes of samples for CPU {}\n", .{ metadata.data_head - metadata.data_tail, sampler.cpu });

        const sampledata = sampler.buffer[4096 .. ];

        var tail = metadata.data_tail;
        while (tail < metadata.data_head) {
            const header = std.mem.bytesToValue(linux.perf_event_header, sampledata[tail .. tail + @sizeOf(linux.perf_event_header)]);
            const ip = std.mem.bytesToValue(u64, sampledata[tail + @sizeOf(linux.perf_event_header) .. tail + header.size]);

            std.debug.print("IP {x}\n", .{ ip });

            tail += header.size;
        }

    }

    std.debug.print("Child done: {}\n", .{status});
    
}
