// Development HTTP server on 127.0.0.1, mirroring guildrun's dev server.
//
//   GET  /health              -> "ok"
//   POST /eval[?timeout=MS]   -> runs the body as a Lua chunk in the game, returns its result
//   GET  /speech?since=N      -> spoken lines after sequence N ("cursor: N" first)
//   GET  /log?tail=N          -> last N lines of the session log
//   POST /key                 -> body lines "VK down|up|press": synthetic keys through the game window
//   GET  /keys                -> the captured virtual-key set
//
// /eval works through a command file: the chunk is written to
// Data/Lua/baba_access/cmd/<id>.lua, the Lua side polls baba_dev_poll() each frame,
// runs the file, and answers with baba_dev_reply(id, text).
#include <winsock2.h>
#include <ws2tcpip.h>
#include "common.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_port;
static HANDLE g_thread;

// Command channel state.
static CRITICAL_SECTION g_cmd_cs;
static HANDLE g_cmd_event;    // signalled when a reply arrives
static HANDLE g_cmd_mutex;    // serializes /eval requests
static volatile int g_cmd_pending; // id the Lua side has not picked up yet
static volatile int g_cmd_waiting; // id the server is waiting a reply for
static char *g_cmd_reply;
static size_t g_cmd_reply_len;

int ba_dev_poll(void) {
    EnterCriticalSection(&g_cmd_cs);
    int id = g_cmd_pending;
    g_cmd_pending = 0;
    LeaveCriticalSection(&g_cmd_cs);
    return id;
}

void ba_dev_reply(int id, const char *text, size_t len) {
    EnterCriticalSection(&g_cmd_cs);
    if (id == g_cmd_waiting) {
        free(g_cmd_reply);
        g_cmd_reply = (char *)malloc(len + 1);
        if (g_cmd_reply) { memcpy(g_cmd_reply, text, len); g_cmd_reply[len] = 0; g_cmd_reply_len = len; }
        else g_cmd_reply_len = 0;
        SetEvent(g_cmd_event);
    } else {
        ba_logf("dev: reply for stale command %d ignored", id);
    }
    LeaveCriticalSection(&g_cmd_cs);
}

static void send_all(SOCKET s, const char *p, size_t n) {
    while (n > 0) {
        int k = send(s, p, (int)n, 0);
        if (k <= 0) return;
        p += k; n -= (size_t)k;
    }
}

static void respond(SOCKET s, int status, const char *body, size_t len) {
    char head[256];
    const char *reason = status == 200 ? "OK" : status == 404 ? "Not Found" : status == 504 ? "Gateway Timeout" : "Bad Request";
    int n = snprintf(head, sizeof head,
        "HTTP/1.1 %d %s\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",
        status, reason, len);
    send_all(s, head, (size_t)n);
    send_all(s, body, len);
}

static long query_int(const char *path, const char *name, long def) {
    const char *q = strchr(path, '?');
    if (!q) return def;
    size_t nl = strlen(name);
    const char *p = q + 1;
    while (*p) {
        if (strncmp(p, name, nl) == 0 && p[nl] == '=') return atol(p + nl + 1);
        p = strchr(p, '&');
        if (!p) break;
        p++;
    }
    return def;
}

static void handle_eval(SOCKET s, const char *path, const char *body, size_t blen) {
    long timeout = query_int(path, "timeout", 10000);
    if (WaitForSingleObject(g_cmd_mutex, (DWORD)timeout) != WAIT_OBJECT_0) { respond(s, 504, "busy", 4); return; }
    static int counter;
    int id = ++counter;
    char dir[MAX_PATH], file[MAX_PATH];
    snprintf(dir, sizeof dir, "%sData\\Lua\\baba_access\\cmd", g_game_root);
    CreateDirectoryA(dir, NULL);
    snprintf(file, sizeof file, "%s\\%d.lua", dir, id);
    FILE *f = fopen(file, "wb");
    if (!f) { ReleaseMutex(g_cmd_mutex); respond(s, 400, "cannot write command file", 25); return; }
    fwrite(body, 1, blen, f);
    fclose(f);

    EnterCriticalSection(&g_cmd_cs);
    ResetEvent(g_cmd_event);
    g_cmd_waiting = id;
    g_cmd_pending = id;
    LeaveCriticalSection(&g_cmd_cs);

    DWORD w = WaitForSingleObject(g_cmd_event, (DWORD)timeout);
    EnterCriticalSection(&g_cmd_cs);
    g_cmd_waiting = 0;
    g_cmd_pending = 0;
    char *reply = g_cmd_reply; size_t rlen = g_cmd_reply_len;
    g_cmd_reply = NULL; g_cmd_reply_len = 0;
    LeaveCriticalSection(&g_cmd_cs);
    DeleteFileA(file);
    ReleaseMutex(g_cmd_mutex);

    if (w != WAIT_OBJECT_0 || !reply) { respond(s, 504, "no reply from Lua (is the game past loading, and is the mod ticking?)", 68); free(reply); return; }
    respond(s, 200, reply, rlen);
    free(reply);
}

static void handle_speech(SOCKET s, const char *path) {
    long since = query_int(path, "since", 0);
    size_t cap = 256 * 600;
    char *lines = (char *)malloc(cap);
    char *out = (char *)malloc(cap + 64);
    if (!lines || !out) { free(lines); free(out); respond(s, 400, "oom", 3); return; }
    lines[0] = 0;
    uint64_t latest = ba_speech_history((uint64_t)since, lines, cap);
    int n = snprintf(out, cap + 64, "cursor: %llu\n%s", (unsigned long long)latest, lines);
    respond(s, 200, out, (size_t)n);
    free(lines);
    free(out);
}

