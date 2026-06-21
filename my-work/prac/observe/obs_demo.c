#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((noinline))
static uint64_t busy_loop(unsigned long rounds)
{
    uint64_t x = 0;

    for (unsigned long i = 0; i < rounds; i++) {
        x += (i * 2654435761UL) ^ (x >> 3);
    }

    return x;
}

__attribute__((noinline))
int target_func(int value)
{
    printf("target_func(%d)\n", value);
    return value * 2 + 1;
}

int main(int argc, char **argv)
{
    int loops = 5;

    if (argc > 1)
        loops = atoi(argv[1]);

    printf("obs_demo pid=%d loops=%d\n", getpid(), loops);

    for (int i = 0; i < loops; i++) {
        uint64_t r = busy_loop(20000000UL);
        int y = target_func(i);
        printf("round=%d busy=%llu result=%d\n",
               i, (unsigned long long)r, y);
        usleep(200000);
    }

    return 0;
}
