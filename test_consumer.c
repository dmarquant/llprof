#include <stdint.h>
#include <stdio.h>

struct SampleData {
    uint64_t time_ns;
    uint32_t cpu;
    uint32_t tid;
    uint32_t num_frames;
};

struct Samples {
  void* context;
  uint64_t num_samples;
  struct SampleData* samples;
  uint64_t num_locations;
  uint32_t* locations;
};

extern void* createContext();
extern struct Samples readSamples(void* context, const char* file_name);
extern void printLocation(struct Samples samples, uint32_t loc_ix);

int main() {
  void* context = createContext();
  struct Samples samples = readSamples(context, "./samples.bin");

  printf("Loaded %lu samples\n", samples.num_samples);

  int loci = 0;
  for (int i = 0; i < 20; i++) {
    struct SampleData sample = samples.samples[i];
    printf("\n%d: %u,%u - %luns\n", i, sample.cpu, sample.tid, sample.time_ns);

    for (int j = 0; j < sample.num_frames; j++) {
      printf("  ");
      fflush(stdout);
      printLocation(samples, samples.locations[loci]);
      loci ++;
    }
  }
}
