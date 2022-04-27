//
// Options.cs
//

/*

REFERENCES

Microsoft.CSharp
System
System.Core
System.Data
System.Data.DataSetExtensions
System.Xml
System.Xml.Linq
System.Reflection.Context;   // me

USING

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Reflection;           // me
using System.Reflection.Context;   // me
 
 */

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

namespace CWP_Utils
{
    /////////////////////////////////////////////////////////////////////////////////

    public partial class MessageTipForm : Form
    {
        private System.Windows.Forms.Label message;
        private System.Windows.Forms.Timer myTimer;

        /// <summary>
        /// Required designer variable.
        /// </summary>
        private System.ComponentModel.IContainer components = null;

        /// <summary>
        /// Clean up any resources being used.
        /// </summary>
        /// <param name="disposing">true if managed resources should be disposed; otherwise, false.</param>
        protected override void Dispose(bool disposing)
        {
            if (disposing && (components != null))
            {
                components.Dispose();
            }
            base.Dispose(disposing);
        }

        #region Windows Form Designer generated code

        /// <summary>
        /// Required method for Designer support - do not modify
        /// the contents of this method with the code editor.
        /// </summary>
        private void InitializeComponent()
        {
            this.message = new System.Windows.Forms.Label();
            this.SuspendLayout();
            // 
            // message
            // 
            this.message.AutoSize = true;
            this.message.BackColor = System.Drawing.Color.LightYellow;
            this.message.BorderStyle = System.Windows.Forms.BorderStyle.FixedSingle;
            this.message.FlatStyle = System.Windows.Forms.FlatStyle.Popup;
            this.message.Font = new System.Drawing.Font("Microsoft Sans Serif", 8.5F, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point, ((byte)(0)));
            this.message.Location = new System.Drawing.Point(0, 0);
            this.message.Margin = new System.Windows.Forms.Padding(0);
            this.message.Name = "message";
            this.message.Padding = new System.Windows.Forms.Padding(10);
            this.message.Size = new System.Drawing.Size(138, 37);
            this.message.TabIndex = 0;
            this.message.Text = "message goes here";
            this.message.TextAlign = System.Drawing.ContentAlignment.MiddleCenter;
            this.message.Click += new System.EventHandler(this.message_Click);
            // 
            // MessageTipForm
            // 
            this.AutoScaleDimensions = new System.Drawing.SizeF(6F, 13F);
            this.AutoScaleMode = System.Windows.Forms.AutoScaleMode.Font;
            this.AutoSize = true;
            this.BackColor = System.Drawing.Color.LightYellow;
            this.ClientSize = new System.Drawing.Size(133, 29);
            this.ControlBox = false;
            this.Controls.Add(this.message);
            this.FormBorderStyle = System.Windows.Forms.FormBorderStyle.None;
            this.MaximizeBox = false;
            this.MinimizeBox = false;
            this.Name = "MessageTipForm";
            this.Opacity = 0.9D;
            this.ShowIcon = false;
            this.ShowInTaskbar = false;
            this.SizeGripStyle = System.Windows.Forms.SizeGripStyle.Hide;
            this.StartPosition = System.Windows.Forms.FormStartPosition.CenterScreen;
            this.Text = "Tip";
            this.TopMost = true;
            this.ResumeLayout(false);
            this.PerformLayout();

        }

        #endregion

        public MessageTipForm()
        {
            InitializeComponent();
            myTimer = MessageTip.TimerStart();
        }

        private void message_Click(object sender, EventArgs e)
        {
            this.Close();
            myTimer.Stop();
        }

        public void SetMessageText(String text)
        {
            message.Text = text;
        }
    }

    /// <summary>
    /// Timer class
    /// </summary>
    public static class MessageTip
    {
        private static System.Windows.Forms.Timer myTimer = new System.Windows.Forms.Timer();
        private static MessageTipForm myForm;
        private static int myDuration;

        // This is the method to run when the timer is raised. 
        private static void TimerEventProcessor(Object myObject, EventArgs myEventArgs)
        {
            myTimer.Stop();
            myForm.Close();
        }

        public static System.Windows.Forms.Timer TimerStart()
        {
            /* Adds the event and the event handler for the method that will 
               process the timer event to the timer. */
            myTimer.Tick += new EventHandler(TimerEventProcessor);

            // Sets the timer interval to 5 seconds.
            myTimer.Interval = myDuration;
            myTimer.Start();

            return (myTimer);
        }

