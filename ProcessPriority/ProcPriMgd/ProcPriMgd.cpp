// This is the main DLL file.

#include "stdafx.h"
#include "ProcPriMgd.h"

////////////////////////////////
// ProcPriMgd.cpp : Defines the exported functions for the DLL application.
//

using namespace System;

namespace ProcPriMgd {

	// declare functions
	typedef NTSTATUS(NTAPI *NtQueryInformationProcessFn)(HANDLE process, ULONG infoClass, void* data, ULONG dataSize, ULONG* outSize);
	typedef NTSTATUS(NTAPI *NtSetInformationProcessFn)(HANDLE process, ULONG infoClass, void* data, ULONG dataSize);
	static NtQueryInformationProcessFn NtQueryInformationProcess;
	static NtSetInformationProcessFn NtSetInformationProcess;

	//////////////////////////
	// Set process priority //
	//////////////////////////
	UInt32 ProcPri::setPriority(UInt32 targetPid, UInt32 priority)
	{
		PPExecpt^ pPPExecpt = gcnew PPExecpt;
		ProcPri::doInit();

		if (targetPid == 0) {
			pPPExecpt->what = "pid == 0";
			throw pPPExecpt;
		}

		// figure out what priority we should be setting
		DWORD cpu, memory, io;
		if (priority == ProcPri::lowPriority)
		{
			cpu = BELOW_NORMAL_PRIORITY_CLASS;
			memory = LowMemoryPriority;
			io = LowIoPriority;
		}
		else if (priority == ProcPri::normalPriority)
		{
			cpu = NORMAL_PRIORITY_CLASS;
			memory = DefaultMemoryPriority;
			io = DefaultIoPriority;
		}
		else if (priority == ProcPri::highPriority)
		{
			cpu = ABOVE_NORMAL_PRIORITY_CLASS;
			memory = HighMemoryPriority;
			io = HighIoPriority;
		}
		else
		{
			pPPExecpt->what = "illegal priority value: " + priority.ToString();
			throw pPPExecpt;
		}

		HANDLE target = OpenProcess(PROCESS_SET_INFORMATION, false, targetPid);
		if (!target)
		{
			pPPExecpt->what = "Failed to open process " + targetPid.ToString() + " " + CLastError(GetLastError());
			throw pPPExecpt;
		}

		// set the CPU priority
		if (!SetPriorityClass(target, cpu))
		{
			CloseHandle(target);
			pPPExecpt->what = "SetPriorityClass failed: " + CLastError(GetLastError());
			throw pPPExecpt;
		}

		NTSTATUS result;

		// set the IO priority
		result = NtSetInformationProcess(target, ProcessInformationIoPriority, &io, sizeof(io));
		if (result != 0)
		{
			CloseHandle(target);
			pPPExecpt->what = "NtSetInformationProcess( IoPriority ) failed: " + result.ToString();
			throw pPPExecpt;
		}

		// set the memory priority
		result = NtSetInformationProcess(target, ProcessInformationMemoryPriority,
			&memory, sizeof(memory));
		if (result != 0)
		{
			CloseHandle(target);
			pPPExecpt->what = "NtSetInformationProcess( MemoryPriority ) failed: " + result.ToString();
			throw pPPExecpt;
		}

		CloseHandle(target);
		return (UInt32)0;
	}

	////////////////////////////
	// Query process priority //
	////////////////////////////
	UInt32 ProcPri::queryPriority(UInt32 targetPid)
	{
		PPExecpt^ pPPExecpt = gcnew PPExecpt;
		ProcPri::doInit();

		if (targetPid == 0) {
			pPPExecpt->what = "pid == 0";
			throw pPPExecpt;
		}

		HANDLE target = OpenProcess(PROCESS_QUERY_INFORMATION, false, targetPid);
		if (!target)
		{
			pPPExecpt->what = "Failed to open process " + targetPid.ToString() + ProcPri::CLastError(GetLastError());
			throw pPPExecpt;
		}

		// find the CPU priority
		DWORD cpu = GetPriorityClass(target);
		if (cpu == 0)
		{
			CloseHandle(target);
			pPPExecpt->what = "GetPriorityClass failed: " + ProcPri::CLastError(GetLastError());
			throw pPPExecpt;
		}

		NTSTATUS result;
		ULONG len;

		// find the memory priority
		DWORD memory;
		result = NtQueryInformationProcess(target, ProcessInformationMemoryPriority, &memory, sizeof(memory), &len);
		if (result != 0 || len != sizeof(memory))
		{
			pPPExecpt->what = "NtQueryInformationProcess( MemoryPriority ) failed: " + result.ToString();
			throw pPPExecpt;
		}

		// find the IO priority
		DWORD io;
		result = NtQueryInformationProcess(target, ProcessInformationIoPriority, &io, sizeof(io), &len);
		if (result != 0 || len != sizeof(io))
		{
			pPPExecpt->what = "NtQueryInformationProcess( IoPriority ) failed: " + result.ToString();
			throw pPPExecpt;
		}

		if (cpu > 1) {
			int cpu2 = 1;
			while (cpu >>= 1) { ++cpu2; }
			cpu = cpu2;
		}
		return (UInt32)((cpu << 16) | (memory << 8) | io);
	}
	//#pragma unmanaged

	//////////
	// Init //
	//////////
	void ProcPri::doInit()
	{
		PPExecpt^ pPPExecpt = gcnew PPExecpt;

		// locate the functions for querying/setting memory and IO priority
		HMODULE ntdll = LoadLibrary(L"ntdll.dll");
		NtQueryInformationProcess = (NtQueryInformationProcessFn)GetProcAddress(ntdll, "NtQueryInformationProcess");
		NtSetInformationProcess = (NtSetInformationProcessFn)GetProcAddress(ntdll, "NtSetInformationProcess");
		if (!NtQueryInformationProcess || !NtSetInformationProcess)
		{
			pPPExecpt->what = "Failed to locate the required imports from ntdll.dll";
			throw pPPExecpt;
		}
	}

	//////////////////////////////
	// get last error as string //  NOT WORKING!
	//////////////////////////////
	String^ ProcPri::CLastError(const DWORD dwErrorCode)
	{
		LPTSTR lpErrorText = NULL;

		::FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_ALLOCATE_BUFFER,
			0, dwErrorCode, 0, lpErrorText, MAX_PATH, 0);

		String^ strErrMessage = gcnew String(lpErrorText);
		::LocalFree(lpErrorText);
		return strErrMessage;
	}

}