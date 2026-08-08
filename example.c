#define _GNU_SOURCE
#include <asm/unistd.h>
#include <linux/perf_event.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include <sched.h>

// Wrapper for perf_event_open syscall
static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

// Sample record format returned when PERF_SAMPLE_IP is set
struct perf_sample {
    struct perf_event_header header;
    uint64_t ip; // The instruction pointer captured by the kernel
};

typedef struct {
  int perffd;
  struct perf_event_mmap_page *buffer;
} perf_data;


int main() {
  int pipefd[2];
  if (pipe(pipefd) == -1) {
    perror("pipe");
    exit(EXIT_FAILURE);
  }

  pid_t pid = fork();
  if (pid < 0) {
    perror("Fork failed");
    exit(EXIT_FAILURE);
  } else if (pid == 0) {
    close(pipefd[1]); // close write end

    // Wait for the parent to setup tracing, then execute the program
    char ch;
    read(pipefd[0], &ch, 1);
    close(pipefd[0]);

    //char *args[] = {"ls", "-l", "/usr/bin", NULL};
    char *args[] = {"./test", NULL};
    execvp(args[0], args);

    // execvp ONLY returns if there was an error
    perror("execvp failed");
    exit(EXIT_FAILURE);
  } else {
    close(pipefd[0]); // Close read end

    cpu_set_t cpuset;
    sched_getaffinity(0, sizeof(cpuset), &cpuset);
    int ncpus = CPU_COUNT(&cpuset);
    
    printf("Found %d cpus\n", ncpus);

    // TODO: Designated initializer
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(struct perf_event_attr));
    pe.size = sizeof(struct perf_event_attr);

    // 1. Configure sampling parameters
    pe.type = PERF_TYPE_HARDWARE;
    pe.config = PERF_COUNT_HW_CPU_CYCLES; // Sample based on CPU cycles
    pe.sample_type = PERF_SAMPLE_IP;       // Request ONLY the Instruction Pointer
    pe.sample_freq = 4000;                 // Target 1,000 samples/sec
    pe.freq = 1;                           // Enable frequency mode
    pe.disabled = 1;                       // Start disabled until ready
    pe.exclude_kernel = 1;                 // Only capture user-space IPs
    pe.exclude_hv = 1;
    pe.inherit = 1;
    pe.mmap = 1;
    pe.mmap2 = 1;
    pe.precise_ip = 0; // TODO: Why can I not set '2' ?

    size_t page_size = sysconf(_SC_PAGESIZE);
    size_t mmap_size = 528384;

    perf_data ps[ncpus];
    for (int cpu = 0; cpu < ncpus; cpu++) {
      // 2. Open perf event for the current process (pid=0) on any CPU (cpu=-1)
      int fd = perf_event_open(&pe, pid, cpu, -1, 0);
      if (fd == -1) {
          perror("perf_event_open failed");
          exit(EXIT_FAILURE);
      }
      ps[cpu].perffd = fd;

      // 3. Map ring buffer: 1 metadata page + 2^n data pages (1 + 8 pages = 36 KiB)
      struct perf_event_mmap_page *metadata = mmap(NULL, mmap_size, 
                                                   PROT_READ | PROT_WRITE, 
                                                   MAP_SHARED, fd, 0);
      if (metadata == MAP_FAILED) {
          perror("mmap failed");
          close(fd);
          exit(EXIT_FAILURE);
      }
      ps[cpu].buffer = metadata;
    }


    for (int cpu = 0; cpu < ncpus; cpu++) {
      // 4. Enable counter sampling
      ioctl(ps[cpu].perffd, PERF_EVENT_IOC_RESET, 0);
      ioctl(ps[cpu].perffd, PERF_EVENT_IOC_ENABLE, 0);
    }

    // Signal the child by closing the pipe
    close(pipefd[1]);

    wait(NULL);

    for (int cpu = 0; cpu < ncpus; cpu++) {
      ioctl(ps[cpu].perffd, PERF_EVENT_IOC_DISABLE, 0);
    }

    FILE *out = fopen("ips.txt", "w");
    if (!out) {
        perror("fopen failed");
        exit(EXIT_FAILURE);
    }
      
    uint32_t sample_count = 0;

    // 5. Read captured samples from the ring buffer
    for (int cpu = 0; cpu < ncpus; cpu++) {
      struct perf_event_mmap_page* metadata = ps[cpu].buffer;

      unsigned char *data_boundary = (unsigned char *)metadata + page_size;
      uint64_t head = metadata->data_head;
      uint64_t tail = metadata->data_tail;
      size_t ring_size = page_size * 8;


      while (tail < head) {
          struct perf_event_header *header = (struct perf_event_header *)(data_boundary + (tail % ring_size));

          if (header->type == PERF_RECORD_SAMPLE) {
              struct perf_sample *sample = (struct perf_sample *)header;
              fprintf(out, "0x%lx\n", sample->ip);
              sample_count++;
          }

          tail += header->size; // Advance ring buffer read cursor
      }

      // Update metadata tail so kernel knows space was consumed
      metadata->data_tail = tail;
      munmap(metadata, mmap_size);
      
      close(ps[cpu].perffd);
    }

    printf("Done! Wrote %u IP samples to ips.txt\n", sample_count);

    fclose(out);
    return 0;
  }
}
