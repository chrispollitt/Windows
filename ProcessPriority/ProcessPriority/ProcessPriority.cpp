// ProcessPriority.cpp : Defines the exported functions for the DLL application.
//

#include "stdafx.h"
#include "ProcessPriority.h"

//////////////////////////////////////////////////////////////////

//#define _WIN32_WINNT 0x0501 // XP and above
#include <sdkddkver.h>
#include <stdio.h>
#include <windows.h>
#include <stdexcept>
//#using <mscorlib.dll>

//using namespace System::Runtime::InteropServices;

// declare functions
typedef NTSTATUS(NTAPI *NtQueryInformationProcessFn)(HANDLE process, ULONG infoClass, void* data, ULONG dataSize, ULONG* outSize);
static  NtQueryInformationProcessFn NtQueryInformationProcess;
typedef NTSTATUS(NTAPI *NtSetInformationProcessFn)(HANDLE process, ULONG infoClass, void* data, ULONG dataSize);
static  NtSetInformationProcessFn NtSetInformationProcess;

// set addresses
const DWORD ProcessInformationMemoryPriority = 0x27;
const DWORD ProcessInformationIoPriority = 0x21;
// mem
const DWORD LowMemoryPriority = 3;
const DWORD DefaultMemoryPriority = 5;
const DWORD HighMemoryPriority = 5; // 7 does not work
// io
const DWORD LowIoPriority = 1;
const DWORD DefaultIoPriority = 2;
const DWORD HighIoPriority = 2; // 3 does not work
// cpu set in windows.h
//const DWORD BELOW_NORMAL_PRIORITY_CLASS =   0;
//const DWORD NORMAL_PRIORITY_CLASS       =  32;
//const DWORD ABOVE_NORMAL_PRIORITY_CLASS = 128;

// internal priorities
extern PROCESSPRIORITY_API const int lowPriority = 1;
extern PROCESSPRIORITY_API const int normalPriority = 2;
extern PROCESSPRIORITY_API const int highPriority = 3;

// error message
const int  esize = 1024;
char error[esize];

//////////////////////////
// Set process priority //
//////////////////////////
PROCESSPRIORITY_API unsigned int setPriority(DWORD targetPid, int priority)
{
	try {
		doInit();

		if (targetPid == 0) {
			throw std::runtime_error("pid == 0");
		}

		// figure out what priority we should be setting
		DWORD cpu, memory, io;
		if (priority == lowPriority)
		{
			cpu = BELOW_NORMAL_PRIORITY_CLASS;
			memory = LowMemoryPriority;
			io = LowIoPriority;
		}
		else if (priority == normalPriority)
		{
			cpu = NORMAL_PRIORITY_CLASS;
			memory = DefaultMemoryPriority;
			io = DefaultIoPriority;
		}
		else if (priority == highPriority)
		{
			cpu = ABOVE_NORMAL_PRIORITY_CLASS;
			memory = HighMemoryPriority;
			io = HighIoPriority;
		}
		else
		{
			sprintf_s(error, esize, "illegal priority value: %d", priority);
			throw std::runtime_error(error);
		}

		HANDLE target = OpenProcess(PROCESS_SET_INFORMATION, false, targetPid);
		if (!target)
		{
			sprintf_s(error, esize, "Failed to open process %u: %s", targetPid, CLastError(GetLastError()));
			throw std::runtime_error(error);
		}

		// set the CPU priority
		if (!SetPriorityClass(target, cpu))
		{
			CloseHandle(target);
			sprintf_s(error, esize, "SetPriorityClass failed: %s", CLastError(GetLastError()));
			throw std::runtime_error(error);
		}

		NTSTATUS result;

		// set the IO priority
		result = NtSetInformationProcess(target, ProcessInformationIoPriority, &io, sizeof(io));
		if (result != 0)
		{
			CloseHandle(target);
			sprintf_s(error, esize, "NtSetInformationProcess( IoPriority ) failed: %u", result);
			throw std::runtime_error(error);
		}

		// set the memory priority
		result = NtSetInformationProcess(target, ProcessInformationMemoryPriority,
			&memory, sizeof(memory));
		if (result != 0)
		{
			CloseHandle(target);
			sprintf_s(error, esize, "NtSetInformationProcess( MemoryPriority ) failed: %u", result);
			throw std::runtime_error(error);
		}

		CloseHandle(target);
	}
	catch (std::exception& e) {
		FILE *fh = NULL;
		fopen_s(&fh, "c:\\tmp\\ProcessPriority.err", "a");
		fprintf(fh, "err=%s\n", e.what());
		fclose(fh);
		throw;
	}
	return 0;
}

