/****************************** Module Header ******************************\
* Module Name:	RunAsAdminServer.cs
* Project:		RunAsAdmin 
* 
\***************************************************************************/

#region Using directives
// System
using CWP_Utils;
// Local
using ProcPriMgd;
using System;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
#endregion

[assembly: AssemblyVersion("1.0.0.0")]
namespace RunAsAdmin
{
    class RunAsAdminServer : Global
    {

        /// <summary>
        /// Main
        /// </summary>
        [STAThread]
        static void Main(String[] args)
        {
            Utils.ExeName = ServerExe;
#if TARGET_EXE
            Utils.ExeType = "Exe";
#elif TARGET_WINEXE
            Utils.ExeType = "WinExe";
#else
#error "neither TARGET_EXE nor TARGET_WINEXE defined"
#endif

            // If any args are passed, exit
            if (args.Length > 0)
            {
                Utils.Logging(OutLevel.Fatal, "Server takes no arguments");
                Environment.Exit(1);
            }

            // I need to be admin
            if (!AmIAdmin)
            {
                Utils.Logging(OutLevel.Fatal, "Server not run as Administrator");
                Environment.Exit(1);
            }

            // Ensure my priority is normal for cpu, mem, io
            // (Yes, this is a hack!)
            try
            {
                ProcPri.setPriority((UInt32)MyProcessID, ProcPri.normalPriority);
            }
            catch (PPExecpt e)
            {
                Utils.Logging(OutLevel.Warn, "setPriority failed: " + e.what);
            }

#if !DEBUG1
            // ping myself
            PingServer();
#endif
            // run main loop
            PipeServer();
        }

        /// <summary>
        /// Named pipe server through BCL System.IO.Pipes.
        ///
        /// Anything sent here is run with this process's elevated token, so who may connect matters:
        ///  - the pipe's access list allows only the account this server runs as (this used to be "Everyone"),
        ///    and denies network logons (SMB reaches named pipes);
        ///  - the caller's identity is checked again after it has sent its request;
        ///  - requests are size-limited, must name an existing working directory, and a client that stalls is dropped.
        /// Programs of the same account can still use it: that is what this service is for (elevating without a prompt).
        /// </summary>
        static void PipeServer()
        {
            NamedPipeServerStream pipeServer = null;

            // the elevated token has the same user SID as the normal one
            SecurityIdentifier owner = WindowsIdentity.GetCurrent().User;

            try
            {
                /////////////////////////////////////////////////////////////////
                // Create a named pipe.
                //

                PipeSecurity pipeSa = new PipeSecurity();
                pipeSa.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
                    PipeAccessRights.FullControl, AccessControlType.Deny));
                pipeSa.AddAccessRule(new PipeAccessRule(owner,
                    PipeAccessRights.ReadWrite, AccessControlType.Allow));

                // Create the named pipe
                pipeServer = new NamedPipeServerStream(
                    PipeName,                       // The unique pipe name.
                    PipeDirection.InOut,            // The pipe is bi-directional
                    1,                              // Max num of instances
                    PipeTransmissionMode.Message,   // Message type pipe
                    PipeOptions.None,               // No additional parameters
                    BufferSize,                     // Input buffer size
                    BufferSize,                     // Output buffer size
                    pipeSa,                         // Pipe security attributes
                    HandleInheritability.None       // Not inheritable
                );

                Utils.Logging(OutLevel.Debug, "The named pipe, " + PipeName + ", is created for " + owner.Value);
            }
            catch (Exception ex)
            {
                Utils.Logging(OutLevel.Fatal, "The server threw error on startup: " + ex.Message.ToString());
                return;
            }

            /////////////////////////////////////////////////////////////////
            // Loop forever
            //
            while (true)
            {
                try
                {
                    Utils.Logging(OutLevel.Debug, "Waiting for the client's connection...");
                    pipeServer.WaitForConnection();

                    String reply = HandleClient(pipeServer, owner);

                    if (reply != null && pipeServer.CanWrite)
                    {
                        byte[] bReply = Encoding.Unicode.GetBytes(StatusPrefix + reply);
                        pipeServer.Write(bReply, 0, bReply.Length);
                        Utils.Logging(OutLevel.Debug, "Replied " + bReply.Length.ToString() + " bytes; Message: '" + StatusPrefix + reply + "'");

                        // let the client read the reply before disconnecting, but do not wait for ever for a client that does not
                        Task drain = Task.Factory.StartNew(delegate { try { pipeServer.WaitForPipeDrain(); } catch (Exception) { } });
                        drain.Wait(Timeout);
                    }
                }
                catch (Exception ex)
                {
                    Utils.Logging(OutLevel.Error, "The server throws the error: " + ex.Message);
                    Thread.Sleep(200);                  // no busy loop if something is persistently wrong
                }
                finally
                {
                    try { pipeServer.Disconnect(); }
                    catch (Exception) { }
                }
            }
        }

        /// <summary>
        /// Read one request, check who sent it and that it is sane, run it. Returns the status text, or null for "no reply".
        /// </summary>
        static String HandleClient(NamedPipeServerStream pipe, SecurityIdentifier owner)
        {
            const int MaxRequestChars = 32768;
            StringBuilder request = new StringBuilder();
            byte[] buffer = new byte[BufferSize];

            // Receive one message from the pipe (a stalled client is dropped after Timeout)
            do
            {
                Task<int> read = pipe.ReadAsync(buffer, 0, buffer.Length);
                if (!read.Wait(Timeout))
                {
                    Utils.Logging(OutLevel.Warn, "Client sent nothing for " + (Timeout / aSecond) + " s; dropped");
                    read.ContinueWith(t => { var ignored = t.Exception; });    // observe the failure the disconnect will cause
                    return null;
                }
                int count = read.Result;
                if (count == 0) break;
                request.Append(Encoding.Unicode.GetString(buffer, 0, count));
                if (request.Length > MaxRequestChars)
                {
                    Utils.Logging(OutLevel.Warn, "Request too long; dropped");
                    return "request too long";
                }
            }
            while (!pipe.IsMessageComplete);

            // Who is it? (impersonation only works after the first read.)  The access list already allows only the owner.
            SecurityIdentifier caller = null;
            try
            {
                pipe.RunAsClient(delegate { caller = WindowsIdentity.GetCurrent().User; });
            }
            catch (Exception ex)
            {
                Utils.Logging(OutLevel.Warn, "Cannot identify the caller: " + ex.Message);
                return "denied";
            }
            if (caller == null || !caller.Equals(owner))
            {
                Utils.Logging(OutLevel.Warn, "Refused a request from " + (caller == null ? "an unknown caller" : caller.Value));
                return "denied";
            }

            // Sane? The request is: working directory, TAB, command, TAB, arguments...
            String message = request.ToString().TrimEnd('\0');
            String[] parts = message.Split(Separator.ToCharArray()[0]);
            if (parts.Length < 2 || parts[1].Length == 0 || !Directory.Exists(parts[0]))
            {
                Utils.Logging(OutLevel.Warn, "Bad request (working directory missing or no command)");
                return "bad request";
            }

            Utils.Logging(OutLevel.Debug, "Received " + message.Length + " chars; Message: '" + message + "'");
            return RunIt(message);
        }
    }
}