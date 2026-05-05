using System.Text.Json.Nodes;

namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// Injects keyboard events into a running QEMU instance via QMP
/// <c>input-send-event</c>.
///
/// <para>Why this exists: the embedded WPF window grabs WM_KEYDOWN/UP
/// before they reach the reparented GTK toplevel, so synthetic
/// SendMessage forwarding is fragile across the WPF↔GTK message-pump
/// boundary. QMP injection skips the host's input pipeline entirely
/// and pushes events into QEMU's USB-tablet/keyboard emulation, which
/// the guest sees indistinguishable from a real keypress.</para>
/// </summary>
public static class QemuKeyboard
{
    /// <summary>
    /// Map a Win32 virtual-key code (the kind <c>KeyInterop.VirtualKeyFromKey</c>
    /// produces in WPF) to a QEMU QKeyCode string. Returns null when the
    /// VK has no mapping — caller should drop the event rather than send
    /// garbage. Letters use lowercase qcodes; QEMU's keymap handles
    /// shift to produce uppercase in the guest.
    /// </summary>
    public static string? VirtualKeyToQCode(int vk)
    {
        if (vk >= 0x30 && vk <= 0x39) return ((char)vk).ToString();
        if (vk >= 0x41 && vk <= 0x5A) return ((char)(vk + 32)).ToString();
        if (vk >= 0x70 && vk <= 0x7B) return "f" + (vk - 0x6F).ToString(System.Globalization.CultureInfo.InvariantCulture);
        return vk switch
        {
            0x08 => "backspace",
            0x09 => "tab",
            0x0D => "ret",
            0x10 => "shift",
            0x11 => "ctrl",
            0x12 => "alt",
            0x13 => "pause",
            0x14 => "caps_lock",
            0x1B => "esc",
            0x20 => "spc",
            0x21 => "pgup",
            0x22 => "pgdn",
            0x23 => "end",
            0x24 => "home",
            0x25 => "left",
            0x26 => "up",
            0x27 => "right",
            0x28 => "down",
            0x2C => "print",
            0x2D => "insert",
            0x2E => "delete",
            0x5B => "meta_l",
            0x5C => "meta_r",
            0x5D => "menu",
            0x60 => "kp_0",
            0x61 => "kp_1",
            0x62 => "kp_2",
            0x63 => "kp_3",
            0x64 => "kp_4",
            0x65 => "kp_5",
            0x66 => "kp_6",
            0x67 => "kp_7",
            0x68 => "kp_8",
            0x69 => "kp_9",
            0x6A => "kp_multiply",
            0x6B => "kp_add",
            0x6D => "kp_subtract",
            0x6E => "kp_decimal",
            0x6F => "kp_divide",
            0x90 => "num_lock",
            0x91 => "scroll_lock",
            0xA0 => "shift",
            0xA1 => "shift_r",
            0xA2 => "ctrl",
            0xA3 => "ctrl_r",
            0xA4 => "alt",
            0xA5 => "alt_r",
            0xBA => "semicolon",
            0xBB => "equal",
            0xBC => "comma",
            0xBD => "minus",
            0xBE => "dot",
            0xBF => "slash",
            0xC0 => "grave_accent",
            0xDB => "bracket_left",
            0xDC => "backslash",
            0xDD => "bracket_right",
            0xDE => "apostrophe",
            _ => null,
        };
    }

    /// <summary>
    /// Send a single key down/up event to QEMU.
    /// </summary>
    public static Task SendKeyAsync(QmpClient qmp, string qcode, bool down, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(qmp);
        ArgumentException.ThrowIfNullOrEmpty(qcode);
        var args = new JsonObject
        {
            ["events"] = new JsonArray
            {
                new JsonObject
                {
                    ["type"] = "key",
                    ["data"] = new JsonObject
                    {
                        ["down"] = down,
                        ["key"] = new JsonObject
                        {
                            ["type"] = "qcode",
                            ["data"] = qcode,
                        },
                    },
                },
            },
        };
        return qmp.ExecuteAsync("input-send-event", args, ct);
    }
}
