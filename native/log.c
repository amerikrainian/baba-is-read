// Session log: %LOCALAPPDATA%\BabaAccess\baba_access.log, truncated at DLL attach.
#include "common.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

static char g_log_path[MAX_PATH];
static CRITICAL_SECTION g_log_cs;
static int g_log_ready;

void ba_log_init(void) {
    if (g_log_ready) return;
    InitializeCriticalSection(&g_log_cs);
    snprintf(g_log_path, sizeof g_log_path, "%sbaba_access.log", g_data_dir);
    FILE *f = fopen(g_log_path, "w");
    if (f) fclose(f);
    g_log_ready = 1;
}

const char *ba_log_path(void) { return g_log_path; }

void ba_logf(const char *fmt, ...) {
    if (!g_log_ready) return;
    EnterCriticalSection(&g_log_cs);
    FILE *f = fopen(g_log_path, "a");
    if (f) {
        SYSTEMTIME t; GetLocalTime(&t);
        fprintf(f, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
        va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
        fputc('\n', f);
        fclose(f);
    }
    LeaveCriticalSection(&g_log_cs);
}
