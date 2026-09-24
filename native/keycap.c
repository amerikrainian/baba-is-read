// Key capture: take chosen virtual keys away from the engine and hand them to Lua.
//
// The engine sees the keyboard two ways, and both are covered:
//   1. Window messages (WM_KEYDOWN/WM_KEYUP) delivered to SDL's window procedure.
//      The game window is subclassed and captured keys are swallowed there.
//   2. Direct state polling (GetAsyncKeyState, GetKeyState, GetKeyboardState) and
//      raw input (GetRawInputData), reached through the executable's import table.
//      Those imports are redirected so captured keys read as released.
// Captured keys are queued; Lua drains the queue once per frame.
//
// The same hooks also provide synthetic keys for the dev server: a key marked
// "virtually held" is reported as pressed by the polled calls, and a message is
// posted so event-driven code sees it too. Counters per entry point show which
// path the engine actually uses (see ba_keycap_stats).
//
// Event packing (one integer): vk | mods << 8 | down << 12 | repeat << 13
//   mods: 1 = shift, 2 = control, 4 = alt
#include "common.h"
#include <stdio.h>
#include <string.h>

int ba_iat_hook(const char *dll_name, const char *func_name, void *replacement, void **original);

static HWND g_hwnd;
static WNDPROC g_orig_proc;
static unsigned char g_capture[256];
static unsigned char g_synth[256];       // virtually held keys (dev server)
static unsigned char g_engine_down[256]; // keys whose press reached the engine and is not yet released

#define QUEUE_CAP 128
static int g_queue[QUEUE_CAP];
static int g_qhead, g_qtail;
static CRITICAL_SECTION g_qcs;
static int g_qinit;

// Call counters for the diagnostic.
static volatile LONG g_calls_async, g_calls_keystate, g_calls_kbstate, g_calls_rawinput, g_calls_wndproc_keys;

static void queue_init(void) {
    if (!g_qinit) { InitializeCriticalSection(&g_qcs); g_qinit = 1; }
}

static void queue_push(int ev) {
    queue_init();
    EnterCriticalSection(&g_qcs);
    int next = (g_qtail + 1) % QUEUE_CAP;
    if (next != g_qhead) { g_queue[g_qtail] = ev; g_qtail = next; }
    LeaveCriticalSection(&g_qcs);
}

int ba_keycap_poll(void) {
    queue_init();
    EnterCriticalSection(&g_qcs);
    int ev = 0;
    if (g_qhead != g_qtail) { ev = g_queue[g_qhead]; g_qhead = (g_qhead + 1) % QUEUE_CAP; }
    LeaveCriticalSection(&g_qcs);
    return ev;
}

// ---- Polled state hooks ----
typedef SHORT (WINAPI *GetAsyncKeyState_t)(int);
typedef SHORT (WINAPI *GetKeyState_t)(int);
typedef BOOL (WINAPI *GetKeyboardState_t)(PBYTE);
typedef UINT (WINAPI *GetRawInputData_t)(HRAWINPUT, UINT, LPVOID, PUINT, UINT);
static GetAsyncKeyState_t o_GetAsyncKeyState;
static GetKeyState_t o_GetKeyState;
static GetKeyboardState_t o_GetKeyboardState;
static GetRawInputData_t o_GetRawInputData;

static int masked(int vk) { return vk >= 0 && vk < 256 && g_capture[vk]; }
static int synth(int vk) { return vk >= 0 && vk < 256 && g_synth[vk]; }

static SHORT WINAPI h_GetAsyncKeyState(int vk) {
    InterlockedIncrement(&g_calls_async);
    if (synth(vk)) return (SHORT)0x8001;
    if (masked(vk)) return 0;
    return o_GetAsyncKeyState(vk);
}

static SHORT WINAPI h_GetKeyState(int vk) {
    InterlockedIncrement(&g_calls_keystate);
    if (synth(vk)) return (SHORT)0x8001;
    if (masked(vk)) return 0;
    return o_GetKeyState(vk);
}

static BOOL WINAPI h_GetKeyboardState(PBYTE state) {
    InterlockedIncrement(&g_calls_kbstate);
    BOOL r = o_GetKeyboardState(state);
    if (r && state) {
        for (int vk = 0; vk < 256; vk++) {
            if (g_synth[vk]) state[vk] |= 0x80;
            else if (g_capture[vk]) state[vk] &= (BYTE)~0x80;
        }
    }
    return r;
}