        public static void Show(String message, int duration)
        {
            myDuration = duration;
            Application.EnableVisualStyles();
            //Application.SetCompatibleTextRenderingDefault(false);
            myForm = new MessageTipForm();
            myForm.SetMessageText(message);
            Application.Run(myForm);
        }
    }

    //////////////////////////////////////////////////////////////////

    public enum OptKind
    {
        Null,
        OptionalFlag,
        MandatoryFlag,
        OptionalArg,
        MandatoryArg
    }

    [AttributeUsage(AttributeTargets.Field)]
    public sealed class Metadata : Attribute
    {
        public OptKind Kind = OptKind.Null;
        public String LongName = null;
        public String UsageName = null;
        public String Description = null;
        public Int16 Position = -1;
        public bool Supplied = false;
        // default value
        public Type VarType;
        public Object VarValue;
    }

    public abstract class BaseGetOpts
    {
        // key for _flags Dictionary
        private class _key
        {
            public String SN; // ShortName
            public Int16 Pos; // Position
        }

        // key comparer for _flags Dictionary
        private sealed class _cmp : IEqualityComparer<_key>
        {
            public bool Equals(_key x, _key y)
            {
                if (ReferenceEquals(x, y)) return true;
                if (ReferenceEquals(x, null)) return false;
                if (ReferenceEquals(y, null)) return false;
                if (x.GetType() != y.GetType()) return false;
                return string.Equals(x.SN, y.SN) && x.Pos == y.Pos;
            }

            public int GetHashCode(_key obj)
            {
                unchecked
                {
                    return ((obj.SN != null ? obj.SN.GetHashCode() : 0) * 397) ^ obj.Pos;
                }
            }
        }

        // _flags Dictionary
        private Dictionary<_key, Metadata> _flags = new Dictionary<_key, Metadata>(new _cmp())
        {
            { new _key {SN="h",Pos=-1}, new Metadata {
                LongName = "Help",
                UsageName = "Help",
                Kind = OptKind.OptionalFlag,
                Description = "Show this help page",
                Position = -1,
                Supplied = false,
                VarType = typeof(Boolean),
                VarValue= (Object) false
            }},
        };

        // has Parsed been called yet?
        private bool _isParsed = false;
        private bool _parseResult = false;

        public bool IsParsed
        {
            get
            {
                return _isParsed;
            }
            set // throws MemberAccessException
            {
                throw new MemberAccessException("Parsed is a read-only property");
            }
        }
        public bool ParseResult
        {
            get
            {
                return _parseResult;
            }
            set // throws MemberAccessException
            {
                throw new MemberAccessException("Parsed is a read-only property");
            }
        }

        /// <summary>
        /// Constructors (Initializers)
        /// </summary>        
        public BaseGetOpts()
        {
            Initialize();
            List<String> _args = new List<string>(Environment.GetCommandLineArgs());
            _args.RemoveAt(0); // remove own prog name
            _parseResult = Parse(_args);
        }
        public BaseGetOpts(String[] args)
        {
            Initialize();
            List<String> _args = new List<string>(args);
            _parseResult = Parse(_args);
        }
        public BaseGetOpts(List<String> args)
        {
            Initialize();
            _parseResult = Parse(args);
        }

        /// <summary>
        /// Destructor (Finalizer)
        /// </summary>        
        ~BaseGetOpts()
        {
        }

