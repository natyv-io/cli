#include "fixture.h"
#include <stdlib.h>

struct FixtureHandle {
    int value;
    FixtureCallback callback;
    void *user_data;
};

FixtureHandle *fixture_create(int initial) {
    FixtureHandle *h = malloc(sizeof(FixtureHandle));
    if (h == NULL) return NULL;
    h->value = initial;
    h->callback = NULL;
    h->user_data = NULL;
    return h;
}

void fixture_destroy(FixtureHandle *handle) {
    free(handle);
}

int fixture_ping(void) {
    return 42;
}

FixtureStatus fixture_get_point(FixtureHandle *handle, FixturePoint *out_point) {
    if (handle == NULL || out_point == NULL) return FIXTURE_ERROR;
    out_point->x = handle->value;
    out_point->y = handle->value * 2;
    return FIXTURE_OK;
}

void fixture_set_callback(FixtureHandle *handle, FixtureCallback cb, void *user_data) {
    if (handle == NULL) return;
    handle->callback = cb;
    handle->user_data = user_data;
}

void fixture_trigger(FixtureHandle *handle, int value) {
    if (handle == NULL || handle->callback == NULL) return;
    handle->callback(value, handle->user_data);
}

unsigned long fixture_checksum(unsigned long seed, const unsigned char *data, unsigned int len) {
    unsigned long sum = seed;
    for (unsigned int i = 0; i < len; i++) sum += data[i];
    return sum;
}

int fixture_pack(unsigned char *dest, unsigned long *dest_len, const unsigned char *source, unsigned long source_len) {
    if (*dest_len == 0) return -1;
    unsigned long n = source_len < *dest_len ? source_len : *dest_len;
    for (unsigned long i = 0; i < n; i++) dest[i] = (unsigned char)(source[i] * 2);
    *dest_len = n;
    return 0;
}
