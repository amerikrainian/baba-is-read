// Lua-facing exports. Each is loaded from Lua with package.loadlib(dll, name) and
// called as a plain Lua function; arguments and results go through luastack.h.
//
//   baba_version()                 -> integer
//   baba_selftest(s)               -> #s                       (layout check: strings)
//   baba_selftest2(s, n)           -> #s * 1000 + n            (layout check: multiple args, integers)
//   baba_speech_init()             -> boolean
//   baba_speak(text, interrupt)    -> boolean
//   baba_stop()                    -> boolean
//   baba_log(text)                 -> nothing
//   baba_keycap_install()          -> boolean
//   baba_capture(vk, mask)         -> nothing (mask: bit 1 << mods per captured modifier combination)
//   baba_poll_key()                -> packed event or 0
//   baba_pretend_focus(on)         -> nothing (keys are processed while the game is in the background)
//   baba_click(x, y, right, phase) -> boolean: a mouse click at client coordinates (phase 1 press, 2 release, 0 both)
//   baba_client_size()             -> width << 16 | height of the window's client area
//   baba_post_key(vk, down)        -> boolean: a synthetic key through the game window (the key help's game rows)
//   baba_dev_start(port)           -> boolean
//   baba_dev_poll()                -> pending command id or 0
//   baba_dev_reply(id, text)       -> nothing
#include "common.h"
#include "luastack.h"
#include <stdio.h>
#include <string.h>

char g_module_dir[MAX_PATH];
char g_game_root[MAX_PATH];
char g_data_dir[MAX_PATH];

#define EXPORT __declspec(dllexport)

EXPORT int baba_version(void *L) { ba_push_int(L, BA_VERSION); return 1; }

EXPORT int baba_selftest(void *L) {
    size_t len = 0;
    const char *s = ba_arg_string(L, 1, &len);
    ba_push_int(L, s ? (int64_t)len : -1);
    return 1;
}

EXPORT int baba_selftest2(void *L) {
    size_t len = 0;
    const char *s = ba_arg_string(L, 1, &len);
    int64_t n = ba_arg_int(L, 2, -1);
    if (!s || ba_nargs(L) != 2) { ba_push_int(L, -1); return 1; }
    ba_push_int(L, (int64_t)len * 1000 + n);
    return 1;
}

EXPORT int baba_speech_init(void *L) { ba_push_bool(L, ba_speech_ready()); return 1; }

EXPORT int baba_speak(void *L) {
    size_t len = 0;
    const char *s = ba_arg_string(L, 1, &len);
    int interrupt = (int)ba_arg_int(L, 2, 0);
    if (!s) { ba_push_bool(L, 0); return 1; }
    // Lua strings may contain embedded zeros or lack termination in principle; copy to be safe.
    char *copy = (char *)malloc(len + 1);
    if (!copy) { ba_push_bool(L, 0); return 1; }
    memcpy(copy, s, len); copy[len] = 0;
    int ok = ba_speech_output(copy, interrupt);
    free(copy);
    ba_push_bool(L, ok);
    return 1;
}

EXPORT int baba_stop(void *L) { ba_push_bool(L, ba_speech_stop()); return 1; }

EXPORT int baba_log(void *L) {
    size_t len = 0;
    const char *s = ba_arg_string(L, 1, &len);
    if (s) ba_logf("lua: %.*s", (int)len, s);
    return 0;
}

EXPORT int baba_keycap_install(void *L) { ba_push_bool(L, ba_keycap_install()); return 1; }

EXPORT int baba_capture(void *L) {
    ba_keycap_set((int)ba_arg_int(L, 1, 0), (int)ba_arg_int(L, 2, 0));
    return 0;
}

EXPORT int baba_pretend_focus(void *L) {
    ba_keycap_pretend_focus((int)ba_arg_int(L, 1, 0));
    return 0;
}

EXPORT int baba_click(void *L) {
    ba_push_bool(L, ba_keycap_click((int)ba_arg_int(L, 1, 0), (int)ba_arg_int(L, 2, 0), (int)ba_arg_int(L, 3, 0), (int)ba_arg_int(L, 4, 0)));
    return 1;
}

EXPORT int baba_client_size(void *L) { ba_push_int(L, ba_keycap_client_size()); return 1; }

EXPORT int baba_post_key(void *L) {
    ba_push_bool(L, ba_keycap_post((int)ba_arg_int(L, 1, 0), (int)ba_arg_int(L, 2, 1)));
    return 1;
}

EXPORT int baba_poll_key(void *L) { ba_push_int(L, ba_keycap_poll()); return 1; }

EXPORT int baba_dev_start(void *L) {
    int port = (int)ba_arg_int(L, 1, 8772);
    ba_push_bool(L, ba_dev_start(port));
    return 1;
}

EXPORT int baba_dev_poll(void *L) { ba_push_int(L, ba_dev_poll()); return 1; }

EXPORT int baba_dev_reply(void *L) {
    int id = (int)ba_arg_int(L, 1, 0);
    size_t len = 0;
    const char *s = ba_arg_string(L, 2, &len);
    if (id > 0) ba_dev_reply(id, s ? s : "", s ? len : 0);
    return 0;
}

static void strip_components(char *path, int n) {
    // Removes the last n path components from "...\a\b\c\" style paths, keeping the trailing backslash.
    size_t len = strlen(path);
    while (n > 0 && len > 0) {
        if (path[len - 1] == '\\') len--;
        while (len > 0 && path[len - 1] != '\\') len--;
        n--;
    }
    path[len] = 0;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(h);
        GetModuleFileNameA(h, g_module_dir, MAX_PATH);
        char *slash = strrchr(g_module_dir, '\\');
        if (slash) slash[1] = 0;
        // Deployed at <game>\Data\Lua\baba_access\bin\babaaccess.dll.
        strcpy(g_game_root, g_module_dir);
        strip_components(g_game_root, 4);
        char local[MAX_PATH];
        DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", local, MAX_PATH);
        if (n == 0 || n >= MAX_PATH) strcpy(local, g_game_root);
        snprintf(g_data_dir, MAX_PATH, "%s\\BabaAccess\\", local);
        CreateDirectoryA(g_data_dir, NULL);
        ba_log_init();
        ba_logf("bridge: attached, version %d, module %s, game root %s", BA_VERSION, g_module_dir, g_game_root);
    }
    return TRUE;
}
