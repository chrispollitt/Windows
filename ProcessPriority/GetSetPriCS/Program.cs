// General
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.ExceptionServices;
using System.ComponentModel;

// local
using ProcPriMgd;

///////////////////////
// program
namespace GetSetPriCS
{
    class Program
    {

        static void Main(string[] args)
        {
            UInt32 result = 1;

            if (args.Length != 2)
            {
                System.Console.WriteLine("usage: " + Environment.CommandLine + " <pid> <pri>");
                Environment.Exit(1);
            }

            UInt32 targetPid = Convert.ToUInt32(args[0]);
            UInt32 priority = Convert.ToUInt32(args[1]);

            // get pri
            try
            {
                result = ProcPri.queryPriority(targetPid);
            }
            catch (PPExecpt e) // Win32Exception System.Runtime.InteropServices.SEHException
            {
                System.Console.WriteLine("error: cannot query priority for pid: " + targetPid + " error: " + e.what);
                Environment.Exit(1);
            }

            if (result == 1)
            {
                System.Console.WriteLine("error: cannot get priority for pid: " + targetPid);
                Environment.Exit(1);
            }

            UInt32 cpu = (result >> 16) & 0xFF;
            UInt32 memory = (result >> 8) & 0xFF;
            UInt32 io = (result) & 0xFF;

            System.Console.WriteLine("cpu=" + cpu);
            System.Console.WriteLine("mem=" + memory);
            System.Console.WriteLine("io=" + io);

            // try to set priority
            try
            {
                result = ProcPriMgd.ProcPri.setPriority(targetPid, priority);
                System.Console.WriteLine("set=" + result);
            }
            catch (PPExecpt e) // Win32Exception System.Runtime.InteropServices.SEHException
            {
                System.Console.WriteLine("error: cannot set priority for pid: " + targetPid + " error: " + e.what);
                Environment.Exit(1);
            }

            Environment.Exit(0);
        }

    }
}
