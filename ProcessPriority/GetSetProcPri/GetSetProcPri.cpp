// GetSetProcPri.cpp : Defines the entry point for the console application.
//

// general
#include "stdafx.h"
#include <stdexcept>
#using <mscorlib.dll>

// local
#ifdef __cplusplus_cli
#using "../Release/ProcPriMgd.dll" // use via CLR not linker
using namespace ProcPriMgd;
#else
#include "../include/ProcessPriority.h"
using namespace ProcessPriority;
#endif

///////////////
// main()
int _tmain(int argc, _TCHAR* argv[])
{
	unsigned int result = 1;

	if (argc != 3) {
		fprintf(stderr, "usage: %s <pid> <pri>\n", argv[0]);
		return 1;
	}

	DWORD targetPid = (DWORD)atoi(argv[1]);
	int priority = (int)atoi(argv[2]);

	// get pri
	try {
		result = ProcPri::queryPriority(targetPid);
	}
	catch (const PPExecpt^ e) {
		fprintf(stderr, "error: cannot query priority for pid: %d error: %s\n", targetPid, e->what);
		return 1;
	}

	if (result == 1) {
		fprintf(stderr, "error: cannot get priority for pid: %d\n", targetPid);
		return 1;
	}

	unsigned int cpu = (result >> 16) & 0xFF;
	unsigned int memory = (result >> 8) & 0xFF;
	unsigned int io = (result)& 0xFF;

	printf("cpu=%d\n", cpu);
	printf("mem=%d\n", memory);
	printf("io=%d\n", io);

	// try to set priority
	try {
		result = ProcPri::setPriority(targetPid, priority);
		printf("set=%d\n", result);
	}
	catch (const PPExecpt^ e) {
		fprintf(stderr, "error: cannot set priority for pid: %d error: %s\n", targetPid, e->what);
		return 1;
	}

	return 0;
}
