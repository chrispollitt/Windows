// ProcPriMgd.h

#pragma once

#include <windows.h>
//#define _WIN32_WINNT 0x0501 // XP and above
#include <sdkddkver.h>
#include <stdio.h>
#include <windows.h>
#include <stdexcept>
#using <mscorlib.dll>

using namespace System;

namespace ProcPriMgd {

	public ref struct PPExecpt : public Exception {
	public:
		String^ what = gcnew String("");
	};

	public ref class ProcPri {

	public:
		// internal priorities
		static const UInt32 lowPriority = 1;
		static const UInt32 normalPriority = 2;
		static const UInt32 highPriority = 3;

		// functions
		static UInt32 setPriority(UInt32 targetPid, UInt32 priority);
		static UInt32 queryPriority(UInt32 targetPid);

	private:
		// set addresses
		static const DWORD ProcessInformationMemoryPriority = 0x27;
		static const DWORD ProcessInformationIoPriority = 0x21;
		// mem
		static const DWORD LowMemoryPriority = 3;
		static const DWORD DefaultMemoryPriority = 5;
		static const DWORD HighMemoryPriority = 5; // 7 does not work
		// io
		static const DWORD LowIoPriority = 1;
		static const DWORD DefaultIoPriority = 2;
		static const DWORD HighIoPriority = 2; // 3 does not work
		// cpu set in windows.h
		//           DWORD BELOW_NORMAL_PRIORITY_CLASS =   0;
		//           DWORD NORMAL_PRIORITY_CLASS       =  32;
		//           DWORD ABOVE_NORMAL_PRIORITY_CLASS = 128;

		// internal functions
		static void doInit();
		static String^ CLastError(const DWORD dwErrorCode);
	};

}
