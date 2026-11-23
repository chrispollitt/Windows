/*
 * ptyw - run a console program on a hidden pseudo console (ConPTY).
 *
 * ptyw.exe is linked as a *Windows GUI subsystem* program (like pythonw.exe),
 * so starting it never flashes or allocates a console window.  The child is
 * attached to a ConPTY, so from its point of view it has a real, interactive
 * console (isatty() is true, console APIs and VT sequences work, window size
 * queries answer) -- but nobody can see it.
 *
 * Usage:  ptyw [-s COLSxROWS] [-o FILE] [--] command [args...]
 *
 *   -s COLSxROWS  pseudo console size (default 120x30)
 *   -o FILE       also write everything the child prints to FILE (truncated)
 *
 * I/O plumbing:
 *   - If ptyw's own stdout is redirected (file/pipe/NUL), the child's output
 *     (stdout+stderr merged, as on any terminal, still containing VT escape
 *     sequences) is copied there.  Otherwise it is discarded.
 *   - If ptyw's own stdin is redirected (file/pipe), it is fed to the child's
 *     console input, with LF / CRLF turned into CR (what Enter produces).
 *   - ptyw exits with the child's exit code.  Its own errors exit with 125
 *     and are written to stderr if redirected, else shown in a message box.
 *
 * Build (Cygwin):  make          (needs x86_64-w64-mingw32-gcc)
 * Requires Windows 10 1809 or later (ConPTY).
 */

#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif

#define EXIT_PTYW_ERROR 125
#define DEF_COLS 120
#define DEF_ROWS 30

typedef HRESULT (WINAPI *PFN_CreatePseudoConsole)(COORD, HANDLE, HANDLE, DWORD, HANDLE *);
typedef void    (WINAPI *PFN_ClosePseudoConsole)(HANDLE);

static HANDLE g_pty_in_w;         /* we write here -> child's console input   */
static HANDLE g_sink_std;         /* inherited stdout, or NULL                */
static HANDLE g_sink_file;        /* -o FILE, or NULL                         */
static HANDLE g_err;              /* inherited stderr (for our own errors)    */
static CRITICAL_SECTION g_in_lock;

/* ------------------------------------------------------------------ */
/* helpers                                                              */

/* A std handle that is a real file/pipe/NUL, not NULL and not a console. */
static HANDLE redirected_std(DWORD which)
{
    HANDLE h = GetStdHandle(which);
    DWORD mode;
    if (!h || h == INVALID_HANDLE_VALUE)
        return NULL;
    if (GetFileType(h) == FILE_TYPE_UNKNOWN)
        return NULL;
    if (GetConsoleMode(h, &mode))
        return NULL;                 /* a console: don't spray VT at it */
    return h;
}

static BOOL write_all(HANDLE h, const void *buf, DWORD len)
{
    const BYTE *p = buf;
    while (len) {
        DWORD n;
        if (!WriteFile(h, p, len, &n, NULL) || n == 0)
            return FALSE;
        p += n;
        len -= n;
    }
    return TRUE;
}

static void pty_send(const void *buf, DWORD len)
{
    EnterCriticalSection(&g_in_lock);
    write_all(g_pty_in_w, buf, len);
    LeaveCriticalSection(&g_in_lock);
}

static void die(const WCHAR *msg)
{
    HANDLE e = g_err;
    if (e) {
        char out[2048];
        int n = WideCharToMultiByte(CP_UTF8, 0, msg, -1, out, sizeof out - 3, NULL, NULL);
        if (n > 0) {
            out[n - 1] = '\r';
            out[n] = '\n';
            write_all(e, out, (DWORD)n + 1);
        }
    } else {
        MessageBoxW(NULL, msg, L"ptyw", MB_OK | MB_ICONERROR);
    }
    ExitProcess(EXIT_PTYW_ERROR);
}

static void die_win(const WCHAR *what)
{
    WCHAR sys[512] = L"", msg[1024];
    DWORD err = GetLastError();
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                   NULL, err, 0, sys, 512, NULL);
    wsprintfW(msg, L"ptyw: %s failed (error %lu): %s", what, err, sys);
    die(msg);
}

