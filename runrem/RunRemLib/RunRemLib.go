package RunRemLib

import (
	"fmt"
	"os"
	"io"
	"path/filepath"
)

var (
	TaskName   = `RunRem`
	PipeName   = TaskName
	SrvExe     = TaskName + `Server`
	SrvPath    = os.Getenv(`LOCALAPPDATA`) + `\` + TaskName
	UserName   = os.Getenv(`USERNAME`)
	UserDomain = os.Getenv(`USERDOMAIN`)
	UserNameD  = UserName         // UserDomain+`\`+UserName
)

func HandleError(err error) {
	fmt.Fprintf(os.Stderr, "error: %+v\n", err)
}

// CopyFile copies the contents of the file named srcName to the file named
// dstName. The file will be created if it does not already exist. If the
// destination file exists, all it's contents will be replaced by the contents
// of the source file.
func CopyFile(srcName, dstName string) (err error) {
	srcBase := filepath.Base(srcName)
	if fs, err := os.Stat(dstName); err == nil && fs.IsDir() {
		dstName += `\` + srcBase
	}
    srcFH, err := os.Open(srcName)
    if err != nil {
        HandleError(err)
    }
    defer srcFH.Close()
    dstFH, err := os.Create(dstName)
    if err != nil {
        HandleError(err)
    }
    defer func() {
        cerr := dstFH.Close()
        if err == nil {
            err = cerr
        }
    }()
    if _, err = io.Copy(dstFH, srcFH); err != nil {
        HandleError(err)
    }
    err = dstFH.Sync()
    return
}
