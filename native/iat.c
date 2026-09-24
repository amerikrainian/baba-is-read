// Import-table hooking for the game executable.
//
// The engine statically links SDL, so every keyboard-state call it makes goes
// through the main module's import table. Redirecting an entry there changes
// what the whole engine sees without patching code.
#include "common.h"
#include <string.h>

int ba_iat_hook(const char *dll_name, const char *func_name, void *replacement, void **original) {
    HMODULE exe = GetModuleHandleA(NULL);
    unsigned char *base = (unsigned char *)exe;
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!dir.VirtualAddress) return 0;
    IMAGE_IMPORT_DESCRIPTOR *imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress);
    for (; imp->Name; imp++) {
        const char *name = (const char *)(base + imp->Name);
        if (_stricmp(name, dll_name) != 0) continue;
        IMAGE_THUNK_DATA *orig_thunk = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
        IMAGE_THUNK_DATA *thunk = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; orig_thunk->u1.AddressOfData; orig_thunk++, thunk++) {
            if (orig_thunk->u1.Ordinal & IMAGE_ORDINAL_FLAG) continue;
            IMAGE_IMPORT_BY_NAME *by_name = (IMAGE_IMPORT_BY_NAME *)(base + orig_thunk->u1.AddressOfData);
            if (strcmp((const char *)by_name->Name, func_name) != 0) continue;
            DWORD old;
            if (!VirtualProtect(&thunk->u1.Function, sizeof(thunk->u1.Function), PAGE_READWRITE, &old)) return 0;
            if (original) *original = (void *)thunk->u1.Function;
            thunk->u1.Function = (ULONGLONG)replacement;
            VirtualProtect(&thunk->u1.Function, sizeof(thunk->u1.Function), old, &old);
            return 1;
        }
    }
    return 0;
}