        /// <summary>
        /// Initialize
        /// </summary>        
        private void Initialize()
        {
            var mytype = this.GetType();
            var mytypeinfo = mytype.GetTypeInfo();
            var props = mytypeinfo.DeclaredFields;
            bool propfound = false;

            foreach (var prop in props)
            {
                String flag = prop.Name;
                Type type = prop.FieldType;
                propfound = true;
                bool metafound = false;

                var attrs = prop.GetCustomAttributes(true);
                foreach (var attr in attrs)
                {
                    if (attr is Metadata)
                    {
                        Metadata a = (Metadata)attr;
                        String sn;
                        Int16 pos;
                        metafound = true;

                        if (a.Kind == OptKind.Null)
                            throw new FieldAccessException("Flags must have Kind set: " + flag);
                        if (a.Description == null)
                            throw new FieldAccessException("Flags must have Description set: " + flag);

                        if (a.Kind == OptKind.OptionalFlag || a.Kind == OptKind.MandatoryFlag)
                        {
                            sn = flag.Substring(0, 1).ToLower();
                            if (a.Position != -1)
                                throw new FieldAccessException("Flags must not have Position parameter: " + flag);
                            pos = -1;
                        }
                        else
                        {
                            sn = "_";
                            if (a.Position == -1)
                                throw new FieldAccessException("Arguments must have Position parameters: " + flag);
                            pos = a.Position;
                        }
                        _key fc = new _key { SN = sn, Pos = pos };
                        _flags[fc] = new Metadata()
                        {
                            LongName = flag,
                            UsageName = a.UsageName != null ? a.UsageName : flag,
                            Kind = a.Kind,
                            Description = a.Description,
                            Position = pos,
                            Supplied = false,
                            VarType = type,
                            VarValue = (Object)prop.GetValue(this)
                        };
                        prop.SetValue(this, null);  // would like to revert to unassigned
                    }
                }
                if (!metafound)
                    throw new FieldAccessException("Missing Metadata: " + flag);
            }
            if (!propfound)
                throw new FieldAccessException("No flags or args defined: " + this.ToString());
        }

        /// <summary>
        /// Display Usage
        /// </summary>        
        public void Usage()
        {
            var mytype = this.GetType();
            var mytypeinfo = mytype.GetTypeInfo();

            String usageStr =
                "Usage:\n" +
                "  " + Utils.ExeName + " ";
            foreach (var opt in _flags.Keys)
            {
                var data = _flags[opt];
                var name = data.UsageName;
                var desc = data.Description;
                var oarg = data.VarType == typeof(Boolean) ? "" : ":<" + name + ">";
                var dash = data.Kind == OptKind.MandatoryFlag || data.Kind == OptKind.OptionalFlag ? "-" : "";
                var opt2 = data.Kind == OptKind.MandatoryArg || data.Kind == OptKind.OptionalArg ? "<" + name + ">" : opt.SN + oarg;
                var opt3 = data.Kind == OptKind.OptionalArg || data.Kind == OptKind.OptionalFlag ? "[" + dash + opt2 + "]" : " " + dash + opt2 + " ";
                usageStr += "  " + opt3;
            }
            usageStr += "\nWhere:\n";
            foreach (var opt in _flags.Keys)
            {
                var data = _flags[opt];
                var name = data.UsageName;
                String defval = "";
                if (name == "Help")
                {
                    defval = " (default=False)";
                }
                else if (
                    (data.VarType == typeof(Boolean) || data.VarType == typeof(String)) &&
                    (data.Kind == OptKind.MandatoryFlag || data.Kind == OptKind.OptionalFlag)
                )
                {
                    if (data.VarValue == null)
                    {
                        defval = " (default=<null>)";
                    }
                    else
                    {
                        defval = " (default=" + data.VarValue.ToString() + ")";
                    }
                }
                var desc = data.Description;
                var oarg = data.VarType == typeof(Boolean) ? "" : ":<" + name + ">";
                var dash = data.Kind == OptKind.MandatoryFlag || data.Kind == OptKind.OptionalFlag ? "-" : " ";
                var opt2 = data.Kind == OptKind.MandatoryArg || data.Kind == OptKind.OptionalArg ? "<" + name + ">" : opt.SN + oarg;
                var opt3 = data.Kind == OptKind.OptionalArg || data.Kind == OptKind.OptionalFlag ? "[" + dash + opt2 + "]" : " " + dash + opt2 + " ";
                usageStr += "  " + opt3 + "   = " + desc + defval + "\n";
            }
            Utils.Logging(OutLevel.Info, usageStr);
        }

