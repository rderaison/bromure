using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Bromure.AC.Display;

/// <summary>
/// WPF view that renders a remote VNC framebuffer and forwards keyboard
/// + pointer events back to the server through <see cref="VncClient"/>.
/// One control per session. Replaces the mstsc embed: no HwndHost, no
/// reparenting, no RDP-security negotiation games — just a
/// <see cref="WriteableBitmap"/> updated from server-pushed Raw / CopyRect
/// rectangles.
///
/// <para>Layout: the bitmap is hosted in an <see cref="Image"/> with
/// <see cref="Stretch.Uniform"/> so it scales letterboxed to the window
/// size. Mouse/keyboard coordinates are mapped back to the source
/// framebuffer (so resizing the window doesn't break input targeting).</para>
/// </summary>
public sealed class VncControl : ContentControl, IDisposable
{
    private readonly VncClient _client;

    /// <summary>Underlying RFB client — exposed so the SessionTab
    /// can synthesise input (e.g. Ctrl+Shift+T for "new kitty tab")
    /// without going through WPF's keyboard event chain.</summary>
    public VncClient Client => _client;
    private readonly Image _image;
    private WriteableBitmap? _bitmap;
    private byte _buttonMask;        // mirrors what we last sent to the server
    private bool _disposed;

    /// <summary>Display name from the server (e.g. "bromure"). Updated
    /// after the handshake completes.</summary>
    public string DesktopName => _client.DesktopName;

    public event Action<Exception?>? Disconnected
    {
        add => _client.Disconnected += value;
        remove => _client.Disconnected -= value;
    }

    public VncControl(string host, int port)
    {
        _client = new VncClient(host, port);
        _image = new Image
        {
            // Stretch=Uniform preserves the framebuffer's aspect ratio
            // and fills the available space. Combined with
            // NearestNeighbor scaling + Aliased edges, scaling-up is
            // pixel-doubled rather than bilinearly smeared — terminal
            // text stays crisp, just gets "bigger pixels" instead of
            // a blurry interpolation. Scaling-down (fb > window) is
            // less common; we accept some minor smear there.
            Stretch = Stretch.Uniform,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Stretch,
            VerticalAlignment   = System.Windows.VerticalAlignment.Stretch,
            SnapsToDevicePixels = true,
        };
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.NearestNeighbor);
        RenderOptions.SetEdgeMode(_image, EdgeMode.Aliased);
        Background = Brushes.Red;     // DIAGNOSTIC — red shows where the Image doesn't reach
        Content = _image;
        // Keyboard input only flows when the control has focus; tab-
        // stop + click-to-focus is the WPF idiom for that.
        Focusable = true;
        FocusVisualStyle = null;
        IsTabStop = true;

        _client.Ready += OnReady;
        _client.RectangleReceived += OnRectangle;
        _client.DesktopResized += OnDesktopResized;
        _client.ServerClipboardChanged += OnServerClipboard;
        SizeChanged += OnControlResized;

        MouseLeftButtonDown += (_, e) => OnMouseDown(e, 0x01);
        MouseLeftButtonUp   += (_, e) => OnMouseUp(e, 0x01);
        MouseRightButtonDown += (_, e) => OnMouseDown(e, 0x04);
        MouseRightButtonUp   += (_, e) => OnMouseUp(e, 0x04);
        MouseMove += OnMouseMove;
        MouseWheel += OnMouseWheel;
        PreviewKeyDown += (_, e) => HandleKey(e, true);
        PreviewKeyUp   += (_, e) => HandleKey(e, false);
        // Click anywhere → take keyboard focus so typing reaches the
        // remote terminal without the user tabbing into us.
        MouseDown += (_, _) => Focus();
        // Host → guest clipboard sync. We push on focus-gain (covers
        // most "I'm about to interact" moments) AND on every Ctrl+V /
        // Ctrl+Shift+V keydown, so the freshest Windows clipboard
        // content reaches the guest just before kitty's paste handler
        // reads it. Guest → host direction is the auto ServerCutText
        // handler wired above.
        GotKeyboardFocus += async (_, _) =>
        {
            try { await PushHostClipboardAsync().ConfigureAwait(false); } catch { }
        };
        PreviewKeyDown += async (_, e) =>
        {
            if (e.Key == Key.V &&
                (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
            {
                try { await PushHostClipboardAsync().ConfigureAwait(false); } catch { }
            }
        };
    }

    public Task ConnectAsync(CancellationToken ct = default) => _client.ConnectAsync(ct);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { _client.DisposeAsync().AsTask().GetAwaiter().GetResult(); } catch { }
    }

    // -- Server → bitmap -------------------------------------------------