/* ------------------------------------------------------------------ */
/* pty output pump: copy to sinks, and act as a minimal terminal by     */
/* answering the cursor-position / device-attributes queries that       */
/* ConPTY (or the child) may issue.                                     */

static DWORD WINAPI out_pump(LPVOID arg)
{
    HANDLE rd = arg;
    BYTE buf[8192];
    DWORD n;
    int state = 0;                   /* 0 text, 1 after ESC, 2 inside CSI */
    char params[16];
    int np = 0;

    while (ReadFile(rd, buf, sizeof buf, &n, NULL) && n) {
        DWORD i;
        if (g_sink_std && !write_all(g_sink_std, buf, n))
            g_sink_std = NULL;       /* reader went away: keep draining */
        if (g_sink_file && !write_all(g_sink_file, buf, n))
            g_sink_file = NULL;

        for (i = 0; i < n; i++) {
            BYTE c = buf[i];
            if (c == 0x1b) { state = 1; continue; }
            if (state == 1) {
                if (c == '[') { state = 2; np = 0; } else state = 0;
            } else if (state == 2) {
                if (c >= 0x20 && c <= 0x3f) {
                    if (np < (int)sizeof params - 1) params[np++] = (char)c;
                } else {
                    params[np] = 0;
                    if (c == 'n' && params[0] == '6' && params[1] == 0)
                        pty_send("\x1b[1;1R", 6);        /* cursor position */
                    else if (c == 'c' && (np == 0 || (np == 1 && params[0] == '0')))
                        pty_send("\x1b[?1;0c", 7);       /* primary DA      */
                    state = 0;
                }
            }
        }
    }
    return 0;
}

