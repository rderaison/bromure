using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit 08 §1.2: per-user single-instance enforcement to prevent
/// two Bromure.AC.exe processes racing the per-profile VHDX clone
/// path (HCS doesn't lock the parent). These tests pin the
/// behaviour by exercising the mutex+pipe handshake within a single
/// test process — sufficient because the real cross-process scenario
/// is just two acquires hitting the same named kernel object.
/// </summary>
public class SingleInstanceGuardTests
{
    [Fact]
    public void Acquire_FirstInstance_OwnsMutex()
    {
        using var guard = SingleInstanceGuard.Acquire();
        guard.IsFirstInstance.Should().BeTrue();
    }

    [Fact]
    public async Task Acquire_SecondAttempt_DoesNotOwn()
    {
        using var first = SingleInstanceGuard.Acquire();
        first.IsFirstInstance.Should().BeTrue();

        // Named Mutexes are owned PER-THREAD within a process — a
        // recursive acquire on the same thread succeeds. In
        // production the second instance is a different process, so
        // it's a different thread either way. Simulate that here by
        // running the second Acquire on a dedicated task thread.
        var secondResult = await Task.Run(() =>
        {
            using var second = SingleInstanceGuard.Acquire();
            return second.IsFirstInstance;
        });
        secondResult.Should().BeFalse("the named mutex is already held by `first` on the test thread");
    }

    [Fact]
    public void SignalExisting_WhenNoServerRunning_ReturnsFalse()
    {
        // Acquire and immediately dispose so no pipe server is up.
        using (SingleInstanceGuard.Acquire()) { }

        var ok = SingleInstanceGuard.SignalExisting(TimeSpan.FromMilliseconds(200));
        ok.Should().BeFalse("there is no server listening on the activation pipe");
    }

    [Fact]
    public async Task SignalExisting_FiresActivationCallback_OnTheServerInstance()
    {
        using var guard = SingleInstanceGuard.Acquire();
        guard.IsFirstInstance.Should().BeTrue();

        var hit = new TaskCompletionSource();
        guard.StartActivationServer(() => hit.TrySetResult());

        // Give the server a tick to spin up its pipe before we dial.
        await Task.Delay(100);

        var ok = SingleInstanceGuard.SignalExisting(TimeSpan.FromSeconds(2));
        ok.Should().BeTrue();

        var fired = await Task.WhenAny(hit.Task, Task.Delay(2000));
        fired.Should().BeSameAs(hit.Task, "the activation callback must fire when the pipe receives a byte");
    }

    [Fact]
    public void ChannelName_IncludesUserScope()
    {
        var name = SingleInstanceGuard.ChannelName();
        name.Should().StartWith("Bromure.AC-Singleton-");
        // Must contain SOMETHING after the prefix — a SID or username.
        name.Length.Should().BeGreaterThan("Bromure.AC-Singleton-".Length);
    }
}