    /// <summary>Set true once the server has sent its first
    /// framebuffer update. Resize requests before this point sometimes
    /// crash older Xvnc builds; we defer SetDesktopSize until the
    /// loop is steady-state.</summary>
    private bool _firstFrameReceived;

    private void OnReady()
    {
        // Marshal to UI thread to allocate the WriteableBitmap. The
        // first SetDesktopSize is deferred to after the first frame
        // arrives — see _firstFrameReceived.
        Log($"OnReady: server fb={_client.Width}×{_client.Height}");
        Dispatcher.InvokeAsync(() => AllocateBitmap(_client.Width, _client.Height));
    }

    private void OnDesktopResized(int w, int h)
    {
        // Server confirmed (or initiated) a new framebuffer size.
        // Be idempotent — Xvnc emits an ExtendedDesktopSize pseudo-rect
        // on every FramebufferUpdate after a resize (not just once),
        // and a fresh full FBUR triggers another ExtendedDesktopSize,
        // so without this guard we burn CPU re-allocating the bitmap
        // and re-requesting full frames in a tight loop.
        Dispatcher.InvokeAsync(() =>
        {
            if (_bitmap is not null && _bitmap.PixelWidth == w && _bitmap.PixelHeight == h)
            {
                return;
            }
            Log($"OnDesktopResized: fb {(_bitmap?.PixelWidth ?? 0)}×{(_bitmap?.PixelHeight ?? 0)} → {w}×{h} — reallocating");
            AllocateBitmap(w, h);
            _ = _client.SendFramebufferUpdateRequestAsync(incremental: false, 0, 0, w, h);
        });
    }

    private void OnControlResized(object sender, SizeChangedEventArgs e)
    {
        // Don't fire SetDesktopSize until the first frame is in —
        // see _firstFrameReceived comment.
        if (_firstFrameReceived) RequestRemoteResize();
    }

    private static readonly string LogPath =
        System.IO.Path.Combine(System.IO.Path.GetTempPath(), "bromure-vnc.log");

    private static void Log(string msg)
    {
        try { System.IO.File.AppendAllText(LogPath, $"[{DateTime.Now:HH:mm:ss.fff}] {msg}\n"); } catch { }
    }

    /// <summary>NO-OP — matching the macOS UX: framebuffer stays at
    /// the bake-default 1280×800 (xterm explicitly sized to fill it),
    /// and the host-side WPF Image upscales 2× via NearestNeighbor for
    /// crisp pixel-doubled rendering. Client-driven SetDesktopSize is
    /// disabled because xterm + openbox don't reliably re-fullscreen
    /// on framebuffer growth — the new screen area would sit black.</summary>
    private void RequestRemoteResize()
    {
        // intentional no-op.
    }

