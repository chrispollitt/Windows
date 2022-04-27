/****************************** Module Header ******************************\
* Module Name:	Global.cs
* Project:		RunAsAdmin 
* 
\***************************************************************************/

#region Using directives
// System
using CWP_Utils;
// Local
using Microsoft.Win32.TaskScheduler;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Threading;
#endregion

namespace RunAsAdmin
{
    //////////////////////////////////////////////////////////
    // global methods and constants
    public class Global
    {
        // pipe
        public const int BufferSize = 4096;  // 4 KB
        public const int aSecond = 1000;
        public const int Timeout = aSecond * 5; // 5 seconds
        public const String Separator = "\x09";
        public static String ServerName = ".";
        public static String PipeName = "RunAsAdmin";

        // names
        public const String ServerExe = "RunAsAdminServer";
        public const String ClientExe = "RunAsAdminClient";

        // scheduled task
        public const String TaskFolder = @"\UserCreated";
        public const String TaskName = "Elevate Service";
        public const String InstallDir = @"C:\dos\";

        // spawn user proc
        public const String StatusPrefix = "result=";
        public const String StatusFail = "fail";
        public const String StatusSuccess = "success";
        public const int MaxWait = aSecond * 60; // 1 minute

        // Options
        public static GetOpts Opts;

        // Am I admin
        public static WindowsIdentity MyId = WindowsIdentity.GetCurrent();
        public static WindowsPrincipal MyIdPrincipal = new WindowsPrincipal(MyId);
        public static bool AmIAdmin = MyIdPrincipal.IsInRole(WindowsBuiltInRole.Administrator);
        public static int MyProcessID = Process.GetCurrentProcess().Id;

