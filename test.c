#include <stdint.h>
#include <stdio.h>

void super_slow_function(volatile uint64_t* count) {
  for (uint64_t i = 0; i < 100000000; i++) {
    *count += i;
  }
}

void slow_function(volatile uint64_t* count) {
  for (uint64_t i = 0; i < 10000000; i++) {
    *count += i;
  }
}

void doing_some_busy_work() {
  volatile uint64_t count = 0;
  for (uint64_t i = 0; i < 100; i++) {
    slow_function(&count);
    super_slow_function(&count);
    slow_function(&count);
  }
}

int main(int argc, char** argv) {
  // --- Simulated CPU-heavy workload to generate samples ---
  printf("Sampling IP... Running CPU workload...\n");

  doing_some_busy_work();
}
