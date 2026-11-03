// Обычная библиотека с экспортируемыми функциями (их можно вызвать из другого кода через dlsym)
#include <stdio.h>
#include <string.h>

__attribute__((visibility("default")))
int gx_add(int a, int b) { return a + b; }

__attribute__((visibility("default")))
double gx_average(const double *v, int n) {
    double s = 0;
    for (int i = 0; i < n; i++) s += v[i];
    return n ? s / n : 0;
}

__attribute__((visibility("default")))
const char *gx_version(void) { return "1.0"; }