        /// <summary>
        /// Ping Server and start if necessary
        /// </summary>
        public static void PingServer()
        {
            try
            {
                using (TaskService ts = new TaskService())
                {
                    Task ti = ts.GetTask(TaskFolder + @"\" + TaskName);

                    // create if not found
                    if (ti == null && AmIAdmin)
                    {
                        Utils.Logging(OutLevel.Debug, "Creating Server's scheduled task");

                        // Create a new task definition and assign properties
                        TaskDefinition td = ts.NewTask();
                        td.RegistrationInfo.Description = TaskName;

                        // Create a trigger that will fire the task at this time every other day
                        WindowsIdentity MyId = WindowsIdentity.GetCurrent();
                        WindowsPrincipal MyIdPrincipal = new WindowsPrincipal(MyId);
                        String CurrentUser = MyIdPrincipal.Identity.Name.ToString();
                        td.Triggers.Add(new LogonTrigger { UserId = CurrentUser });

                        // Create an action that will launch server whenever the trigger fires
                        td.Actions.Add(new ExecAction(InstallDir + ServerExe + ".exe", null));
                        td.Principal.RunLevel = TaskRunLevel.Highest;
                        td.Settings.Priority = ProcessPriorityClass.Normal;

                        // misc
                        td.Settings.AllowDemandStart = true;
                        td.Settings.AllowHardTerminate = true;
                        td.Settings.DisallowStartIfOnBatteries = false;
                        td.Settings.Enabled = true;
                        td.Settings.ExecutionTimeLimit = TimeSpan.FromDays(7);
                        td.Settings.MultipleInstances = TaskInstancesPolicy.StopExisting;
                        td.Settings.RunOnlyIfIdle = false;
                        td.Settings.StopIfGoingOnBatteries = false;
                        //td.Settings.RunOnlyIfLoggedOn = true;

                        // Register the task in the root folder
                        ts.RootFolder.RegisterTaskDefinition(TaskFolder + @"\" + TaskName, td);

                        // get instance
                        ti = ts.GetTask(TaskFolder + @"\" + TaskName);
                    }

                    // this is the client
                    if (Utils.ExeName == ClientExe)
                    {
                        // was not admin so didn't create above
                        if (ti == null)
                        {
                            Utils.Logging(OutLevel.Fatal, "Need to create server scheduled task first");
                            Environment.Exit(1);
                        }
                        // have client start server if not yet running
                        else if (!ti.State.Equals(TaskState.Running))
                        {
                            Utils.Logging(OutLevel.Tip, "Starting server");
                            ti.Run();
                            Thread.Sleep(Timeout);
                        }
                    }
                    // this is server
                    else
                    {
                        // create failed?!
                        if (ti == null)
                        {
                            // should never get here
                            Utils.Logging(OutLevel.Fatal, "Unable to create server scheduled task");
                            Environment.Exit(1);
                        }
                        // is task not running? this is not right!
                        else if (!ti.State.Equals(TaskState.Running))
                        {
                            Utils.Logging(OutLevel.Fatal, "Must be run from task scheduler");
                            Environment.Exit(1);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Utils.Logging(OutLevel.Fatal, "Cannot ping server: " + ex.Message);
                Environment.Exit(1);
            }
        }

        /// <summary>
        /// Run the user's program
        /// </summary>
        public static String RunIt(String data)
        {
            String result = StatusFail;
            try
            {
                String CmdDir;
                String CmdFile;
                String CmdArgs = String.Empty;

                // restore arguments and cwd
                List<String> datas = new List<String>();
                datas.AddRange(data.Split(Separator.ToCharArray()[0]));
                CmdDir = datas[0];
                datas.RemoveAt(0);


                if (Opts != null)
                {
                    Opts = null;
                }
                // create opts object
                Opts = new GetOpts(datas);

                // check command line args
                if (!Opts.ParseResult)
                {
                    if (Utils.ExeName == ClientExe)
                    {
                        Opts.Usage();
                        Environment.Exit(1);
                    }
                    return ("command line parse error");
                }

                // if shell
                if (Opts.Shell)
                {
                    var arg = Opts.Command;
                    CmdFile = System.Environment.GetEnvironmentVariable("COMSPEC");
                    CmdArgs += " /c";
                    if (arg.Contains(" "))
                    {
                        CmdArgs += " \"" + arg + "\"";
                    }
                    else
                    {
                        CmdArgs += " " + arg;
                    }
                }
                // regular
                else
                {
                    CmdFile = Opts.Command;
                }
                foreach (var arg in Opts.Arguments)
                {
                    if (arg.Contains(" "))
                    {
                        CmdArgs += " \"" + arg + "\"";
                    }
                    else
                    {
                        CmdArgs += " " + arg;
                    }
                }

                // create process obj
                Process Proc = new Process();
                Proc.StartInfo.WorkingDirectory = CmdDir;
                Proc.StartInfo.FileName = CmdFile;
                Proc.StartInfo.Arguments = CmdArgs;

                // Options:
                //  -h = hidden (for console apps)
                if (Opts.No_window)
                {
                    Proc.StartInfo.WindowStyle = ProcessWindowStyle.Hidden;
                }

                // run it
                if (Proc.Start())
                {
                    Proc.PriorityClass = ProcessPriorityClass.Normal;
                    Proc.PriorityBoostEnabled = true;
                    int TotWait = 0;

                    if (Opts.WaitForExit)
                    {
                        while (!Proc.HasExited)
                        {
                            if (TotWait >= MaxWait)
                            {
                                result = "Timeout waiting for exit";
                                break;
                            }
                            else
                            {
                                Thread.Sleep(aSecond);
                                Proc.Refresh();
                                TotWait += aSecond;
                            }
                        }
                        if (Proc.HasExited)
                        {
                            result = Proc.ExitCode == 0 ? StatusSuccess : "failed";
                        }
                    }
                    else if (Opts.PauseForWindow != null && Opts.PauseForWindow.Length > 0)
                    {
                        // Proc.WaitForInputIdle();   // sadly will not work for conhost.exe apps (cmd / tcc / rxvt)
                        while (!Regex.IsMatch(Proc.MainWindowTitle, Opts.PauseForWindow, RegexOptions.IgnoreCase))
                        {
                            if (Proc.HasExited || TotWait >= MaxWait)
                            {
                                result = "Window title never set";
                                break;
                            }
                            else
                            {
                                Thread.Sleep(aSecond);
                                Proc.Refresh();
                                TotWait += aSecond;
                            }
                        }
                        if (Regex.IsMatch(Proc.MainWindowTitle, Opts.PauseForWindow, RegexOptions.IgnoreCase))
                        {
                            result = StatusSuccess;
                        }
                    }
                    else
                    {
                        result = StatusSuccess;
                    }
                }
                else
                {
                    result = "failed to start";
                }
                if (Utils.ExeName == ServerExe)
                {
                    Utils.Logging(OutLevel.Info, "Ran cmd: " + CmdFile + ", result=" + result);
                }
            }
            catch (Exception ex)
            {
                Utils.Logging(OutLevel.Error, "The server throws the error: " + ex.Message);
                result = ex.Message;
            }

            return (result);
        }

    }

    public class GetOpts : BaseGetOpts
    {
        // options
        [Metadata(Kind = OptKind.OptionalFlag, Description = "Wait for program exit")]
        public bool WaitForExit = false;

        [Metadata(Kind = OptKind.OptionalFlag, UsageName = "Title", Description = "Pause until window appears")]
        public String PauseForWindow = string.Empty;

        [Metadata(Kind = OptKind.OptionalFlag, Description = "Run via command shell")]
        public bool Shell = false;

        [Metadata(Kind = OptKind.OptionalFlag, Description = "Run with no window")]
        public bool No_window = false;

        // args
        [Metadata(Position = 0, Kind = OptKind.MandatoryArg, Description = "The command to run")]
        public String Command = string.Empty;

        [Metadata(Position = 1, Kind = OptKind.OptionalArg, Description = "Optional arg list")]
        public List<String> Arguments = new List<string>();

        // explicitly call base constructors since they are not inherited
        public GetOpts() : base() { }
        public GetOpts(String[] argv) : base(argv) { }
        public GetOpts(List<String> argv) : base(argv) { }
    }

}