///////////////////////////////////////////////
// Run Remote Server
///////////////////////////////////////////////

// Package
package main

import "runtime/debug"

// Imports
import (
	"os"
	"os/exec"
	"path/filepath"
	"bufio"
	"fmt"
	"net"
	"strings"
	"io/ioutil"

	"gopkg.in/natefinch/npipe.v2"
	"github.com/janmir/go-wintask"
	
	. "./RunRemLib"
)

// Use Listen to start a server, and accept connections with Accept().
func RunRemListen() {
	host := "."
	pipe := `\\`+host+`\pipe\` + PipeName
	
	os.Chdir(os.TempDir())
	ln, err := npipe.Listen(pipe)
	if err != nil {
		HandleError(err)
		return
	}

	for {
		conn, err := ln.Accept()
		if err != nil {
			HandleError(err)
			continue
		}

		// handle connection like any other net.Conn
		go func(conn net.Conn) {
			r := bufio.NewReader(conn)
			msgin, err := r.ReadString('\n')
			if err != nil {
				HandleError(err)
				return
			}
			msgin = strings.TrimSpace(msgin)
//fmt.Println("server: "+msgin)
			if strings.Contains(msgin, "~~") {
				msginA := strings.SplitN(msgin, "~~", 2)
				msgin = "cmd /c " + msginA[0]
				tmpCont := strings.Replace(msginA[1], "~~", "\n", -1)
				err = ioutil.WriteFile(msginA[0], []byte(tmpCont), 0755)
				if err != nil {
					HandleError(err)
					return
				}
			}
			cmdA := strings.Split(msgin, " ")
			cmd  := cmdA[0]
			cmdA  = cmdA[1:]
//fmt.Println("PATH="+os.Getenv(`PATH`))
			execout, err := exec.Command(cmd, cmdA...).CombinedOutput()
			if err != nil {
				HandleError(err)
			}
			msgout := string(execout)
			msgout = strings.TrimSpace(msgout)
			msgout = strings.Replace(msgout, "\n", "~~", -1)
//fmt.Println("server: "+msgout)
			_, err = fmt.Fprintln(conn, msgout)
			if err != nil {
				HandleError(err)
			}
		}(conn)
	}
}

// Install server and start
func RunRemInstall() {
	// Vars
	ExeFile    := SrvPath + `\` + SrvExe + `.exe`
	ExeFileJS  := strings.Replace(ExeFile, `\`, `\\`, -1)
	XMLFile    := SrvPath + `\` + SrvExe + `.xml`
	JSFile     := SrvPath + `\` + SrvExe + `.js`
	argv0, _   := os.Executable()
	taskObj    := tasker.New(true)
	taskXML    := `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2019-02-18T16:05:00.5451915</Date>
    <Author>`+UserNameD+`</Author>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>`+UserNameD+`</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>`+UserNameD+`</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript</Command>
      <Arguments>`+JSFile+`</Arguments>
      <WorkingDirectory>`+SrvPath+`\</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
`
	taskWScript := `// WScript Wrapper //
var Prog         = '`+ExeFileJS+`';
var Hide         = 0;
var WindowStyle  = Hide;
var WaitOnReturn = true;
var WSobj        = WScript.CreateObject("WScript.Shell");
WSobj.Run(Prog, WindowStyle, WaitOnReturn);
`
		
	// Copy .exe (if needed)
	myName    := filepath.Base(argv0)
	myDir, _  := filepath.Abs(filepath.Dir(argv0))
	if _, err := os.Stat(ExeFile); err != nil {
		os. Mkdir(SrvPath, 0755)
		CopyFile(myDir + `\` + myName, ExeFile)
		err = ioutil.WriteFile(XMLFile, []byte(taskXML), 0755)
		if err != nil {HandleError(err)}
		err = ioutil.WriteFile(JSFile, []byte(taskWScript), 0755)
		if err != nil {HandleError(err)}
	}
	
	// Query
	outputO := taskObj.Query(TaskName)

	// Create task (if needed)
	if len(outputO) == 0 {
		output := taskObj.Create(tasker.TaskCreate{
			Taskname:	TaskName,
			XMLFile:	XMLFile,
		})
		fmt.Printf("%+v\n", output)
	}
	
	// Query
	outputO = taskObj.Query(TaskName)

	// Run task (if needed)
	if outputO[0].Status != "Running" {
		output := taskObj.Run(TaskName)
		fmt.Printf("%+v\n", output)
	}	
}

// Uninstall server and start
func RunRemUninstall() {
	// Vars
	taskObj := tasker.New(true)

	// Stop
	output := taskObj.End(TaskName)
	fmt.Printf("%+v\n", output)

	// Delete Task
	output = taskObj.Delete(TaskName, true)
	fmt.Printf("%+v\n", output)
	
	// Delete path
	os.RemoveAll(SrvPath)
}

// Print Usage
func Usage() {
	fmt.Println(`
Usage:
  `+SrvExe+` [{-i,-u}]
Where:
  -i = install
  -u = uninstall
`)
	os.Exit(1)
}

// Main
func main() {
	args := os.Args
	if len(args) == 2 {
		if args[1] == "-i" {
			RunRemInstall()
		} else if args[1] == "-u" {
			RunRemUninstall()
		} else {
			Usage()
		}
	} else if len(args) == 1 {
		RunRemListen()
	} else {
		Usage()
	}
}
