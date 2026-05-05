using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using Bromure.SandboxEngine.Qemu;

namespace Bromure.AC.Display;

/// <summary>
/// HwndHost wrapper that reparents QEMU's SDL window into our WPF
/// surface. Replacement for the macOS port's `VZVirtualMachineView`
/// — until the real fb-agent path lands, we let QEMU draw with
/// `-display sdl` and then yank its top-level window into our session
/// chrome via Win32 <c>SetParent</c>.
///
/// <para><b>Lifetime contract.</b> The host calls <see cref="Attach"/>
/// once it has a QEMU PID; we enumerate top-level windows owned by
/// that process, find the SDL one (class name <c>SDL_app</c>), strip
/// its OS chrome, and reparent. <see cref="Detach"/> reverses the
/// chrome flags but doesn't kill the window — QEMU shutdown does that.</para>
/// </summary>
public sealed class QemuWindowHost : HwndHost
{
    public QemuWindowHost()
    {
        // Make the host focusable so clicks land here. Without this WPF
        // routes the click to the parent and the embedded HWND never
        // sees the focus change — the user has to click *inside* the
        // QEMU framebuffer to start typing, which is the "feels like a
        // VM, not a desktop app" complaint. With Focusable=true + the
        // OnGotKeyboardFocus override below, focus on the host
        // forwards to the embedded child via Win32 SetFocus().
        Focusable = true;
        // Pull WPF keyboard focus on click — but DO NOT mark the
        // event handled. WPF needs to route the click down to the
        // embedded HWND so GTK sees a real WM_LBUTTONDOWN, which
        // is what makes GTK move its widget-level focus into the
        // drawing area. Without that, our SendMessage(WM_KEYDOWN)
        // lands on a toplevel whose internal focus is null.
        MouseLeftButtonDown += (_, _) => Focus();
    }

    private const int WS_CHILD = 0x40000000;
    private const int WS_VISIBLE = 0x10000000;
    private const int WS_POPUP = unchecked((int)0x80000000);
    private const int WS_BORDER = 0x00800000;
    private const int WS_CAPTION = 0x00C00000;
    private const int WS_DLGFRAME = 0x00400000;
    private const int WS_THICKFRAME = 0x00040000;
    private const int WS_SYSMENU = 0x00080000;
    private const int WS_MINIMIZEBOX = 0x00020000;
    private const int WS_MAXIMIZEBOX = 0x00010000;
    private const int GWL_STYLE = -16;
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_APPWINDOW = 0x00040000;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_FRAMECHANGED = 0x0020;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const uint RDW_INVALIDATE = 0x0001;
    private const uint RDW_ERASE = 0x0004;
    private const uint RDW_FRAME = 0x0400;
    private const uint RDW_ALLCHILDREN = 0x0080;

    private IntPtr _qemuWindow;
    private IntPtr _placeholder;
    private IntPtr _previousParent;
    private int _previousStyle;
    private int _previousExStyle;
    private QmpClient? _qmp;

    /// <summary>
    /// QMP client used to inject keyboard events. WPF's input pipeline
    /// consumes WM_KEYDOWN/UP before the reparented GTK toplevel can
    /// see them, so we route key presses through QEMU's input subsystem
    /// instead. Mouse already works (the host cursor delivers WM_MOUSE*
    /// directly to whichever HWND is under it, bypassing WPF), so we
    /// only need this for the keyboard.
    /// </summary>
    public QmpClient? Qmp
    {
        get => _qmp;
        set => _qmp = value;
    }

