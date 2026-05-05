using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;

namespace Bromure.AC.Display;

/// <summary>
/// HwndHost wrapper that reparents a WSLg-rendered Linux GUI window
/// (kitty by default) into our WPF surface. WSLg presents Linux
/// Wayland/X11 clients as native Windows HWNDs via an RDP-RAIL
/// bridge owned by <c>msrdc.exe</c>; we find the right RAIL window
/// by its title prefix (we asked kitty to use a unique per-session
/// title) and SetParent it into our <see cref="HwndHost"/>.
///
/// <para>Replaces the QEMU-port <c>QemuWindowHost</c>. Differences:</para>
/// <list type="bullet">
///   <item>The foreign HWND owner is <c>msrdc.exe</c>/<c>wslg.exe</c>,
///   not our spawned <c>wsl.exe</c>. Match by title, not PID.</item>
///   <item>Win32 keyboard messages reach RAIL windows the normal
///   way — no QMP-style injection. We only need the click-to-focus
///   nudge so the WPF host reclaims keyboard focus when the user
///   clicks back into the embed.</item>
///   <item>No GTK chrome to clip; RAIL windows are typically already
///   stripped by WSLg.</item>
/// </list>
/// </summary>
public sealed class WslWindowHost : HwndHost
{
    public WslWindowHost()
    {
        Focusable = true;
        // Pull WPF focus on first click. Clicks INSIDE the foreign
        // child go straight to it, so we also hook WM_PARENTNOTIFY in
        // WndProc below to reclaim focus on subsequent clicks.
        MouseLeftButtonDown += (_, _) => Focus();
    }

    private const int WS_CHILD = 0x40000000;
    private const int WS_VISIBLE = 0x10000000;
    private const int WS_POPUP = unchecked((int)0x80000000);
    private const int GWL_STYLE = -16;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_FRAMECHANGED = 0x0020;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const uint RDW_INVALIDATE = 0x0001;
    private const uint RDW_ERASE = 0x0004;
    private const uint RDW_FRAME = 0x0400;
    private const uint RDW_ALLCHILDREN = 0x0080;

    private const int WM_ACTIVATE = 0x0006;
    private const int WM_NCACTIVATE = 0x0086;
    private const int WA_ACTIVE = 1;
    private const int WM_PARENTNOTIFY = 0x0210;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_RBUTTONDOWN = 0x0204;

    private IntPtr _guestWindow;
    private IntPtr _placeholder;
    private IntPtr _previousParent;
    private int _previousStyle;

    /// <summary>
    /// Find the Linux GUI window whose title starts with
    /// <paramref name="titlePrefix"/> and reparent it into us.
    /// kitty's <c>--title</c> sets the initial title; we match that
    /// to disambiguate concurrent sessions.
    /// </summary>
    public bool Attach(string titlePrefix, TimeSpan timeout)
    {
        if (Handle == IntPtr.Zero) return false;
        var deadline = DateTime.UtcNow + timeout;
        IntPtr hwnd = IntPtr.Zero;
        while (DateTime.UtcNow < deadline)
        {
            hwnd = FindWindowByTitlePrefix(titlePrefix);
            if (hwnd != IntPtr.Zero) break;
            System.Threading.Thread.Sleep(100);
        }
        if (hwnd == IntPtr.Zero) return false;

        _guestWindow = hwnd;
        _previousParent = GetParent(hwnd);
        _previousStyle = GetWindowLong(hwnd, GWL_STYLE);

        // Same minimal style change as the QEMU port: only flip
        // WS_POPUP→WS_CHILD. Aggressive chrome stripping caused white
        // screens with GDK/GTK and might do the same with RAIL — keep
        // it minimal.
        var newStyle = (_previousStyle & ~WS_POPUP) | WS_CHILD;
        SetWindowLong(hwnd, GWL_STYLE, newStyle);

        SetParent(hwnd, Handle);
        ResizeChildToHost();

        SendMessage(hwnd, WM_ACTIVATE, (IntPtr)WA_ACTIVE, IntPtr.Zero);
        SendMessage(hwnd, WM_NCACTIVATE, (IntPtr)1, IntPtr.Zero);
        SetFocus(hwnd);
        RedrawWindow(hwnd, IntPtr.Zero, IntPtr.Zero,
            RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN);
        return true;
    }

