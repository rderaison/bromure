package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"

	"github.com/rderaison/bromure/sidecar/internal/account"
	"github.com/rderaison/bromure/sidecar/internal/control"
	"github.com/rderaison/bromure/sidecar/internal/settings"
	"github.com/rderaison/bromure/sidecar/internal/sshdial"
	"github.com/rderaison/bromure/sidecar/internal/sshserver"
	"github.com/rderaison/bromure/sidecar/internal/winopen"
)

// acct adapts internal/account to the verbs.
type acct struct{ a *account.Account }

func toMap(v any) map[string]any {
	data, _ := json.Marshal(v)
	m := map[string]any{}
	_ = json.Unmarshal(data, &m)
	return m
}

func (x acct) Status() map[string]any       { return toMap(x.a.Status()) }
func (x acct) BeginSignIn() (string, error) { return x.a.BeginSignIn() }
func (x acct) SignOut()                     { x.a.SignOut() }
func (x acct) RefreshServers()              { x.a.RefreshServers() }
func (x acct) Stop()                        { x.a.Close() }

// Complete enrolls with a handed-back link (it talks to bromure.io);
// a link we didn't start is refused.
func (x acct) Complete(raw string) error {
	err := x.a.Complete(raw)
	if errors.Is(err, account.ErrNotOurs) {
		return errors.New("that sign-in link wasn't started here — start the sign-in " +
			"again on this machine (the Sidecar menu, or `bromure-sidecar enroll`)")
	}
	return err
}

func (x acct) Servers() []map[string]any {
	out := []map[string]any{}
	for _, s := range x.a.Servers() {
		m := toMap(s)
		m["user"] = s.SSHUsername
		out = append(out, m)
	}
	return out
}

var theAccount *account.Account

// startAccount brings up the bromure.io account: enrollment, key sync,
// relay-only serving of the loopback SSH server.
func startAccount(r *remote) accountAPI {
	theAccount = account.New(account.Config{
		SSHPort:         settings.SSHPortValue(),
		MachineName:     control.MachineName,
		UserName:        userName(),
		ClientPublicKey: sshdial.ClientPublicKeyLine,
		SetManagedKeys:  sshserver.SetManagedKeys,
		OpenURL:         winopen.URL,
	})
	theAccount.Start()
	return acct{theAccount}
}

// accountDialer is the P2P dialer MachineLinker uses to reach an account
// server's SSH port.
func accountDialer(r *remote) func(ctx context.Context, deviceID string) (net.Conn, error) {
	return func(ctx context.Context, deviceID string) (net.Conn, error) {
		if theAccount == nil {
			return nil, errors.New("not signed in to bromure.io")
		}
		return theAccount.Dial(ctx, deviceID)
	}
}
