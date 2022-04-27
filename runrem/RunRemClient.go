///////////////////////////////////////////////
// Run Rem Client
///////////////////////////////////////////////

// Package
package main

// Imports
import (
	"os"
	"bufio"
	"fmt"
	"strings"
	"io/ioutil"

	"gopkg.in/natefinch/npipe.v2"
	
	. "./RunRemLib"
)

// Use Dial to connect to a server and read messages from it.
func RunRemDial(host string, cmd string) {
	pipe   := `\\`+host+`\pipe\` + PipeName
	msgout := cmd

	conn, err := npipe.Dial(pipe)
	if err != nil {
		HandleError(err)
	}
	_, err = fmt.Fprintln(conn, msgout)
	if err != nil {
		HandleError(err)
	}
	r := bufio.NewReader(conn)
	msgin, err := r.ReadString('\n')
	if err != nil {
		HandleError(err)
	}
	msgin = strings.TrimSpace(msgin)
	msgin = strings.Replace(msgin, "~~", "\n", -1)
	fmt.Println(msgin)
}

// Loop over remote hosts
func LoopOverHosts(host string, cmd string) {
	hosts := []string{ host }
	// expand hosts
	if _, err := os.Stat(host); err == nil {
		hostsC, err := ioutil.ReadFile(host)
		if err != nil {
			HandleError(err)
		}
		hosts = strings.Split(string(hostsC), "\n")
	}
	// copy script
	if _, err := os.Stat(cmd); err == nil {
		cmdC, err := ioutil.ReadFile(cmd)
		if err != nil {
			HandleError(err)
		}
		cmd += "~~" + strings.Replace(string(cmdC), "\n", "~~", -1)
	}
	// loop over hosts
	for _, host := range hosts {
		host = strings.TrimSpace(host)
		if len(host) > 0 {
			fmt.Println("======"+host)
			RunRemDial(host, cmd)
		}
	}
}

// Print Usage
func Usage() {
	fmt.Println(`
Usage:
  RunRemClient <host> <program>
Where:
  <host>    = hostname OR file with list of hostnames
  <program> = .exe (must exist on remote machine) OR .cmd (copied first)
`)
	os.Exit(1)
}

// Main
func main() {
	args := os.Args
	if len(args) != 3 {
		Usage()
	}
	host := args[1]
	cmd  := args[2]
	LoopOverHosts(host, cmd)
}
