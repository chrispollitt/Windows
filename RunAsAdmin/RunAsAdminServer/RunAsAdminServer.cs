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
using System.Text;
using System.Threading;
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
        /// Named pipe server through BCL System.IO.Pipes
        /// </summary>
        static void PipeServer()
        {
            NamedPipeServerStream pipeServer = null;

            try
            {
                /////////////////////////////////////////////////////////////////
                // Create a named pipe.
                // 

                // Prepare the security attributes
                // Granting everyone the full control of the pipe is just for 
                // demo purpose, though it creates a security hole.
                PipeSecurity pipeSa = new PipeSecurity();
                pipeSa.SetAccessRule(new PipeAccessRule("Everyone",
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
                //pipeServer.ReadTimeout = Timeout;
                //pipeServer.WriteTimeout = Timeout;

                Utils.Logging(OutLevel.Debug, "The named pipe, " + PipeName + ", is created");
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
                    /////////////////////////////////////////////////////////////////
                    // Wait for the client to connect.
                    // 

                    Utils.Logging(OutLevel.Debug, "Waiting for the client's connection...");
                    pipeServer.WaitForConnection();

                    /////////////////////////////////////////////////////////////////
                    // Read client requests from the pipe and write the response.
                    // 

                    // A byte buffer of BufferSize bytes. The buffer should be big 
                    // enough for ONE request from a client.
                    String result;

                    // Receive one message from the pipe.
                    String strMessage = String.Empty;

                    do
                    {
                        if (pipeServer.CanRead)
                        {
                            byte[] bRequest = new byte[BufferSize];// Client -> Server
                            String str;
                            int cbBytesRead, cbRequestBytes;

                            cbRequestBytes = BufferSize;
                            cbBytesRead = pipeServer.Read(bRequest, 0, cbRequestBytes);

                            str = Encoding.Unicode.GetString(bRequest).TrimEnd('\0');
                            if (str.Length > 0)
                            {
                                Utils.Logging(OutLevel.Debug, "Received " + cbBytesRead.ToString() + " bytes; Message: '" + str + "'");
                                strMessage += str;
                            }
                        }
                    }
                    while (!pipeServer.IsMessageComplete);

                    // Run it
                    result = RunIt(strMessage);

                    // Prepare the response.
                    byte[] bReply;                          // Server -> Client
                    int cbBytesWritten, cbReplyBytes;

                    strMessage = StatusPrefix + result;
                    bReply = Encoding.Unicode.GetBytes(strMessage);
                    cbReplyBytes = bReply.Length;

                    // Write the response to the pipe.

                    if (pipeServer.CanWrite)
                    {
                        pipeServer.Write(bReply, 0, cbReplyBytes);
                    }

                    // If no IO exception is thrown from Write, number of bytes 
                    // written (cbBytesWritten) != -1.
                    cbBytesWritten = cbReplyBytes;

                    Utils.Logging(OutLevel.Debug, "Replied " + cbBytesWritten.ToString() + " bytes; Message: '" + strMessage + "'");
                }
                catch (Exception ex)
                {
                    Utils.Logging(OutLevel.Error, "The server throws the error: " + ex.Message);
                }
                finally
                {
                    /////////////////////////////////////////////////////////////////
                    // Flush the pipe to allow the client to read the pipe's contents 
                    // before disconnecting. disconnect the pipe.
                    // 
                    pipeServer.Flush();
                    pipeServer.Disconnect();
                    Thread.Sleep(Timeout);
                }
            }
        }
    }
}