static void handle_log(SOCKET s, const char *path) {
    long tail = query_int(path, "tail", 50);
    FILE *f = fopen(ba_log_path(), "rb");
    if (!f) { respond(s, 200, "", 0); return; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    long want = 64 * 1024;
    long start = size > want ? size - want : 0;
    fseek(f, start, SEEK_SET);
    char *buf = (char *)malloc((size_t)(size - start) + 1);
    if (!buf) { fclose(f); respond(s, 400, "oom", 3); return; }
    size_t got = fread(buf, 1, (size_t)(size - start), f);
    buf[got] = 0;
    fclose(f);
    // Keep only the last `tail` lines.
    long lines = 0; const char *p = buf + got;
    while (p > buf && lines <= tail) { p--; if (*p == '\n') lines++; }
    if (lines > tail) p++;
    respond(s, 200, p, strlen(p));
    free(buf);
}

static void handle_key(SOCKET s, const char *body) {
    char copy[1024];
    strncpy(copy, body, sizeof copy - 1); copy[sizeof copy - 1] = 0;
    int count = 0;
    char *save = NULL;
    for (char *line = strtok_s(copy, "\r\n", &save); line; line = strtok_s(NULL, "\r\n", &save)) {
        int vk = atoi(line);
        const char *how = strchr(line, ' ');
        how = how ? how + 1 : "press";
        if (vk < 1 || vk > 255) continue;
        if (strncmp(how, "down", 4) == 0) count += ba_keycap_post(vk, 1);
        else if (strncmp(how, "up", 2) == 0) count += ba_keycap_post(vk, 0);
        else { count += ba_keycap_post(vk, 1); Sleep(30); count += ba_keycap_post(vk, 0); }
    }
    char out[32]; int n = snprintf(out, sizeof out, "posted %d", count);
    respond(s, 200, out, (size_t)n);
}

static void handle_keys(SOCKET s) {
    char out[1024]; size_t used = 0;
    ba_keycap_stats(out, sizeof out);
    used = strlen(out);
    out[used++] = 10;
    for (int vk = 1; vk < 256 && used + 8 < sizeof out; vk++)
        if (ba_keycap_get(vk)) used += (size_t)snprintf(out + used, sizeof out - used, "%d %d\n", vk, ba_keycap_get(vk));
    respond(s, 200, out, used);
}

static void handle_client(SOCKET s) {
    char *req = (char *)malloc(1 << 20);
    if (!req) { closesocket(s); return; }
    size_t got = 0; size_t cap = 1 << 20;
    char *hdr_end = NULL;
    while (got < cap - 1) {
        int k = recv(s, req + got, (int)(cap - 1 - got), 0);
        if (k <= 0) break;
        got += (size_t)k; req[got] = 0;
        hdr_end = strstr(req, "\r\n\r\n");
        if (hdr_end) {
            size_t clen = 0;
            const char *cl = strstr(req, "Content-Length:");
            if (cl && cl < hdr_end) clen = (size_t)atol(cl + 15);
            size_t have = got - (size_t)(hdr_end + 4 - req);
            if (have >= clen) break;
        }
    }
    if (!hdr_end) { free(req); closesocket(s); return; }
    char method[8] = {0}, path[512] = {0};
    sscanf(req, "%7s %511s", method, path);
    const char *body = hdr_end + 4;
    size_t blen = got - (size_t)(body - req);

    if (strncmp(path, "/health", 7) == 0 || strcmp(path, "/") == 0) respond(s, 200, "ok", 2);
    else if (strncmp(path, "/eval", 5) == 0) handle_eval(s, path, body, blen);
    else if (strncmp(path, "/speech", 7) == 0) handle_speech(s, path);
    else if (strncmp(path, "/log", 4) == 0) handle_log(s, path);
    else if (strncmp(path, "/keys", 5) == 0) handle_keys(s);
    else if (strncmp(path, "/key", 4) == 0) handle_key(s, body);
    else respond(s, 404, "no such route", 13);
    shutdown(s, SD_SEND);
    closesocket(s);
    free(req);
}

static DWORD WINAPI server_thread(LPVOID arg) {
    (void)arg;
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { ba_logf("dev: WSAStartup failed"); return 1; }
    SOCKET ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ls == INVALID_SOCKET) { ba_logf("dev: socket failed"); return 1; }
    BOOL yes = TRUE;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof yes);
    struct sockaddr_in addr; memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)g_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ls, (struct sockaddr *)&addr, sizeof addr) != 0) { ba_logf("dev: bind to port %d failed: %d", g_port, WSAGetLastError()); return 1; }
    if (listen(ls, 8) != 0) { ba_logf("dev: listen failed"); return 1; }
    ba_logf("dev: listening on http://127.0.0.1:%d", g_port);
    for (;;) {
        SOCKET c = accept(ls, NULL, NULL);
        if (c == INVALID_SOCKET) continue;
        DWORD to = 30000;
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, (const char *)&to, sizeof to);
        handle_client(c);
    }
    return 0;
}

int ba_dev_start(int port) {
    if (g_thread) return 1;
    InitializeCriticalSection(&g_cmd_cs);
    g_cmd_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    g_cmd_mutex = CreateMutexW(NULL, FALSE, NULL);
    g_port = port;
    g_thread = CreateThread(NULL, 0, server_thread, NULL, 0, NULL);
    return g_thread != NULL;
}
