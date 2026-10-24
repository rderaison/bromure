//go:build !windows

package netmon

const notifySupported = false

// startNotify: no push notification here; the monitor polls.
func startNotify(kick func()) func() { return func() {} }
