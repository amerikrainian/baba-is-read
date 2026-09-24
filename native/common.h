// Shared declarations for the Baba Access native bridge.
#ifndef BA_COMMON_H
#define BA_COMMON_H

#include <windows.h>
#include <stdint.h>
#include <stddef.h>

#define BA_VERSION 1

// Paths (filled in at DLL attach).
extern char g_module_dir[MAX_PATH]; // directory holding babaaccess.dll, with trailing backslash
extern char g_game_root[MAX_PATH];  // the game's install directory, with trailing backslash
extern char g_data_dir[MAX_PATH];   // %LOCALAPPDATA%\BabaAccess\, with trailing backslash

// log.c
void ba_log_init(void);
void ba_logf(const char *fmt, ...);
const char *ba_log_path(void);

// speech.c
int ba_speech_ready(void);
int ba_speech_output(const char *text, int interrupt);
int ba_speech_stop(void);
// History of spoken lines for the dev server: fills buf with lines whose sequence
// number is greater than `since`, returns the latest sequence number.
uint64_t ba_speech_history(uint64_t since, char *buf, size_t cap);

// keycap.c
int ba_keycap_install(void);
void ba_keycap_set(int vk, int on);
int ba_keycap_get(int vk);
int ba_keycap_poll(void); // packed event or 0
int ba_keycap_post(int vk, int down); // synthetic key through the game window
HWND ba_keycap_hwnd(void);
void ba_keycap_stats(char *buf, size_t cap);
void ba_keycap_pretend_focus(int on);
int ba_keycap_pretend_focus_get(void);

// devserver.c
int ba_dev_start(int port);
int ba_dev_poll(void);                       // pending command id or 0
void ba_dev_reply(int id, const char *text, size_t len);

#endif