    /// <summary>Find QEMU's SDL window by PID and reparent into us.</summary>
    public bool Attach(int pid, TimeSpan timeout)
    {
        if (Handle == IntPtr.Zero) return false;
        var deadline = DateTime.UtcNow + timeout;
        IntPtr qemuWindow = IntPtr.Zero;
        while (DateTime.UtcNow < deadline)
        {
            qemuWindow = FindWindowForPid(pid);
            if (qemuWindow != IntPtr.Zero) break;
            System.Threading.Thread.Sleep(50);
        }
        if (qemuWindow == IntPtr.Zero) return false;

        // GTK toplevel windows on Windows are a frame around an inner
        // child window that holds the framebuffer (class typically
        // "gdkWindowChild"). If we reparent the toplevel itself we drag
        // along the menubar and the WS_CAPTION even after show-menubar=off
        // — the user sees framebuffer + chrome inside our HwndHost.
        // Reparenting the inner drawing area gives us *just* the pixels.
        // For SDL the toplevel == drawing area, so there's no inner
        // child to descend into and we keep the toplevel.
        var drawingArea = FindLargestVisibleChild(qemuWindow);
        if (drawingArea != IntPtr.Zero)
        {
            qemuWindow = drawingArea;
        }

        _qemuWindow = qemuWindow;
        _previousParent = GetParent(qemuWindow);
        _previousStyle = GetWindowLong(qemuWindow, GWL_STYLE);
        _previousExStyle = GetWindowLong(qemuWindow, GWL_EXSTYLE);

        // Stripping WS_POPUP and the chrome flags broke the framebuffer:
        // GDK on Windows lost its rendering context and the embedded
        // window came up white. The minimal change Windows actually
        // requires for SetParent to work is the WS_CHILD bit; everything
        // else can stay and just gets clipped by our HwndHost's client
        // rect. Tradeoff: a thin titlebar may peek out at the top of
        // the embed during the brief moment before our SetWindowPos
        // resize hits, but the framebuffer renders.
        var newStyle = (_previousStyle & ~WS_POPUP) | WS_CHILD;
        SetWindowLong(qemuWindow, GWL_STYLE, newStyle);

        SetParent(qemuWindow, Handle);

        // GTK3 on Windows uses a single HWND for the entire toplevel
        // (titlebar + chrome + framebuffer all on one window). We
        // can't strip WS_CAPTION etc without breaking GDK's rendering
        // (verified — that gives a white screen). Trick instead:
        // measure the non-client area (titlebar height) and position
        // the child at negative Y so the titlebar drifts above our
        // HwndHost's clip rect. The framebuffer occupies the visible
        // area; the titlebar exists in memory but renders to no
        // visible pixel.
        GetWindowRect(qemuWindow, out var windowRect);
        GetClientRect(qemuWindow, out var clientRect);
        // Map the client rect's origin to screen coords to compute
        // the top-left offset of the client area inside the window.
        var clientOriginScreen = new POINT { x = 0, y = 0 };
        ClientToScreen(qemuWindow, ref clientOriginScreen);
        _topInset = clientOriginScreen.y - windowRect.top;

        ResizeChildToHost();

        // Tell GTK the window is "active" so it accepts keyboard
        // input. Without this WM_ACTIVATE, GTK paints the titlebar
        // grey and ignores SendMessage(WM_KEYDOWN) because it thinks
        // it's a background window.
        SendMessage(qemuWindow, WM_ACTIVATE, (IntPtr)WA_ACTIVE, IntPtr.Zero);
        SendMessage(qemuWindow, WM_NCACTIVATE, (IntPtr)1, IntPtr.Zero);
        SetFocus(qemuWindow);

        RedrawWindow(qemuWindow, IntPtr.Zero, IntPtr.Zero,
            RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN);
        return true;
    }

    private int _topInset;