static UINT WINAPI h_GetRawInputData(HRAWINPUT h, UINT cmd, LPVOID data, PUINT size, UINT header) {
    UINT r = o_GetRawInputData(h, cmd, data, size, header);
    if (cmd == RID_INPUT && data && r != (UINT)-1 && r >= sizeof(RAWINPUTHEADER)) {
        RAWINPUT *ri = (RAWINPUT *)data;
        if (ri->header.dwType == RIM_TYPEKEYBOARD) {
            InterlockedIncrement(&g_calls_rawinput);
            int vk = ri->data.keyboard.VKey;
            if (masked(vk)) {
                // Turn the event into a release of an unused key so the engine ignores it.
                ri->data.keyboard.VKey = 0xFF;
                ri->data.keyboard.MakeCode = 0;
                ri->data.keyboard.Flags |= RI_KEY_BREAK;
            }
        }
    }
    return r;
}

// ---- Focus ----
// SDL only delivers keyboard events to the engine while it believes the window
// has focus, and it decides that by asking Windows for the foreground window.
// With pretend-focus on, that question is answered with the game window, so
// synthetic keys are processed while the player is in another application, and
// nothing ever moves the real focus.
typedef HWND (WINAPI *GetForegroundWindow_t)(void);
typedef HWND (WINAPI *GetFocus_t)(void);
static GetForegroundWindow_t o_GetForegroundWindow;
static GetFocus_t o_GetFocus;
static int g_pretend_focus;

static HWND WINAPI h_GetForegroundWindow(void) {
    if (g_pretend_focus && g_hwnd) return g_hwnd;
    return o_GetForegroundWindow();
}

static HWND WINAPI h_GetFocus(void) {
    if (g_pretend_focus && g_hwnd) return g_hwnd;
    return o_GetFocus();
}

void ba_keycap_pretend_focus(int on) {
    g_pretend_focus = on ? 1 : 0;
    if (on && g_hwnd) {
        // Let SDL re-evaluate focus now that the answer has changed.
        PostMessageW(g_hwnd, WM_SETFOCUS, 0, 0);
    }
    ba_logf("keycap: pretend focus %s", on ? "on" : "off");
}

int ba_keycap_pretend_focus_get(void) { return g_pretend_focus; }

static void install_state_hooks(void) {
    static int done;
    if (done) return;
    done = 1;
    int a = ba_iat_hook("USER32.dll", "GetAsyncKeyState", (void *)h_GetAsyncKeyState, (void **)&o_GetAsyncKeyState);
    int k = ba_iat_hook("USER32.dll", "GetKeyState", (void *)h_GetKeyState, (void **)&o_GetKeyState);
    int s = ba_iat_hook("USER32.dll", "GetKeyboardState", (void *)h_GetKeyboardState, (void **)&o_GetKeyboardState);
    int r = ba_iat_hook("USER32.dll", "GetRawInputData", (void *)h_GetRawInputData, (void **)&o_GetRawInputData);
    int f = ba_iat_hook("USER32.dll", "GetForegroundWindow", (void *)h_GetForegroundWindow, (void **)&o_GetForegroundWindow);
    int g = ba_iat_hook("USER32.dll", "GetFocus", (void *)h_GetFocus, (void **)&o_GetFocus);
    ba_logf("keycap: import hooks GetAsyncKeyState=%d GetKeyState=%d GetKeyboardState=%d GetRawInputData=%d GetForegroundWindow=%d GetFocus=%d", a, k, s, r, f, g);
}

// ---- Window subclass ----
static int current_mods(void) {
    int m = 0;
    if (o_GetKeyState ? (o_GetKeyState(VK_SHIFT) & 0x8000) : (GetKeyState(VK_SHIFT) & 0x8000)) m |= 1;
    if (o_GetKeyState ? (o_GetKeyState(VK_CONTROL) & 0x8000) : (GetKeyState(VK_CONTROL) & 0x8000)) m |= 2;
    if (o_GetKeyState ? (o_GetKeyState(VK_MENU) & 0x8000) : (GetKeyState(VK_MENU) & 0x8000)) m |= 4;
    return m;
}

// On a real focus loss SDL would reset its keyboard state; with pretend-focus it
// never learns of the loss, so the keys it saw pressed are released here. This
// is what keeps an alt-tab from leaving Alt held inside the game.
static void release_engine_keys(void) {
    if (!g_hwnd) return;
    for (int vk = 1; vk < 256; vk++) {
        if (g_engine_down[vk]) {
            UINT scan = MapVirtualKeyW((UINT)vk, MAPVK_VK_TO_VSC);
            LPARAM lp = 1 | ((LPARAM)(scan & 0xff) << 16) | ((LPARAM)1 << 30) | ((LPARAM)1 << 31);
            PostMessageW(g_hwnd, (vk == VK_MENU) ? WM_SYSKEYUP : WM_KEYUP, (WPARAM)vk, lp);
        }
    }
}

