cd c:\users\chris\src\visual studio\processpriority\release
call "\Program Files (x86)\Microsoft Visual Studio 12.0\vc\bin\vcvars32.bat"



----solution one-----

==header.h===
extern "C"
{
__declspec(dllexport) int fnunmanaged(void);
}

==file.cs===
[DllImport(@"D:\work\unmanaged.dll")]
static extern int fnunmanaged();

----solution two-----

==header.h===
__declspec(dllexport) int fnunmanaged(void);

==cmd to run===
dumpbin.exe /exports unmanaged.dll | find "fnunmanaged"

==file.cs===
[DllImport(@"D:\work\unmanaged.dll",
    EntryPoint = "?fnunmanaged@@YAHH@Z",
    ExactSpelling = true)]
static extern int fnunmanaged();

---solution three-----

==header.h===
int fnunmanaged(void);

==module.def==
LIBRARY "unmanaged"
EXPORTS 
  fn1=?fnunmanaged@@YAHH@Z

==file.cs===
[DllImport(@"D:\work\unmanaged.dll")]
static extern int fn1();


----------------

  ?highPriority@@3HB     (int const highPriority)
   ?lowPriority@@3HB     (int const lowPriority)
?normalPriority@@3HB     (int const normalPriority)
 ?queryPriority@@YAIK@Z  (unsigned int __cdecl queryPriority(unsigned long))
   ?setPriority@@YAIKH@Z (unsigned int __cdecl setPriority(unsigned long,int))


cd "c:\users\chris\src\visual studio\processpriority\getsetprics\bin\release"
mklink ProcessPriority.dll ..\..\..\Release\ProcessPriority.dll

cd "c:\users\chris\src\visual studio\processpriority\include"
mklink ProcessPriority.h ..\ProcessPriority\ProcessPriority.h

------------------

mscorlib.dll              - the dynamic library
mscorlib.tlb              - ??
mscorlib.xml              - ??

ProcPriMgd.dll            - the dynamic library
ProcPriMgd.dll.metagen    - ??
ProcPriMgd.pdb            - debug symbols

architectures
  MSIL exe
  x86  lib