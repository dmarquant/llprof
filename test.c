#include <stdint.h>
#include <stdio.h>

void doing_some_busy_work() {
  volatile uint64_t count = 0;
  for (uint64_t i = 0; i < 10000000000; i++) {
    count += i;
  }
}

int main(int argc, char** argv) {
  // --- Simulated CPU-heavy workload to generate samples ---
  printf("Sampling IP... Running CPU workload...\n");

  doing_some_busy_work();
}