static LRESULT CALLBACK ba_wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_KEYDOWN: case WM_SYSKEYDOWN: case WM_KEYUP: case WM_SYSKEYUP: {
        InterlockedIncrement(&g_calls_wndproc_keys);
        int vk = (int)(wp & 0xff);
        int down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) ? 1 : 0;
        if (g_capture[vk]) {
            int repeat = down && (lp & (1 << 30)) ? 1 : 0;
            queue_push(vk | (current_mods() << 8) | (down << 12) | (repeat << 13));
            // A release must reach the engine if it saw the press, or its key state sticks.
            if (!down && g_engine_down[vk]) { g_engine_down[vk] = 0; break; }
            return 0; // swallowed: the game never sees it
        }
        g_engine_down[vk] = (unsigned char)down;
        break;
    }
    case WM_KILLFOCUS:
        release_engine_keys();
        break;
    case WM_ACTIVATE:
        if (LOWORD(wp) == WA_INACTIVE) release_engine_keys();
        break;
    case WM_ACTIVATEAPP:
        if (!wp) release_engine_keys();
        break;
    case WM_NCDESTROY:
        g_hwnd = NULL;
        break;
    }
    return CallWindowProcW(g_orig_proc, hwnd, msg, wp, lp);
}

static BOOL CALLBACK find_window(HWND hwnd, LPARAM lp) {
    if (!IsWindowVisible(hwnd)) return TRUE;
    if (GetWindow(hwnd, GW_OWNER) != NULL) return TRUE;
    wchar_t title[64];
    if (GetWindowTextW(hwnd, title, 64) <= 0) return TRUE;
    *(HWND *)lp = hwnd;
    return FALSE;
}

int ba_keycap_install(void) {
    if (g_hwnd) return 1;
    HWND found = NULL;
    EnumThreadWindows(GetCurrentThreadId(), find_window, (LPARAM)&found);
    if (!found) { ba_logf("keycap: no visible top-level window on this thread"); return 0; }
    g_orig_proc = (WNDPROC)SetWindowLongPtrW(found, GWLP_WNDPROC, (LONG_PTR)ba_wndproc);
    if (!g_orig_proc) { ba_logf("keycap: SetWindowLongPtr failed: %lu", GetLastError()); return 0; }
    g_hwnd = found;
    install_state_hooks();
    wchar_t title[128]; GetWindowTextW(found, title, 128);
    ba_logf("keycap: subclassed window %p '%ls'", (void *)found, title);
    return 1;
}

HWND ba_keycap_hwnd(void) { return g_hwnd; }

void ba_keycap_set(int vk, int on) {
    if (vk < 1 || vk > 255) return;
    g_capture[vk] = on ? 1 : 0;
    // Taking a key the engine currently holds: release it there first.
    if (on && g_engine_down[vk] && g_hwnd) ba_keycap_post(vk, 0);
}

int ba_keycap_get(int vk) {
    if (vk < 1 || vk > 255) return 0;
    return g_capture[vk];
}

static int is_extended(int vk) {
    switch (vk) {
    case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN:
    case VK_INSERT: case VK_DELETE: case VK_HOME: case VK_END: case VK_PRIOR: case VK_NEXT:
    case VK_RCONTROL: case VK_RMENU: case VK_DIVIDE: case VK_NUMLOCK: case VK_SNAPSHOT:
        return 1;
    }
    return 0;
}

// Synthetic key: marks the key virtually held (for polled state) and posts the
// matching message (for event-driven code). Safe to call from any thread.
int ba_keycap_post(int vk, int down) {
    if (!g_hwnd || vk < 1 || vk > 255) return 0;
    g_synth[vk] = down ? 1 : 0;
    UINT scan = MapVirtualKeyW((UINT)vk, MAPVK_VK_TO_VSC);
    LPARAM lp = 1 | ((LPARAM)(scan & 0xff) << 16);
    if (is_extended(vk)) lp |= (LPARAM)1 << 24;
    if (!down) lp |= ((LPARAM)1 << 30) | ((LPARAM)1 << 31);
    return PostMessageW(g_hwnd, down ? WM_KEYDOWN : WM_KEYUP, (WPARAM)vk, lp) ? 1 : 0;
}

// One line of diagnostics: how often each keyboard path has been used.
void ba_keycap_stats(char *buf, size_t cap) {
    int n = snprintf(buf, cap, "wndproc_keys=%ld GetAsyncKeyState=%ld GetKeyState=%ld GetKeyboardState=%ld rawinput_keyboard=%ld foreground=%d pretend_focus=%d engine_down=",
        g_calls_wndproc_keys, g_calls_async, g_calls_keystate, g_calls_kbstate, g_calls_rawinput,
        (o_GetForegroundWindow ? o_GetForegroundWindow() : GetForegroundWindow()) == g_hwnd, g_pretend_focus);
    for (int vk = 1; vk < 256 && n > 0 && (size_t)n + 8 < cap; vk++)
        if (g_engine_down[vk]) n += snprintf(buf + n, cap - (size_t)n, "%d,", vk);
}
