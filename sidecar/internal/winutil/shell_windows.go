//go:build windows

package winutil

import (
	"os/exec"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

var (
	user32               = windows.NewLazySystemDLL("user32.dll")
	procMessageBoxW      = user32.NewProc("MessageBoxW")
	procOpenClipboard    = user32.NewProc("OpenClipboard")
	procCloseClipboard   = user32.NewProc("CloseClipboard")
	procEmptyClipboard   = user32.NewProc("EmptyClipboard")
	procSetClipboardData = user32.NewProc("SetClipboardData")
	kernel32             = windows.NewLazySystemDLL("kernel32.dll")
	procGlobalAlloc      = kernel32.NewProc("GlobalAlloc")
	procGlobalLock       = kernel32.NewProc("GlobalLock")
	procGlobalUnlock     = kernel32.NewProc("GlobalUnlock")
	procCreateMutexW     = kernel32.NewProc("CreateMutexW")
)

// Message box flags.
const (
	MBOK          = 0x0
	MBOKCancel    = 0x1
	MBYesNo       = 0x4
	MBIconInfo    = 0x40
	MBIconWarning = 0x30
	MBIconError   = 0x10
	MBTopMost     = 0x40000
	IDOK          = 1
	IDYes         = 6
)

// MessageBox shows a modal box; the button pressed.
func MessageBox(title, text string, flags uint32) int {
	t, _ := windows.UTF16PtrFromString(text)
	c, _ := windows.UTF16PtrFromString(title)
	r, _, _ := procMessageBoxW.Call(0, uintptr(unsafe.Pointer(t)), uintptr(unsafe.Pointer(c)), uintptr(flags|MBTopMost))
	return int(r)
}

// SetClipboard puts text on the clipboard.
func SetClipboard(text string) error {
	u, err := windows.UTF16FromString(text)
	if err != nil {
		return err
	}
	if r, _, err := procOpenClipboard.Call(0); r == 0 {
		return err
	}
	defer procCloseClipboard.Call()
	procEmptyClipboard.Call()
	const gmemMoveable = 0x0002
	size := uintptr(len(u) * 2)
	h, _, err := procGlobalAlloc.Call(gmemMoveable, size)
	if h == 0 {
		return err
	}
	p, _, err := procGlobalLock.Call(h)
	if p == 0 {
		return err
	}
	copy(unsafe.Slice(*(**uint16)(unsafe.Pointer(&p)), len(u)), u)
	procGlobalUnlock.Call(h)
	const cfUnicodeText = 13
	if r, _, err := procSetClipboardData.Call(cfUnicodeText, h); r == 0 {
		return err
	}
	return nil
}

// OpenURL opens a link in the default browser.
func OpenURL(u string) error {
	verb, _ := windows.UTF16PtrFromString("open")
	file, _ := windows.UTF16PtrFromString(u)
	return windows.ShellExecute(0, verb, file, nil, nil, windows.SW_SHOWNORMAL)
}

// SingleInstance holds a named mutex; false when another process has it.
func SingleInstance(name string) bool {
	n, _ := windows.UTF16PtrFromString(`Local\` + name)
	h, _, err := procCreateMutexW.Call(0, 0, uintptr(unsafe.Pointer(n)))
	if h == 0 {
		return false
	}
	return err != windows.ERROR_ALREADY_EXISTS
}

// --- registry (HKCU only: no admin) -----------------------------------------

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

// RegisterURLScheme points scheme:// at exe "%1".
func RegisterURLScheme(scheme, exe, description string) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, `Software\Classes\`+scheme, registry.ALL_ACCESS)
	if err != nil {
		return err
	}
	defer k.Close()
	if err := k.SetStringValue("", "URL:"+description); err != nil {
		return err
	}
	if err := k.SetStringValue("URL Protocol", ""); err != nil {
		return err
	}
	c, _, err := registry.CreateKey(registry.CURRENT_USER, `Software\Classes\`+scheme+`\shell\open\command`, registry.ALL_ACCESS)
	if err != nil {
		return err
	}
	defer c.Close()
	return c.SetStringValue("", `"`+exe+`" "%1"`)
}

// SetStartAtLogin adds or removes the HKCU Run entry.
func SetStartAtLogin(name, exe string, on bool) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.ALL_ACCESS)
	if err != nil {
		return err
	}
	defer k.Close()
	if !on {
		err := k.DeleteValue(name)
		if err == registry.ErrNotExist {
			return nil
		}
		return err
	}
	return k.SetStringValue(name, `"`+exe+`"`)
}

// StartsAtLogin reports whether the Run entry exists.
func StartsAtLogin(name string) bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	_, _, err = k.GetStringValue(name)
	return err == nil
}

// --- consoles ----------------------------------------------------------------

// OpenTerminal runs argv in a new terminal window: Windows Terminal when
// it's there, else a classic console.
func OpenTerminal(title string, argv ...string) error {
	if wt, err := exec.LookPath("wt.exe"); err == nil {
		cmd := exec.Command(wt, append([]string{"--title", title, "--"}, argv...)...)
		if err := cmd.Start(); err == nil {
			return cmd.Process.Release()
		}
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	const createNewConsole = 0x00000010
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNewConsole}
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

// QuoteArg is one argument for a command line.
func QuoteArg(s string) string {
	if s != "" && !strings.ContainsAny(s, " \t\"") {
		return s
	}
	return syscall.EscapeArg(s)
}

var (
	procGetClipboardData = user32.NewProc("GetClipboardData")
)

// GetClipboard is the clipboard's text ("" when none).
func GetClipboard() string {
	if r, _, _ := procOpenClipboard.Call(0); r == 0 {
		return ""
	}
	defer procCloseClipboard.Call()
	const cfUnicodeText = 13
	h, _, _ := procGetClipboardData.Call(cfUnicodeText)
	if h == 0 {
		return ""
	}
	p, _, _ := procGlobalLock.Call(h)
	if p == 0 {
		return ""
	}
	defer procGlobalUnlock.Call(h)
	return windows.UTF16PtrToString(*(**uint16)(unsafe.Pointer(&p)))
}
