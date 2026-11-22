/* The Windows console: VT input and output switched on, cell size, a read with a deadline. No decisions live here. */
#include <windows.h>

static DWORD saved_in = 0;
static DWORD saved_out = 0;
static int saved = 0;

int glin_term_size(unsigned long *cols, unsigned long *rows);

int glin_term_open(unsigned long *cols, unsigned long *rows) {
    HANDLE hin = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE hout = GetStdHandle(STD_OUTPUT_HANDLE);
    if (hin == INVALID_HANDLE_VALUE || hout == INVALID_HANDLE_VALUE) return 0;
    if (!GetConsoleMode(hin, &saved_in)) return 0;
    if (!GetConsoleMode(hout, &saved_out)) return 0;
    saved = 1;
    /* VT input is what makes the console deliver escape sequences instead of key records, so one decoder serves every platform. */
    DWORD in = saved_in;
    in &= ~(DWORD)(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT | ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT);
    in |= (DWORD)(ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_EXTENDED_FLAGS);
    if (!SetConsoleMode(hin, in)) return 0;
    DWORD out = saved_out;
    out |= (DWORD)(ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    if (!SetConsoleMode(hout, out)) {
        SetConsoleMode(hin, saved_in);
        return 0;
    }
    if (cols && rows) glin_term_size(cols, rows);
    return 1;
}

int glin_term_size(unsigned long *cols, unsigned long *rows) {
    HANDLE hout = GetStdHandle(STD_OUTPUT_HANDLE);
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (!GetConsoleScreenBufferInfo(hout, &info)) return 0;
    /* The window, not the buffer: a taller scrollback would otherwise declare a screen the user cannot see. */
    *cols = (unsigned long)(info.srWindow.Right - info.srWindow.Left + 1);
    *rows = (unsigned long)(info.srWindow.Bottom - info.srWindow.Top + 1);
    return 1;
}

int glin_term_read(char *buf, int len, int timeout_ms) {
    HANDLE hin = GetStdHandle(STD_INPUT_HANDLE);
    DWORD wait = WaitForSingleObject(hin, (DWORD)timeout_ms);
    if (wait != WAIT_OBJECT_0) return 0;
    DWORD got = 0;
    if (!ReadFile(hin, buf, (DWORD)len, &got, NULL)) return 0;
    return (int)got;
}

int glin_term_write(const char *buf, int len) {
    HANDLE hout = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD wrote = 0;
    if (!WriteFile(hout, buf, (DWORD)len, &wrote, NULL)) return 0;
    return (int)wrote;
}

long long glin_term_now_us(void) {
    static LARGE_INTEGER freq;
    static int have_freq = 0;
    LARGE_INTEGER now;
    if (!have_freq) {
        QueryPerformanceFrequency(&freq);
        have_freq = 1;
    }
    QueryPerformanceCounter(&now);
    return (long long)((now.QuadPart * 1000000LL) / freq.QuadPart);
}

void glin_term_restore(void) {
    if (!saved) return;
    SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), saved_in);
    SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), saved_out);
    saved = 0;
}
