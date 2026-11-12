# RunAsAdmin

Run a program elevated (as administrator) from a normal, non-elevated session, **without a UAC prompt**: a tiny `sudo`
for Windows. Two programs:

| program | what it does |
|---|---|
| `RunAsAdminServer.exe` | runs elevated, started at logon by the scheduled task `\UserCreated\Elevate Service` (run level "highest"); listens on the named pipe `RunAsAdmin` and starts what it is asked to |
| `RunAsAdminClient.exe` | `RunAsAdminClient.exe [flags] COMMAND [ARGS...]`: sends the current directory, the command and its arguments to the server. If the client is already elevated it just runs the command itself. With no command it shows its usage |

Flags (short form; the usage shows the rest): `-w` wait for the program to exit, `-p TITLE` pause until a window with that
title appears, `-s` run through the command shell, `-n` no window.

## Security model

Whatever is sent to the server runs with the server's elevated token. So the pipe is the whole security story:

* **Only the account the server runs as may connect.** The pipe's access list allows that one account (read/write) and
  *denies network logons* (SMB reaches named pipes). Before 2026-11 it allowed `Everyone`, which let any local account, and
  possibly a remote one, run programs as an administrator.
* After a client has sent its request the server checks its identity again (impersonation) and refuses anyone but the owner.
* Requests are limited to 32 KB, must name an existing working directory and a command, and a client that sends nothing for 5 s
  is dropped.
* **What it does not do:** any program running as *you* can use it, with no prompt. That is the point of the tool, and it is
  the same trust as `ssh localhost` into an elevated sshd. Treat "code running as me" as "code running as administrator".
  If that is not acceptable, remove the service and use the normal UAC prompt (`Start-Process -Verb RunAs`).

## Build

Needs MSBuild (Visual Studio 2019, or the .NET Framework 4 one) and the .NET 4.5.2 reference assemblies. The two DLLs the
build needs are in `lib/` (`Microsoft.Win32.TaskScheduler`, MIT licence, by David Hall; `ProcPriMgd`, from the
`ProcessPriority` project in this repository).

```
build.cmd          rem builds Release into .\bin
```

## Install / update (run from an elevated prompt)

```
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-InstallDir C:\dos]
```

It backs up what is installed to `<InstallDir>\BAK` (3 newest copies of each file kept), stops the scheduled task and the
server, copies the new files, starts the task again and checks the server is running and its pipe exists. If the check fails it
puts the old files back and starts the old server. Programs the server has already started are not touched. If the server
was not running when you started (nobody logged on, say), it only copies the files; the task starts the new server at the
next logon.

The first run on a machine: run the client once from an **elevated** prompt; it creates the scheduled task
(`PingServer`). After that the task starts the server at every logon. To remove it: end and delete the task, delete the files.

## Files

```
RunAsAdminServer/   the server, plus Globals.cs and CWP_Utils.cs that the client shares
RunAsAdminClient/   the client
lib/                the two DLLs the build references
build.cmd           build
install.ps1         install / update with backup and rollback
```
