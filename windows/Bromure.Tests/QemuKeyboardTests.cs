using Bromure.SandboxEngine.Qemu;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class QemuKeyboardTests
{
    [Theory]
    [InlineData(0x41, "a")]      // VK 'A'
    [InlineData(0x5A, "z")]      // VK 'Z'
    [InlineData(0x30, "0")]
    [InlineData(0x39, "9")]
    public void Letters_and_digits_map_to_lowercase_qcodes(int vk, string expected)
    {
        QemuKeyboard.VirtualKeyToQCode(vk).Should().Be(expected);
    }

    [Theory]
    [InlineData(0x70, "f1")]
    [InlineData(0x7B, "f12")]
    public void Function_keys_map_to_fN(int vk, string expected)
    {
        QemuKeyboard.VirtualKeyToQCode(vk).Should().Be(expected);
    }

    [Theory]
    [InlineData(0x08, "backspace")]
    [InlineData(0x09, "tab")]
    [InlineData(0x0D, "ret")]
    [InlineData(0x1B, "esc")]
    [InlineData(0x20, "spc")]
    [InlineData(0x14, "caps_lock")]
    public void Common_control_keys_map(int vk, string expected)
    {
        QemuKeyboard.VirtualKeyToQCode(vk).Should().Be(expected);
    }

    [Theory]
    [InlineData(0x25, "left")]
    [InlineData(0x26, "up")]
    [InlineData(0x27, "right")]
    [InlineData(0x28, "down")]
    [InlineData(0x21, "pgup")]
    [InlineData(0x22, "pgdn")]
    [InlineData(0x23, "end")]
    [InlineData(0x24, "home")]
    [InlineData(0x2D, "insert")]
    [InlineData(0x2E, "delete")]
    public void Navigation_keys_map(int vk, string expected)
    {
        QemuKeyboard.VirtualKeyToQCode(vk).Should().Be(expected);
    }

    [Theory]
    [InlineData(0xA0, "shift")]
    [InlineData(0xA1, "shift_r")]
    [InlineData(0xA2, "ctrl")]
    [InlineData(0xA3, "ctrl_r")]
    [InlineData(0xA4, "alt")]
    [InlineData(0xA5, "alt_r")]
    [InlineData(0x10, "shift")]   // generic VK_SHIFT
    [InlineData(0x11, "ctrl")]    // generic VK_CONTROL
    [InlineData(0x12, "alt")]     // generic VK_MENU
    public void Modifier_keys_map_with_left_right_distinction(int vk, string expected)
    {
        QemuKeyboard.VirtualKeyToQCode(vk).Should().Be(expected);
    }

    [Theory]
    [InlineData(0xBA, "semicolon")]
    [InlineData(0xBB, "equal")]
    [InlineData(0xBC, "comma")]
    [InlineData(0xBD, "minus")]
    [InlineData(0xBE, "dot")]
    [InlineData(0xBF, "slash")]
    [InlineData(0xC0, "grave_accent")]
    [InlineData(0xDB, "bracket_left")]
    [InlineData(0xDC, "backslash")]
    [InlineData(0xDD, "bracket_right")]
    [InlineData(0xDE, "apostrophe")]
    public void Punctuation_keys_map(int vk, string expected)
    {
        QemuKeyboard.VirtualKeyToQCode(vk).Should().Be(expected);
    }

    [Theory]
    [InlineData(0x60, "kp_0")]
    [InlineData(0x69, "kp_9")]
    [InlineData(0x6A, "kp_multiply")]
    [InlineData(0x6F, "kp_divide")]
    public void Numpad_keys_map(int vk, string expected)
    {
        QemuKeyboard.VirtualKeyToQCode(vk).Should().Be(expected);
    }

    [Theory]
    [InlineData(0)]      // VK 0 (no key)
    [InlineData(0x07)]   // reserved
    [InlineData(0xFF)]   // not a real Win32 VK we map
    public void Unmapped_vks_return_null(int vk)
    {
        QemuKeyboard.VirtualKeyToQCode(vk).Should().BeNull();
    }
}