    private void AllocateBitmap(int w, int h)
    {
        // Bitmap at fixed 96 DPI so WPF doesn't insert a separate DIP-
        // scaling step on top of the system DPI scale. With 96 DPI:
        // source pixels → DIPs (1:1) → physical pixels (single system
        // transform). One scale honours BitmapScalingMode.NearestNeighbor;
        // two cascading scales pick up bilinear interpolation somewhere
        // along the way and surface as chromatic-aberration fringe on
        // bitmap-font text.
        _bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgra32, palette: null);
        _image.Source = _bitmap;
    }

    private void OnServerClipboard(string text)
    {
        // Push the guest's clipboard into the Windows clipboard.
        // Wrapped in try because Clipboard.SetText can throw if
        // another app holds the clipboard (Win32 OpenClipboard fail).
        Dispatcher.InvokeAsync(() =>
        {
            try { System.Windows.Clipboard.SetText(text); }
            catch { /* best-effort */ }
        });
    }

    /// <summary>Send the host clipboard to the guest. Exposed so
    /// SessionWindow can wire it to a Ctrl-Shift-V shortcut or a
    /// menu item, in addition to the natural ClientCutText fire we
    /// could do on every host-side ClipboardChanged event.</summary>
    public Task PushHostClipboardAsync()
    {
        try
        {
            if (System.Windows.Clipboard.ContainsText())
            {
                var text = System.Windows.Clipboard.GetText();
                return _client.SendClipboardAsync(text);
            }
        }
        catch { }
        return Task.CompletedTask;
    }

    private void OnRectangle(RectUpdate r)
    {
        // Each rectangle is dispatched to the UI thread. We don't
        // batch — typical terminals push <100 rects/s and the
        // Dispatcher invoke cost is negligible.
        Dispatcher.InvokeAsync(() =>
        {
            if (!_firstFrameReceived)
            {
                _firstFrameReceived = true;
                Log($"OnRectangle: first frame received — {r.Kind} {r.X},{r.Y} {r.W}×{r.H}");
                RequestRemoteResize();
            }
            if (_bitmap is null) return;
            switch (r.Kind)
            {
                case RectKind.Raw:
                    var rect = new Int32Rect(r.X, r.Y, r.W, r.H);
                    _bitmap.WritePixels(rect, r.Pixels, r.W * 4, 0);
                    break;
                case RectKind.CopyRect:
                    // CopyRect: blit pixels FROM (srcX,srcY)+(w,h) TO
                    // (destX,destY). Avoid resending pixels that are
                    // already on-screen elsewhere. Implement via a
                    // temporary buffer; cheap for the small rects
                    // terminals emit (cursor moves, scrolls).
                    var srcRect = new Int32Rect(r.SrcX, r.SrcY, r.W, r.H);
                    var buf = new byte[r.W * r.H * 4];
                    _bitmap.CopyPixels(srcRect, buf, r.W * 4, 0);
                    var dstRect = new Int32Rect(r.X, r.Y, r.W, r.H);
                    _bitmap.WritePixels(dstRect, buf, r.W * 4, 0);
                    break;
            }
        });
    }

    // -- View → server (input) -------------------------------------------

    /// <summary>Map a WPF point on the Image into framebuffer
    /// coordinates (necessary because the image is Stretch=Uniform —
    /// the window can be any size).</summary>
    private (int X, int Y) MapToFramebuffer(Point pt)
    {
        if (_bitmap is null) return (0, 0);
        // Image is letterboxed inside the control; account for the
        // actual rendered rectangle.
        var imgW = _image.ActualWidth;
        var imgH = _image.ActualHeight;
        if (imgW <= 0 || imgH <= 0) return (0, 0);
        var scaleX = _client.Width  / imgW;
        var scaleY = _client.Height / imgH;
        var x = Math.Clamp((int)(pt.X * scaleX), 0, _client.Width - 1);
        var y = Math.Clamp((int)(pt.Y * scaleY), 0, _client.Height - 1);
        return (x, y);
    }

    private async void OnMouseDown(MouseEventArgs e, byte bit)
    {
        var (x, y) = MapToFramebuffer(e.GetPosition(_image));
        _buttonMask |= bit;
        await _client.SendPointerAsync(_buttonMask, x, y).ConfigureAwait(false);
    }

    private async void OnMouseUp(MouseEventArgs e, byte bit)
    {
        var (x, y) = MapToFramebuffer(e.GetPosition(_image));
        _buttonMask &= unchecked((byte)~bit);
        await _client.SendPointerAsync(_buttonMask, x, y).ConfigureAwait(false);
    }

    private async void OnMouseMove(object _, MouseEventArgs e)
    {
        var (x, y) = MapToFramebuffer(e.GetPosition(_image));
        await _client.SendPointerAsync(_buttonMask, x, y).ConfigureAwait(false);
    }

    private async void OnMouseWheel(object _, MouseWheelEventArgs e)
    {
        // RFB wheel: bit 3 = up, bit 4 = down. Send a press+release
        // pair for each notch (a "click").
        var (x, y) = MapToFramebuffer(e.GetPosition(_image));
        byte wheelBit = (byte)(e.Delta > 0 ? 0x08 : 0x10);
        await _client.SendPointerAsync((byte)(_buttonMask | wheelBit), x, y).ConfigureAwait(false);
        await _client.SendPointerAsync(_buttonMask, x, y).ConfigureAwait(false);
    }

    /// <summary>Allow the owning Window to relay key events captured
    /// at the Window level (modifier-only key downs that WPF doesn't
    /// reliably tunnel to a focused ContentControl when keyboard
    /// focus is on chrome).</summary>
    public void ForwardKey(KeyEventArgs e)
    {
        // Read the up/down state from the ROUTED EVENT type, not
        // e.IsDown — IsDown reflects the key's instantaneous state
        // when the message was synthesised which on KeyUp can still
        // report `true` for modifier keys mid-release on some
        // keyboards, dropping our SendKey(up) call entirely and
        // leaving Shift "stuck" pressed in the X server.
        var down = e.RoutedEvent == Keyboard.PreviewKeyDownEvent
                || e.RoutedEvent == Keyboard.KeyDownEvent;
        HandleKey(e, down);
    }

    private async void HandleKey(KeyEventArgs e, bool down)
    {
        var keysym = WpfKeyToKeysym(e.Key);
        try
        {
            System.IO.File.AppendAllText(
                System.IO.Path.Combine(System.IO.Path.GetTempPath(), "bromure-keys.log"),
                $"[{DateTime.Now:HH:mm:ss.fff}] {(down ? "DOWN" : "UP  ")} Key={e.Key} SystemKey={e.SystemKey} Modifiers={Keyboard.Modifiers} src={(e.OriginalSource?.GetType().Name ?? "?")} → keysym=0x{keysym:X4}\n");
        }
        catch { }
        if (keysym == 0) return;
        e.Handled = true;
        await _client.SendKeyAsync(keysym, down).ConfigureAwait(false);
    }

    /// <summary>Map a WPF <see cref="Key"/> to an X11 keysym (what RFB
    /// wants). The "obvious" letters and digits are ASCII; everything
    /// else maps via the <c>XK_*</c> conventional values from
    /// <c>X11/keysymdef.h</c>. This is a minimal table — enough to
    /// drive bash + a Vim/emacs/Claude/Codex session.
    ///
    /// <para><b>Shift handling.</b> TigerVNC's Xvnc processes each
    /// RFB key event as an INDEPENDENT keysym lookup — it does not
    /// carry our Shift_L press into the next keysym's keycode
    /// translation. So sending lowercase <c>'a'</c> with Shift held
    /// still produces <c>'a'</c> on the guest. The fix is to mix
    /// shift state into the keysym itself: <c>'A'</c> instead of
    /// <c>Shift_L + 'a'</c>. We still pass the Shift_L event for
    /// non-letter shortcuts (e.g. Shift+Tab, Shift+Enter) where the
    /// keysym itself doesn't change.</para></summary>
    private uint WpfKeyToKeysym(Key key)
    {
        var shift = (Keyboard.Modifiers & ModifierKeys.Shift) != 0;
        // Letters → ASCII codepoints, case-folded by held Shift state.
        if (key >= Key.A && key <= Key.Z)
        {
            int letter = (shift ? 'A' : 'a') + (key - Key.A);
            return (uint)letter;
        }
        // Digits → shifted symbols (US layout) when Shift is held.
        if (key >= Key.D0 && key <= Key.D9)
        {
            if (!shift) return (uint)('0' + (key - Key.D0));
            // US keyboard top-row: 1!  2@  3#  4$  5%  6^  7&  8*  9(  0)
            return key switch
            {
                Key.D1 => (uint)'!',
                Key.D2 => (uint)'@',
                Key.D3 => (uint)'#',
                Key.D4 => (uint)'$',
                Key.D5 => (uint)'%',
                Key.D6 => (uint)'^',
                Key.D7 => (uint)'&',
                Key.D8 => (uint)'*',
                Key.D9 => (uint)'(',
                Key.D0 => (uint)')',
                _      => (uint)('0' + (key - Key.D0)),
            };
        }
        if (key >= Key.NumPad0 && key <= Key.NumPad9) return (uint)('0' + (key - Key.NumPad0));
        return key switch
        {
            Key.Space      => 0x0020,
            Key.Tab        => 0xFF09,
            Key.Enter      => 0xFF0D,
            Key.Escape     => 0xFF1B,
            Key.Back       => 0xFF08, // Backspace
            Key.Delete     => 0xFFFF,
            Key.Insert     => 0xFF63,
            Key.Home       => 0xFF50,
            Key.End        => 0xFF57,
            Key.PageUp     => 0xFF55,
            Key.PageDown   => 0xFF56,
            Key.Left       => 0xFF51,
            Key.Up         => 0xFF52,
            Key.Right      => 0xFF53,
            Key.Down       => 0xFF54,
            Key.F1         => 0xFFBE,
            Key.F2         => 0xFFBF,
            Key.F3         => 0xFFC0,
            Key.F4         => 0xFFC1,
            Key.F5         => 0xFFC2,
            Key.F6         => 0xFFC3,
            Key.F7         => 0xFFC4,
            Key.F8         => 0xFFC5,
            Key.F9         => 0xFFC6,
            Key.F10        => 0xFFC7,
            Key.F11        => 0xFFC8,
            Key.F12        => 0xFFC9,
            Key.LeftShift  => 0xFFE1,
            Key.RightShift => 0xFFE2,
            Key.LeftCtrl   => 0xFFE3,
            Key.RightCtrl  => 0xFFE4,
            Key.LeftAlt    => 0xFFE9,
            Key.RightAlt   => 0xFFEA,
            Key.CapsLock   => 0xFFE5,
            Key.OemMinus         => shift ? '_'  : '-',
            Key.OemPlus          => shift ? '+'  : '=',
            Key.OemComma         => shift ? '<'  : ',',
            Key.OemPeriod        => shift ? '>'  : '.',
            Key.OemQuestion      => shift ? '?'  : '/',
            Key.OemSemicolon     => shift ? ':'  : ';',
            Key.OemQuotes        => shift ? '"'  : '\'',
            Key.OemOpenBrackets  => shift ? '{'  : '[',
            Key.OemCloseBrackets => shift ? '}'  : ']',
            Key.OemPipe          => shift ? '|'  : '\\',
            Key.OemTilde         => shift ? '~'  : '`',
            _ => 0,
        };
    }
}