    public void Detach()
    {
        if (_guestWindow == IntPtr.Zero) return;
        try { SetParent(_guestWindow, _previousParent); } catch { }
        _guestWindow = IntPtr.Zero;
    }

    private void ResizeChildToHost()
    {
        if (_guestWindow == IntPtr.Zero || Handle == IntPtr.Zero) return;
        GetClientRect(Handle, out var rect);
        var w = Math.Max(1, rect.right - rect.left);
        var h = Math.Max(1, rect.bottom - rect.top);
        SetWindowPos(_guestWindow, IntPtr.Zero, 0, 0, w, h,
            SWP_NOZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    }

    protected override HandleRef BuildWindowCore(HandleRef hwndParent)
    {
        _placeholder = CreateWindowEx(
            0, "STATIC", null,
            WS_CHILD | WS_VISIBLE,
            0, 0, 1, 1,
            hwndParent.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        return new HandleRef(this, _placeholder);
    }

    protected override void DestroyWindowCore(HandleRef hwnd)
    {
        Detach();
        if (_placeholder != IntPtr.Zero)
        {
            DestroyWindow(_placeholder);
            _placeholder = IntPtr.Zero;
        }
    }

    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);
        ResizeChildToHost();
    }

    protected override void OnGotKeyboardFocus(KeyboardFocusChangedEventArgs e)
    {
        base.OnGotKeyboardFocus(e);
        if (_guestWindow != IntPtr.Zero) SetFocus(_guestWindow);
    }

    /// <summary>
    /// Hook <c>WM_PARENTNOTIFY</c> on the placeholder to detect mouse
    /// clicks landing in the foreign child. WPF doesn't see those
    /// clicks (they go to the RAIL HWND directly), so without this
    /// nudge our WPF keyboard focus would stay wherever the user
    /// last clicked outside the embed.
    /// </summary>
    protected override IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_PARENTNOTIFY)
        {
            var ev = wParam.ToInt32() & 0xFFFF;
            if (ev == WM_LBUTTONDOWN || ev == WM_MBUTTONDOWN || ev == WM_RBUTTONDOWN)
            {
                Dispatcher.BeginInvoke(() => Focus());
            }
        }
        return base.WndProc(hwnd, msg, wParam, lParam, ref handled);
    }

    /// <summary>
    /// EnumWindows scan for a visible top-level window whose title
    /// starts with the given prefix. Used to identify a specific
    /// kitty session among potentially many WSLg-rendered windows.
    /// </summary>
    private static IntPtr FindWindowByTitlePrefix(string prefix)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            var titleBuf = new StringBuilder(256);
            GetWindowText(hwnd, titleBuf, titleBuf.Capacity);
            var title = titleBuf.ToString();
            if (title.StartsWith(prefix, StringComparison.Ordinal))
            {
                found = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // -- P/Invoke ------------------------------------------------------

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);
    private static int GetWindowLong(IntPtr hWnd, int nIndex)
    {
        if (IntPtr.Size == 8) return (int)GetWindowLongPtr(hWnd, nIndex).ToInt64();
        return GetWindowLong32(hWnd, nIndex);
    }
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);
    private static int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong)
    {
        if (IntPtr.Size == 8) return (int)SetWindowLongPtr(hWnd, nIndex, new IntPtr(dwNewLong)).ToInt64();
        return SetWindowLong32(hWnd, nIndex, dwNewLong);
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        int dwExStyle, string lpClassName, string? lpWindowName,
        int dwStyle, int x, int y, int nWidth, int nHeight,
        IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }
}