////////////////////////////
// Query process priority //
////////////////////////////
PROCESSPRIORITY_API unsigned int queryPriority(DWORD targetPid)
{
	try {
		doInit();

		if (targetPid == 0) {
			throw std::runtime_error("pid == 0");
		}

		HANDLE target = OpenProcess(PROCESS_QUERY_INFORMATION, false, targetPid);
		if (!target)
		{
			sprintf_s(error, esize, "Failed to open process %u: %s", targetPid, CLastError(GetLastError()));
			throw std::runtime_error(error);
		}

		// find the CPU priority
		DWORD cpu = GetPriorityClass(target);
		if (cpu == 0)
		{
			CloseHandle(target);
			sprintf_s(error, esize, "GetPriorityClass failed: %s", CLastError(GetLastError()));
			throw std::runtime_error(error);
		}

		NTSTATUS result;
		ULONG len;

		// find the memory priority
		DWORD memory;
		result = NtQueryInformationProcess(target, ProcessInformationMemoryPriority, &memory, sizeof(memory), &len);
		if (result != 0 || len != sizeof(memory))
		{
			sprintf_s(error, esize, "NtQueryInformationProcess( MemoryPriority ) failed: %u", result);
			throw std::runtime_error(error);
		}

		// find the IO priority
		DWORD io;
		result = NtQueryInformationProcess(target, ProcessInformationIoPriority, &io, sizeof(io), &len);
		if (result != 0 || len != sizeof(io))
		{
			sprintf_s(error, esize, "NtQueryInformationProcess( IoPriority ) failed: %u", result);
			throw std::runtime_error(error);
		}

		if (cpu > 1) {
			int cpu2 = 1;
			while (cpu >>= 1) { ++cpu2; }
			cpu = cpu2;
		}
		return (cpu << 16) | (memory << 8) | io;
	}
	catch (std::exception& e) {
		FILE *fh = NULL;
		fopen_s(&fh, "c:\\tmp\\ProcessPriority.err", "a");
		fprintf(fh, "err=%s\n", e.what());
		fclose(fh);
		throw;
	}
}
//#pragma unmanaged

//////////
// Init //
//////////
unsigned int doInit()
{
	// locate the functions for querying/setting memory and IO priority
	HMODULE ntdll = LoadLibrary(L"ntdll.dll");
	NtQueryInformationProcess = (NtQueryInformationProcessFn)GetProcAddress(ntdll, "NtQueryInformationProcess");
	NtSetInformationProcess = (NtSetInformationProcessFn)GetProcAddress(ntdll, "NtSetInformationProcess");
	if (!NtQueryInformationProcess || !NtSetInformationProcess)
	{
		sprintf_s(error, esize, "Failed to locate the required imports from ntdll.dll");
		throw std::runtime_error(error);
	}
	return 0;
}

//////////////////////////////
// get last error as string //  NOT WORKING!
//////////////////////////////
char *CLastError(const DWORD dwErrorCode)
{
	LPTSTR lpErrorText = NULL;

	::FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_ALLOCATE_BUFFER,
		0, dwErrorCode, 0, lpErrorText, MAX_PATH, 0);

	char *strErrMessage = _strdup((char *)lpErrorText);
	::LocalFree(lpErrorText);
	return strErrMessage;
}