        /// <summary>
        /// Parse command line options
        /// </summary>
        private Boolean Parse(List<String> args) // throws MethodAccessException
        {
            String pat1 = @"^[-/]([a-z])$";
            String pat2 = @"^[-/]([a-z])[:=](.+)$";
            var mytype = this.GetType();
            var mytypeinfo = mytype.GetTypeInfo();

            if (_isParsed)
            {
                throw new MethodAccessException("Parse can only be called once");
            }
            else
            {
                _isParsed = true;
            }

            // parse flags
            while (args.Count > 0 && Regex.IsMatch(args[0], @"^[-/]"))
            {
                Match match1 = Regex.Match(args[0], pat1, RegexOptions.IgnoreCase);
                Match match2 = Regex.Match(args[0], pat2, RegexOptions.IgnoreCase);

                //////////////////////////////////////////////////
                // boolean flag
                if (match1.Success)
                {
                    _key fc = new _key { SN = match1.Groups[1].Value.ToLower(), Pos = -1 };
                    Boolean val = true;

                    // flag exists
                    if (_flags.ContainsKey(fc))
                    {
                        var meta = _flags[fc];
                        var prop = mytypeinfo.GetDeclaredField(meta.LongName);
                        // wrong kind
                        if (meta.Kind != OptKind.MandatoryFlag && meta.Kind != OptKind.OptionalFlag)
                        {
                            Utils.Logging(OutLevel.Fatal, "Not a flag: " + args[0]);
                            return (false);
                        }
                        // correct 
                        else if (meta.VarType == val.GetType())
                        {
                            if (fc.SN == "h")
                            {
                                Usage();
                                Environment.Exit(0);
                            }
                            else
                            {
                                prop.SetValue(this, val);
                                _flags[fc].Supplied = true;
                            }
                        }
                        // wrong type of flag
                        else
                        {
                            Utils.Logging(OutLevel.Fatal, "Wrong flag type: " + args[0]);
                            return (false);
                        }
                    }
                    // not a valid flag name
                    else
                    {
                        Utils.Logging(OutLevel.Fatal, "Illegal bool flag: " + args[0]);
                        return (false);
                    }
                }

                //////////////////////////////////////////
                // string flag
                else if (match2.Success)
                {
                    _key fc = new _key { SN = match2.Groups[1].Value.ToLower(), Pos = -1 };
                    String val = match2.Groups[2].Value;

                    // flag exists
                    if (_flags.ContainsKey(fc))
                    {
                        var meta = _flags[fc];
                        var prop = mytypeinfo.GetDeclaredField(meta.LongName);
                        // wrong kind
                        if (meta.Kind != OptKind.MandatoryFlag && meta.Kind != OptKind.OptionalFlag)
                        {
                            Utils.Logging(OutLevel.Fatal, "Not a flag: " + args[0]);
                            return (false);
                        }
                        // correct
                        else if (meta.VarType == val.GetType())
                        {
                            prop.SetValue(this, val);
                            _flags[fc].Supplied = true;
                        }
                        // wrong flag type
                        else
                        {
                            Utils.Logging(OutLevel.Fatal, "Wrong flag type: " + args[0]);
                            return (false);
                        }
                    }
                    // not a valid flag
                    else
                    {
                        Utils.Logging(OutLevel.Fatal, "Illegal val flag: " + args[0]);
                        return (false);
                    }
                }
                // poorly formatted flag
                else
                {
                    Utils.Logging(OutLevel.Fatal, "Illegal flag syntax: " + args[0]);
                    return (false);
                }
                // remove flag from list
                args.RemoveAt(0);
            }

            /////////////////////////////////////////
            // parse args now
            Int16 pos = 0;
            while (args.Count > 0)
            {
                _key fc = new _key { SN = "_", Pos = pos };

                // String arg
                if (
                    _flags.ContainsKey(fc) &&
                    pos == _flags[fc].Position &&
                    _flags[fc].VarType == typeof(String))
                {
                    String val = args[0];

                    var meta = _flags[fc];
                    var prop = mytypeinfo.GetDeclaredField(meta.LongName);
                    // wrong kind
                    if (meta.Kind != OptKind.MandatoryArg && meta.Kind != OptKind.OptionalArg)
                    {
                        Utils.Logging(OutLevel.Fatal, "Not an arg : " + args[0]);
                        return (false);
                    }
                    // correct
                    else if (val.Length > 0)
                    {
                        prop.SetValue(this, val);
                        _flags[fc].Supplied = true;
                    }
                    // empty
                    else
                    {
                        Utils.Logging(OutLevel.Fatal, "value empty: " + meta.LongName);
                        return (false);
                    }

                    // remove arg from list
                    pos++;
                    args.RemoveAt(0);
                }

                // List arg
                else if (
                    _flags.ContainsKey(fc) &&
                    pos == _flags[fc].Position &&
                    _flags[fc].VarType == typeof(List<String>)
                )
                {
                    List<String> val = new List<string>(args);

                    var meta = _flags[fc];
                    var prop = mytypeinfo.GetDeclaredField(meta.LongName);
                    // wrong kind
                    if (meta.Kind != OptKind.MandatoryArg && meta.Kind != OptKind.OptionalArg)
                    {
                        Utils.Logging(OutLevel.Fatal, "Not an arg: " + args[0]);
                        return (false);
                    }
                    // correct
                    else if (val.Count > 0)
                    {
                        prop.SetValue(this, val);
                        _flags[fc].Supplied = true;
                    }
                    // empty
                    else
                    {
                        Utils.Logging(OutLevel.Fatal, "value empty: " + meta.LongName);
                        return (false);
                    }

                    // empty the arg list
                    pos = -1;
                    args.Clear();
                }
                // bad news
                else
                {
                    Utils.Logging(OutLevel.Fatal, "Unexpected arg: " + args[0]);
                    return (false);
                }

            }

            foreach (var arg in _flags.Keys)
            {
                // need to look for missing mandatory flags and args
                if (
                    (_flags[arg].Kind == OptKind.MandatoryArg || _flags[arg].Kind == OptKind.MandatoryFlag) &&
                    (_flags[arg].Supplied != true)
                )
                {
                    Utils.Logging(OutLevel.Fatal, "Missing mandatory flag/arg: " + _flags[arg].LongName);
                    return (false);
                }
                // set default values
                if (_flags[arg].Supplied != true && _flags[arg].LongName != "Help")
                {
                    var prop = mytypeinfo.GetDeclaredField(_flags[arg].LongName);
                    prop.SetValue(this, _flags[arg].VarValue);
                }
            }

            // return
            return (true);
        }
    }

