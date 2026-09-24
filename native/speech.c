// Speech through Prism (prism.dll next to this DLL), loaded on first use.
#include "common.h"
#include <stdio.h>
#include <string.h>

typedef struct { uint8_t version; } PrismConfig;
typedef void *(*prism_init_t)(PrismConfig *);
typedef void *(*prism_registry_create_best_t)(void *);
typedef int (*prism_backend_initialize_t)(void *);
typedef int (*prism_backend_output_t)(void *, const char *, int);
typedef int (*prism_backend_stop_t)(void *);
typedef const char *(*prism_backend_name_t)(void *);

static void *g_backend;
static prism_backend_output_t g_output;
static prism_backend_stop_t g_stop;
static int g_tried;

// History ring for the dev server.
#define HIST_LINES 256
#define HIST_LINE_CAP 512
static char g_hist[HIST_LINES][HIST_LINE_CAP];
static uint64_t g_hist_seq; // sequence number of the latest line (0 = none)
static CRITICAL_SECTION g_hist_cs;
static int g_hist_init;

static int prism_setup(void) {
    if (g_tried) return g_backend != NULL;
    g_tried = 1;
    char path[MAX_PATH];
    snprintf(path, sizeof path, "%sprism.dll", g_module_dir);
    HMODULE h = LoadLibraryA(path);
    if (!h) { ba_logf("speech: LoadLibrary(%s) failed: %lu", path, GetLastError()); return 0; }
    prism_init_t init = (prism_init_t)(void *)GetProcAddress(h, "prism_init");
    prism_registry_create_best_t best = (prism_registry_create_best_t)(void *)GetProcAddress(h, "prism_registry_create_best");
    prism_backend_initialize_t binit = (prism_backend_initialize_t)(void *)GetProcAddress(h, "prism_backend_initialize");
    prism_backend_name_t bname = (prism_backend_name_t)(void *)GetProcAddress(h, "prism_backend_name");
    g_output = (prism_backend_output_t)(void *)GetProcAddress(h, "prism_backend_output");
    g_stop = (prism_backend_stop_t)(void *)GetProcAddress(h, "prism_backend_stop");
    if (!init || !best || !binit || !g_output || !g_stop) { ba_logf("speech: prism.dll is missing exports"); return 0; }
    void *ctx = init(NULL);
    if (!ctx) { ba_logf("speech: prism_init returned NULL"); return 0; }
    g_backend = best(ctx);
    if (!g_backend) { ba_logf("speech: no usable backend (is a screen reader running?)"); return 0; }
    int err = binit(g_backend); // create_best already initialized it; AlreadyInitialized is fine
    ba_logf("speech: backend '%s' ready (initialize -> %d)", bname ? bname(g_backend) : "?", err);
    return 1;
}

static void hist_add(const char *text, int interrupt) {
    if (!g_hist_init) { InitializeCriticalSection(&g_hist_cs); g_hist_init = 1; }
    EnterCriticalSection(&g_hist_cs);
    g_hist_seq++;
    char *slot = g_hist[g_hist_seq % HIST_LINES];
    snprintf(slot, HIST_LINE_CAP, "[%s] %s", interrupt ? "interrupt" : "queue", text);
    LeaveCriticalSection(&g_hist_cs);
}

int ba_speech_ready(void) { return prism_setup(); }

int ba_speech_output(const char *text, int interrupt) {
    hist_add(text, interrupt);
    ba_logf("speech%s: %s", interrupt ? "!" : "", text);
    if (!prism_setup()) return 0;
    int err = g_output(g_backend, text, interrupt ? 1 : 0);
    if (err != 0) ba_logf("speech: output error %d", err);
    return err == 0;
}

int ba_speech_stop(void) {
    if (!prism_setup()) return 0;
    return g_stop(g_backend) == 0;
}

uint64_t ba_speech_history(uint64_t since, char *buf, size_t cap) {
    if (!g_hist_init) { InitializeCriticalSection(&g_hist_cs); g_hist_init = 1; }
    EnterCriticalSection(&g_hist_cs);
    size_t used = 0;
    uint64_t first = since + 1;
    if (g_hist_seq >= HIST_LINES && first < g_hist_seq - HIST_LINES + 1) first = g_hist_seq - HIST_LINES + 1;
    for (uint64_t s = first; s <= g_hist_seq && used + 2 < cap; s++) {
        int n = snprintf(buf + used, cap - used, "%llu %s\n", (unsigned long long)s, g_hist[s % HIST_LINES]);
        if (n < 0 || used + (size_t)n >= cap) break;
        used += (size_t)n;
    }
    uint64_t latest = g_hist_seq;
    LeaveCriticalSection(&g_hist_cs);
    return latest;
}
