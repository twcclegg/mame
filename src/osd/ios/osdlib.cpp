// license:BSD-3-Clause
// copyright-holders:Olivier Galibert, R. Belmont
//============================================================
//
//  osdlib - OS specific low level code, for iOS
//
//  SDLMAME by Olivier Galibert and R. Belmont
//
//============================================================

#include <stdlib.h>
#include <sys/types.h>
#include <signal.h>
#include <time.h>

#include <dlfcn.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>

// MAME headers
#include "modules/lib/osdlib.h"
#include "osdcomm.h"
#include "osdcore.h"
#include "strconv.h"

//============================================================
//  osd_getenv
//============================================================

const char *osd_getenv(const char *name)
{
    return getenv(name);
}

//============================================================
//  osd_setenv
//============================================================

int osd_setenv(const char *name, const char *value, int overwrite)
{
   return setenv(name, value, overwrite);
}

//============================================================
//  osd_process_kill
//============================================================

void osd_process_kill(void)
{
    kill(getpid(), SIGKILL);
}

//============================================================
//  osd_break_into_debugger
//============================================================

void osd_break_into_debugger(const char *message)
{
#ifdef MAME_DEBUG
    printf("MAME exception: %s\n", message);
    printf("Attempting to fall into debugger\n");
    kill(getpid(), SIGTRAP);
#else
    printf("Ignoring MAME exception: %s\n", message);
#endif
}

/* moved to paste.mm
//============================================================
//  osd_get_clipboard_text
//============================================================

std::string osd_get_clipboard_text(void)
{
    return std::string();
}
*/

//============================================================
//  osd_getpid
//============================================================

int osd_getpid(void) noexcept
{
    return getpid();
}

//============================================================
//  osd_dynamic_bind
//============================================================
namespace osd {

bool invalidate_instruction_cache(void const *start, std::size_t size) noexcept
{
#if !defined(OSD_IOS)
    char const *const begin(reinterpret_cast<char const *>(start));
    char const *const end(begin + size);
    __builtin___clear_cache(const_cast<char *>(begin), const_cast<char *>(end))
#endif
    return true;
}

void *virtual_memory_allocation::do_alloc(std::initializer_list<std::size_t> blocks, unsigned intent, std::size_t &size, std::size_t &page_size) noexcept
{
    osd_printf_debug("virtual_memory_allocation::do_alloc(%d)\n", size);

    long const p(sysconf(_SC_PAGE_SIZE));
    if (0 >= p)
        return nullptr;
    std::size_t s(0);
    for (std::size_t b : blocks)
        s += (b + p - 1) / p;
    s *= p;
    if (!s)
        return nullptr;
#if defined(OSD_IOS) || defined(SDLMAME_BSD) || defined(SDLMAME_MACOSX) || defined(SDLMAME_EMSCRIPTEN)
    int const fd(-1);
#else
    // TODO: portable applications are supposed to use -1 for anonymous mappings - detect whatever requires 0 specifically
    int const fd(0);
#endif
    void *const result(mmap(nullptr, s, PROT_NONE, MAP_ANON | MAP_SHARED, fd, 0));
    if (result == (void *)-1)
        return nullptr;
    size = s;
    page_size = p;
    return result;
}

void virtual_memory_allocation::do_free(void *start, std::size_t size) noexcept
{
    osd_printf_debug("virtual_memory_allocation::do_free\n");
    munmap(reinterpret_cast<char *>(start), size);
}

bool virtual_memory_allocation::do_set_access(void *start, std::size_t size, unsigned access) noexcept
{
    osd_printf_debug("virtual_memory_allocation::do_set_access(%s%s%s)\n", (access & READ) ? "R" : "-", (access & WRITE) ? "W" : "-", (access & EXECUTE) ? "X" : "-");

    int prot((NONE == access) ? PROT_NONE : 0);
    if (access & READ)
        prot |= PROT_READ;
    if (access & WRITE)
        prot |= PROT_WRITE;
    if (access & EXECUTE)
        prot |= PROT_EXEC;
    
#if defined(OSD_IOS)
    if (prot & PROT_EXEC)
    {
        osd_printf_debug("virtual_memory_allocation::do_set_access -- FAIL\n");
        return false;
    }
#endif

    return mprotect(reinterpret_cast<char *>(start), size, prot) == 0;
}

} // namespace osd

//============================================================
//  mmap
//  munmap
//  mprotect
//============================================================

#if 0
extern "C" void* mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    osd_printf_verbose("mmap(%s%s%s)\n", (flags & PROT_READ) ? "R" : "-", (flags & PROT_WRITE) ? "W" : "-", (flags & PROT_EXEC) ? "X" : "-");
    return MAP_FAILED;
}

extern "C" int munmap(void *addr, size_t len) {
    osd_printf_verbose("munmap()\n");
    return 0;
}

extern "C" int mprotect(void *addr, size_t len, int flags) {
    osd_printf_verbose("mprotect(%s%s%s)\n", (flags & PROT_READ) ? "R" : "-", (flags & PROT_WRITE) ? "W" : "-", (flags & PROT_EXEC) ? "X" : "-");
    return 0;
}
#endif

//============================================================
//  dlopen
//  dlclose
//  dlsym
//============================================================
extern "C" void* dlopen(const char* path, int mode) {
    osd_printf_verbose("dlopen(%s)\n", path);
    return NULL;
}

extern "C" int dlclose(void* handle) {
    osd_printf_verbose("dlclose\n");
    return 0;
}

extern "C" void* dlsym(void* handle, const char* symbol) {
    osd_printf_verbose("dlsym(%s)\n", symbol);
    return NULL;
}