    private void ResizeChildToHost()
    {
        if (_qemuWindow == IntPtr.Zero || Handle == IntPtr.Zero) return;
        GetClientRect(Handle, out var hostRect);
        var w = Math.Max(1, hostRect.right - hostRect.left);
        var h = Math.Max(1, hostRect.bottom - hostRect.top);
        // Push the child up by _topInset so its non-client area
        // (titlebar / borders) sits above the HwndHost's clip rect.
        // The total window size grows by _topInset to keep the
        // *client* area equal to the host rect.
        SetWindowPos(_qemuWindow, IntPtr.Zero, 0, -_topInset, w, h + _topInset,
            SWP_NOZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    }

    /// <summary>Reverse-attach. Doesn't destroy the QEMU window — guest shutdown does.</summary>
    public void Detach()
    {
        if (_qemuWindow == IntPtr.Zero) return;
        try
        {
            // Don't try to restore the original chrome — by the time we
            // detach the window is usually being torn down. Just clear
            // our reference; QEMU will dispose itself on guest shutdown.
            SetParent(_qemuWindow, _previousParent);
        }
        catch { }
        _qemuWindow = IntPtr.Zero;
    }

    protected override HandleRef BuildWindowCore(HandleRef hwndParent)
    {
        // Create a host placeholder window. The QEMU child window is
        // SetParent'd into this once Attach() runs.
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
        if (_qemuWindow != IntPtr.Zero)
        {
            // Re-activate every time focus comes back. GTK paints the
            // titlebar inactive (and gates input) whenever an
            // activate/deactivate cycle happens, which fires whenever
            // WPF reorders its own internal focus.
            SendMessage(_qemuWindow, WM_ACTIVATE, (IntPtr)WA_ACTIVE, IntPtr.Zero);
            SendMessage(_qemuWindow, WM_NCACTIVATE, (IntPtr)1, IntPtr.Zero);
            SetFocus(_qemuWindow);
        }
    }

    private const int WM_PARENTNOTIFY = 0x0210;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_RBUTTONDOWN = 0x0204;

    /// <summary>
    /// Receives messages routed to the HwndHost placeholder. We hook
    /// <c>WM_PARENTNOTIFY</c> to spot mouse clicks landing in the
    /// embedded QEMU child HWND — that's how we know the user is
    /// trying to interact with the framebuffer. WPF doesn't see these
    /// clicks (they go straight to the foreign child), so without
    /// this nudge our WPF keyboard focus would stay wherever the user
    /// last clicked outside the embed and key events would never
    /// reach <see cref="OnPreviewKeyDown"/>.
    /// </summary>
    protected override IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_PARENTNOTIFY)
        {
            var ev = wParam.ToInt32() & 0xFFFF;
            if (ev == WM_LBUTTONDOWN || ev == WM_MBUTTONDOWN || ev == WM_RBUTTONDOWN)
            {
                // Reclaim WPF keyboard focus on the next dispatcher
                // turn — calling Focus() inside a Win32 message
                // handler is fine, but deferring keeps the message
                // pump unblocked.
                Dispatcher.BeginInvoke(() => Focus());
            }
        }
        return base.WndProc(hwnd, msg, wParam, lParam, ref handled);
    }

    // WPF's input pipeline grabs every WM_KEYDOWN/UP/CHAR before they
    // reach the reparented GTK toplevel — verified empirically: under
    // X11 in the guest, mouse selection works (WM_MOUSE* hit the HWND
    // under the cursor and bypass WPF) but keyboard input is dead.
    // Earlier attempts to SendMessage(WM_KEYDOWN) at the GTK HWND were
    // also fragile across the WPF↔GTK message-pump boundary. Route
    // key events through QMP instead: QEMU's input subsystem generates
    // a real USB-keyboard event the guest sees natively, no GTK or
    // GDK involved.
    private const int WM_ACTIVATE = 0x0006;
    private const int WM_NCACTIVATE = 0x0086;
    private const int WA_ACTIVE = 1;

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        if (ForwardKeyToQmp(e, down: true)) e.Handled = true;
        base.OnPreviewKeyDown(e);
    }

    protected override void OnPreviewKeyUp(KeyEventArgs e)
    {
        if (ForwardKeyToQmp(e, down: false)) e.Handled = true;
        base.OnPreviewKeyUp(e);
    }

    private bool ForwardKeyToQmp(KeyEventArgs e, bool down)
    {
        var qmp = _qmp;
        if (qmp is null) return false;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var vk = KeyInterop.VirtualKeyFromKey(key);
        if (vk == 0) return false;
        var qcode = QemuKeyboard.VirtualKeyToQCode(vk);
        if (qcode is null) return false;
        // Fire-and-forget. QMP round-trip is sub-millisecond on loopback;
        // the typing rate stays interactive and we don't want to block
        // the WPF UI thread on each keystroke. Errors land in QMP read-loop
        // exceptions → supervisor logs.
        _ = QemuKeyboard.SendKeyAsync(qmp, qcode, down);
        return true;
    }

    /// <summary>
    /// Of all visible children of <paramref name="parent"/>, return
    /// the one with the largest area. For QEMU's GTK toplevel that's
    /// reliably the drawing area — the menubar / statusbar children
    /// are short strips. SDL toplevels have no children, so we return
    /// IntPtr.Zero and the caller falls back to the toplevel itself.
    /// </summary>
    private static IntPtr FindLargestVisibleChild(IntPtr parent)
    {
        IntPtr best = IntPtr.Zero;
        int bestArea = 0;
        EnumChildWindows(parent, (hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            if (!GetClientRect(hwnd, out var rect)) return true;
            var w = rect.right - rect.left;
            var h = rect.bottom - rect.top;
            // Ignore zero-size and degenerate strips (menubar / status).
            if (w < 64 || h < 64) return true;
            var area = w * h;
            if (area > bestArea)
            {
                best = hwnd;
                bestArea = area;
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    /// <summary>Walk top-level windows; pick the first one whose process matches.</summary>
    /// <remarks>
    /// QEMU's display backend determines the window class:
    ///   * SDL2 → "SDL_app"
    ///   * GTK3 → "gdkWindowToplevel"
    ///   * GTK4 → "GtkWindow"
    ///   * Qt   → "Qt5QWindowIcon" / "Qt6QWindowIcon"
    /// Plus QEMU's own "Console" / "Display" windows from `-monitor`.
    /// We accept any of these and skip class names that look like
    /// pseudo-consoles or invisible helpers.
    /// </remarks>
    private static IntPtr FindWindowForPid(int pid)
    {
        IntPtr found = IntPtr.Zero;
        IntPtr fallback = IntPtr.Zero;
        EnumWindows((hwnd, _) =>
        {
            GetWindowThreadProcessId(hwnd, out var owningPid);
            if (owningPid != pid) return true;
            if (!IsWindowVisible(hwnd)) return true;
            var className = new StringBuilder(96);
            GetClassName(hwnd, className, className.Capacity);
            var name = className.ToString();
            // Skip Windows-internal helpers that occasionally appear
            // under the QEMU pid (IME, console host, etc).
            if (name.StartsWith("IME", StringComparison.OrdinalIgnoreCase)
                || name.StartsWith("MSCTFIME", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
            // Preferred matches — strong signal this is the framebuffer window.
            if (name.Contains("SDL", StringComparison.OrdinalIgnoreCase)
                || name.StartsWith("Qt", StringComparison.OrdinalIgnoreCase)
                || name.Contains("gdkWindow", StringComparison.OrdinalIgnoreCase)
                || name.Equals("GtkWindow", StringComparison.OrdinalIgnoreCase))
            {
                found = hwnd;
                return false;
            }
            // Otherwise remember the first non-helper visible window as
            // a fallback in case the class name we don't recognise is
            // still QEMU's framebuffer (future GTK/Qt revisions etc).
            if (fallback == IntPtr.Zero) fallback = hwnd;
            return true;
        }, IntPtr.Zero);
        return found != IntPtr.Zero ? found : fallback;
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
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int lpdwProcessId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x, y; }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int left, top, right, bottom; }
}