/* stdin -> pty input, LF/CRLF -> CR */
static DWORD WINAPI in_pump(LPVOID arg)
{
    HANDLE in = arg;
    BYTE buf[4096], conv[4096];
    DWORD n;
    BYTE last = 0;

    while (ReadFile(in, buf, sizeof buf, &n, NULL) && n) {
        DWORD i, m = 0;
        for (i = 0; i < n; i++) {
            BYTE c = buf[i];
            if (c == '\n') {
                if (last != '\r') conv[m++] = '\r';
            } else {
                conv[m++] = c;
            }
            last = c;
        }
        if (m) pty_send(conv, m);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* command line parsing                                                 */

static const WCHAR *skip_ws(const WCHAR *p)
{
    while (*p == L' ' || *p == L'\t') p++;
    return p;
}

/* skip argv[0] using CommandLineToArgvW's rules for the first token */
static const WCHAR *skip_prog(const WCHAR *p)
{
    if (*p == L'"') {
        p++;
        while (*p && *p != L'"') p++;
        if (*p) p++;
    } else {
        while (*p && *p != L' ' && *p != L'\t') p++;
    }
    return skip_ws(p);
}

/* read one option token (optionally "quoted") into out; advance *pp */
static BOOL next_token(const WCHAR **pp, WCHAR *out, int cap)
{
    const WCHAR *p = skip_ws(*pp);
    int n = 0;
    BOOL q = FALSE;
    if (!*p) return FALSE;
    while (*p && (q || (*p != L' ' && *p != L'\t'))) {
        if (*p == L'"') { q = !q; p++; continue; }
        if (n < cap - 1) out[n++] = *p;
        p++;
    }
    out[n] = 0;
    *pp = skip_ws(p);
    return TRUE;
}

/* "120x30" -> COORD; FALSE if malformed or out of range */
static BOOL parse_size(const WCHAR *s, COORD *out)
{
    int c = 0, r = 0;
    while (*s >= L'0' && *s <= L'9') { if (c < 100000) c = c * 10 + (*s - L'0'); s++; }
    if (*s != L'x' && *s != L'X') return FALSE;
    s++;
    while (*s >= L'0' && *s <= L'9') { if (r < 100000) r = r * 10 + (*s - L'0'); s++; }
    if (*s || c < 1 || r < 1 || c > 32767 || r > 32767) return FALSE;
    out->X = (SHORT)c;
    out->Y = (SHORT)r;
    return TRUE;
}

static const WCHAR USAGE[] =
    L"Usage: ptyw [-s COLSxROWS] [-o FILE] [--] command [args...]\n"
    L"   or: <prog>w [args...]   (a copy/link of ptyw.exe named <prog>w.exe runs <prog>)\n\n"
    L"Runs a console program on a hidden pseudo console (ConPTY).\n"
    L"  -s COLSxROWS  console size (default 120x30; env PTYW_SIZE)\n"
    L"  -o FILE       also write the child's output to FILE (env PTYW_OUT)\n"
    L"Redirected stdin/stdout are connected to the child's console.\n"
    L"Exit code is the child's.";

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmd, int nShow)
{
    const WCHAR *p;
    WCHAR tok[MAX_PATH], outfile[MAX_PATH] = L"", alias[MAX_PATH];
    COORD size = { DEF_COLS, DEF_ROWS };
    HMODULE k32;
    PFN_CreatePseudoConsole pCreate;
    PFN_ClosePseudoConsole pClose;
    HANDLE inR, inW, outR, outW, hPC, hOutThread;
    HANDLE hStdin;
    STARTUPINFOEXW si;
    PROCESS_INFORMATION pi;
    SIZE_T attrSize = 0;
    WCHAR *cmd;
    DWORD exitCode = 0;
    size_t len;
    (void)hInst; (void)hPrev; (void)lpCmd; (void)nShow;

    g_err = redirected_std(STD_ERROR_HANDLE);

    /* ---- invocation name: "ptyw" = explicit mode; "<prog>w" = run <prog> ---- */
    {
        WCHAR exe[MAX_PATH];
        const WCHAR *base, *t;
        int n;
        DWORD got = GetModuleFileNameW(NULL, exe, MAX_PATH);
        if (got == 0 || got >= MAX_PATH) die_win(L"GetModuleFileName");
        base = exe;
        for (t = exe; *t; t++)
            if (*t == L'\\' || *t == L'/') base = t + 1;
        n = lstrlenW(base);
        if (n > 4 && base[n - 4] == L'.' && (base[n - 3] | 0x20) == L'e' &&
            (base[n - 2] | 0x20) == L'x' && (base[n - 1] | 0x20) == L'e')
            n -= 4;
        if (n >= MAX_PATH) die(L"ptyw: executable name too long");
        CopyMemory(alias, base, n * sizeof(WCHAR));
        alias[n] = 0;
        if (!lstrcmpiW(alias, L"ptyw")) {
            alias[0] = 0;                     /* explicit mode */
        } else if (n >= 2 && (alias[n - 1] | 0x20) == L'w') {
            alias[n - 1] = 0;                 /* cmdw -> cmd */
        } else {
            WCHAR msg[MAX_PATH + 80];
            wsprintfW(msg, L"ptyw: invoked as \"%s\"; the name must be ptyw or <program>w", alias);
            die(msg);
        }
    }

    /* environment defaults (options may override) */
    {
        WCHAR env[MAX_PATH];
        DWORD e = GetEnvironmentVariableW(L"PTYW_SIZE", env, MAX_PATH);
        if (e && e < MAX_PATH && !parse_size(env, &size))
            die(L"ptyw: PTYW_SIZE expects COLSxROWS (1..32767)");
        e = GetEnvironmentVariableW(L"PTYW_OUT", outfile, MAX_PATH);
        if (e >= MAX_PATH) die(L"ptyw: PTYW_OUT too long");
    }

    /* ---- options ---- */
    p = skip_prog(GetCommandLineW());
    while (!alias[0] && *p == L'-') {
        const WCHAR *q = p;
        next_token(&q, tok, MAX_PATH);
        if (!lstrcmpW(tok, L"--")) { p = q; break; }
        if (!lstrcmpW(tok, L"-h") || !lstrcmpW(tok, L"-?") || !lstrcmpW(tok, L"--help")) {
            die(USAGE);
        } else if (!lstrcmpW(tok, L"-s")) {
            if (!next_token(&q, tok, MAX_PATH)) die(USAGE);
            if (!parse_size(tok, &size))
                die(L"ptyw: -s expects COLSxROWS (1..32767)");
        } else if (!lstrcmpW(tok, L"-o")) {
            if (!next_token(&q, outfile, MAX_PATH)) die(USAGE);
        } else {
            WCHAR msg[MAX_PATH + 64];
            wsprintfW(msg, L"ptyw: unknown option %s", tok);
            die(msg);
        }
        p = q;
    }
    if (!alias[0] && !*p)
        die(USAGE);

    /* ---- sinks / sources ---- */
    g_sink_std = redirected_std(STD_OUTPUT_HANDLE);
    if (outfile[0]) {
        g_sink_file = CreateFileW(outfile, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (g_sink_file == INVALID_HANDLE_VALUE) {
            g_sink_file = NULL;
            die_win(L"opening -o file");
        }
    }
    hStdin = redirected_std(STD_INPUT_HANDLE);

    /* ---- ConPTY (looked up dynamically so old Windows gets a clear error) ---- */
    k32 = GetModuleHandleW(L"kernel32.dll");
    pCreate = (PFN_CreatePseudoConsole)(void *)GetProcAddress(k32, "CreatePseudoConsole");
    pClose  = (PFN_ClosePseudoConsole)(void *)GetProcAddress(k32, "ClosePseudoConsole");
    if (!pCreate || !pClose)
        die(L"ptyw: this Windows has no pseudo console support (need Windows 10 1809+)");

    InitializeCriticalSection(&g_in_lock);

    if (!CreatePipe(&inR, &inW, NULL, 0) || !CreatePipe(&outR, &outW, NULL, 0))
        die_win(L"CreatePipe");
    if (FAILED(pCreate(size, inR, outW, 0, &hPC))) {
        SetLastError(ERROR_GEN_FAILURE);
        die_win(L"CreatePseudoConsole");
    }
    CloseHandle(inR);                /* now owned by the pseudo console */
    CloseHandle(outW);
    g_pty_in_w = inW;

    /* ---- spawn the child on the pseudo console ---- */
    ZeroMemory(&si, sizeof si);
    si.StartupInfo.cb = sizeof si;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attrSize);
    si.lpAttributeList = HeapAlloc(GetProcessHeap(), 0, attrSize);
    if (!si.lpAttributeList ||
        !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attrSize) ||
        !UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hPC, sizeof hPC, NULL, NULL))
        die_win(L"setting up pseudo console attribute");

    /* The child picks up its std handles from *our* process parameters, so a
     * redirected stdin/stdout/stderr here would bypass the pty entirely
     * (isatty false, get_terminal_size fails).  We have saved what we need;
     * blank them so the child gets the pseudo console's handles instead. */
    SetStdHandle(STD_INPUT_HANDLE, NULL);
    SetStdHandle(STD_OUTPUT_HANDLE, NULL);
    SetStdHandle(STD_ERROR_HANDLE, NULL);

    /* Writable command line: "<prog> <rest>" in alias mode, else the rest as given. */
    len = lstrlenW(p) + (alias[0] ? lstrlenW(alias) + 1 : 0);
    cmd = HeapAlloc(GetProcessHeap(), 0, (len + 1) * sizeof(WCHAR));
    if (!cmd) die(L"ptyw: out of memory");
    if (alias[0]) {
        lstrcpyW(cmd, alias);
        if (*p) { lstrcatW(cmd, L" "); lstrcatW(cmd, p); }
    } else {
        lstrcpyW(cmd, p);
    }

    ZeroMemory(&pi, sizeof pi);
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT,
                        NULL, NULL, &si.StartupInfo, &pi)) {
        DWORD err = GetLastError();
        WCHAR sys[512] = L"", msg[1400];
        FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                       NULL, err, 0, sys, 512, NULL);
        wsprintfW(msg, L"ptyw: cannot run \"%s\" (error %lu): %s", cmd, err, sys);
        die(msg);
    }
    CloseHandle(pi.hThread);

    /* ---- pumps ---- */
    hOutThread = CreateThread(NULL, 0, out_pump, outR, 0, NULL);
    if (hStdin)
        CloseHandle(CreateThread(NULL, 0, in_pump, hStdin, 0, NULL));

    /* ---- wait, then tear down ---- */
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);

    /* Older Windows blocks in ClosePseudoConsole until its output is drained;
     * out_pump is still reading, and sees EOF once the pty is gone. */
    pClose(hPC);
    if (hOutThread)
        WaitForSingleObject(hOutThread, 3000);

    ExitProcess(exitCode);
    return (int)exitCode;
}