    // enum for Logging
    public enum OutLevel
    {
        Tip,
        Debug,
        Info,
        Warn,
        Error,
        Fatal
    }

    /// <summary>
    /// misc utils
    /// </summary>
    public static class Utils
    {
        public static String ExeName = "Unset";
        public static String ExeType = "Unset";
        public const int Timeout = 5000;  // 5 seconds
        public const int TipDelay = 3000; // 3 seconds

        /// <summary>
        /// Log messages to user
        /// </summary>
        public static void Logging(OutLevel level, String message)
        {
#if !DEBUG
            if (level == OutLevel.Debug)
            {
                return;
            }
#endif
            message = level + ": " + message;
#if DEBUG
            if (ExeType == "Exe")
            {
                  // This is a console application
                  Console.WriteLine(message);
            }
            else if (ExeType == "WinExe")
            {
                // This is a windows application in debug mode
                if (Debugger.IsAttached && Debugger.IsLogging())
                {
                    Debugger.Log(0, Debugger.DefaultCategory, Utils.ExeName + ": " + message);
                }
                else
                {
                    MessageTip.Show(Utils.ExeName + ": "+ message, TipDelay);
                }
            }
            else
            {
                Debug.Assert(false, "Illegal ExeType: " + ExeType);
            }
#else
            if (ExeType == "Exe")
            {
                // This is a console application
                Console.WriteLine(message);
            }
            else if (ExeType == "WinExe")
            {
                // This is a windows application in release mode

                // server app
                if (Utils.ExeName.ToLower().Contains("server"))
                {
                    // Test the source existance in event log
                    if (!EventLog.SourceExists(Utils.ExeName))
                    {
                        EventSourceCreationData es = new EventSourceCreationData(Utils.ExeName, "APPLICATION");
                        Thread.Sleep(Timeout);
                    }

                    // Create an EventLog instance and assign its source.
                    EventLog myLog = new EventLog();
                    myLog.Source = Utils.ExeName;

                    // Write an informational entry to the event log.    
                    myLog.WriteEntry(message);
                }
                // non-server app
                else
                {
                    // tip
                    if (level == OutLevel.Tip)
                    {
                        MessageTip.Show(message, TipDelay);
                    }
                    else
                    {
                        MessageBox.Show(message, Utils.ExeName);
                    }
                }
            }
            else
            {
                Trace.Assert(false, "Illegal ExeType: " + ExeType);
            }
#endif
        }
    }

}