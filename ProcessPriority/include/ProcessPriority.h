// The following ifdef block is the standard way of creating macros which make exporting 
// from a DLL simpler. All files within this DLL are compiled with the PROCESSPRIORITY_EXPORTS
// symbol defined on the command line. This symbol should not be defined on any project
// that uses this DLL. This way any other project whose source files include this file see 
// PROCESSPRIORITY_API functions as being imported from a DLL, whereas this DLL sees symbols
// defined with this macro as being exported.
#ifdef PROCESSPRIORITY_EXPORTS
#define PROCESSPRIORITY_API __declspec(dllexport)
#else
#define PROCESSPRIORITY_API __declspec(dllimport)
#endif

extern PROCESSPRIORITY_API const int lowPriority;
extern PROCESSPRIORITY_API const int normalPriority;
extern PROCESSPRIORITY_API const int highPriority;

PROCESSPRIORITY_API unsigned int setPriority(DWORD targetPid, int priority);
PROCESSPRIORITY_API unsigned int queryPriority(DWORD targetPid);
unsigned int doInit();
char *CLastError(const DWORD dwErrorCode);

