/****************************** Module Header ******************************\
* Module Name:	RunAsAdminClient.cs
* Project:		RunAsAdmin
* Makes use of:
*   https://taskscheduler.codeplex.com/
* 
\***************************************************************************/

#region Using directives
using CWP_Utils;
using System;
using System.IO;
using System.IO.Pipes;
//using System.Linq;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
#endregion

[assembly: AssemblyVersion("1.0.0.0")]
namespace RunAsAdmin
{

    class RunAsAdminClient : Global
    {
        static String UserProg;

        /// <summary>
        /// Main
        /// </summary>
        [STAThread]
        static void Main(String[] args)
        {
            Utils.ExeName = ClientExe;
#if TARGET_EXE
            Utils.ExeType = "Exe";
#elif TARGET_WINEXE
            Utils.ExeType = "WinExe";
#else
#error "neither TARGET_EXE nor TARGET_WINEXE defined"
#endif
            String strMessage;

            // get cwd, concat with argv
            String MyCWD = Directory.GetCurrentDirectory();
            strMessage = MyCWD + Separator + String.Join(Separator, args);

            // create opts object
            Opts = new GetOpts(args);

            // check command line args
            if (!Opts.ParseResult)
            {
                Opts.Usage();
                Environment.Exit(1);
            }

#if !DEBUG2
            // if already adamin and server is local, run it myself
            if (AmIAdmin && ServerName == ".")
            {
                String result;

                Utils.Logging(OutLevel.Debug, "Already elevated, just launching");
                // Just Run it
                result = RunIt(strMessage);
                UserProg = Regex.Replace(Opts.Command, @"^.*\\", "");

                // test status
                if (result != StatusSuccess)
                {
                    Utils.Logging(OutLevel.Error, "Direct launch of '" + UserProg + "' failed: " + result);
                }
                else
                {
                    Utils.Logging(OutLevel.Tip, "Direct launch of '" + UserProg + "' succeeded!");
                }
            }

            // run it via the server
            else
#endif
            {
                UserProg = Regex.Replace(Opts.Command, @"^.*\\", "");

#if !DEBUG1
                // ping server
                PingServer();
#endif

                // send message
                PipeClient(strMessage);
            }
        }

        /// <summary>
        /// Named pipe server through BCL System.IO.Pipes
        /// </summary>
        static void PipeClient(String strMessage)
        {

            /////////////////////////////////////////////////////////////////////
            // Try to open a named pipe.
            // 

            NamedPipeClientStream pipeClient = null;

            try
            {
                pipeClient = new NamedPipeClientStream(
                    ServerName,                 // The server name
                    PipeName,                   // The unique pipe name
                    PipeDirection.InOut,        // The pipe is bi-directional   
                    PipeOptions.None,           // No additional parameters
                                                //The server process cannot obtain identification information about 
                                                //the client, and it cannot impersonate the client.
                    TokenImpersonationLevel.Identification
                );

                pipeClient.Connect(Timeout); // set TimeOut for connection
                pipeClient.ReadMode = PipeTransmissionMode.Message;
                //pipeClient.ReadTimeout = Timeout;
                //pipeClient.WriteTimeout = Timeout;

                Utils.Logging(OutLevel.Debug, @"The named pipe, \\" + ServerName + @"\" + PipeName + ", is connected.");


                /////////////////////////////////////////////////////////////////
                // Send a message to the pipe server and receive its response.
                //                

                // A byte buffer of BufferSize bytes. The buffer should be big 
                // enough for ONE request to the client

                byte[] bRequest;                        // Client -> Server
                int cbRequestBytes;

                // Send one message to the pipe.

                bRequest = Encoding.Unicode.GetBytes(strMessage);
                cbRequestBytes = bRequest.Length;
                if (pipeClient.CanWrite)
                {
                    pipeClient.Write(bRequest, 0, cbRequestBytes);
                }
                pipeClient.Flush();

                Utils.Logging(OutLevel.Debug, "Sent " + cbRequestBytes.ToString() + " bytes; Message: '" + strMessage + "'");

                // Receive one message from the pipe.
                strMessage = String.Empty;
                int loopCount = 0;
                int loopSleep = 50;
                int loopMax = (aSecond * 5) / loopSleep;

                do
                {
                    if (pipeClient.CanRead)
                    {
                        byte[] bReply = new byte[BufferSize];  // Server -> Client
                        String str;
                        int cbBytesRead, cbReplyBytes;

                        cbReplyBytes = BufferSize;
                        cbBytesRead = pipeClient.Read(bReply, 0, cbReplyBytes);

                        str = Encoding.Unicode.GetString(bReply).TrimEnd('\0');
                        if (str.Length > 0)
                        {
                            Utils.Logging(OutLevel.Debug, "Received " + cbBytesRead.ToString() + " bytes; Message: '" + str + "'");
                            strMessage += str;
                        }
                    }
                    Thread.Sleep(loopSleep);
                }
                while ((strMessage.Length == 0) && (loopCount++ < loopMax));
                Utils.Logging(OutLevel.Debug, "loopCount=" + loopCount + " length=" + strMessage.Length);

                // test status
                if (strMessage != StatusPrefix + StatusSuccess)
                {
                    Utils.Logging(OutLevel.Error, "Proxy launch of '" + UserProg + "' failed: '" + strMessage + "'");
                }
                else
                {
                    Utils.Logging(OutLevel.Tip, "Proxy launch of '" + UserProg + "' succeeded!");
                }

            }
            catch (TimeoutException ex)
            {
                Utils.Logging(OutLevel.Fatal, @"Unable to open named pipe \\" + ServerName + @"\" + PipeName + ": " + ex.Message);
            }
            catch (Exception ex)
            {
                Utils.Logging(OutLevel.Fatal, "The client threw the error: " + ex.Message);
            }
            finally
            {
                /////////////////////////////////////////////////////////////////
                // Close the pipe.
                // 
                if (pipeClient != null)
                    pipeClient.Close();
            }
        }
    }
}