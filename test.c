#include <stdint.h>
#include <stdio.h>


int main(int argc, char** argv) {
  // --- Simulated CPU-heavy workload to generate samples ---
  printf("Sampling IP... Running CPU workload...\n");
  volatile uint64_t count = 0;
  for (uint64_t i = 0; i < 5000000000; i++) {
    count += i;
  }
}
