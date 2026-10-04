# Dev: exercise the launcher's in-game chat box without real key presses: post WM_HOTKEY to the overlay
# window, set the text box, and post Enter - all aimed at the launcher's own windows only.
param([string]$Text = "hello from the overlay")
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class W {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static List<IntPtr> TopLevel(uint pid) {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }
    public static List<IntPtr> Children(IntPtr parent) {
        var list = new List<IntPtr>();
        EnumChildWindows(parent, (h, l) => { list.Add(h); return true; }, IntPtr.Zero);
        return list;
    }
    public static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
}
"@
$p = Get-Process AlyxMP -ErrorAction Stop | Select-Object -First 1
$overlay = $null
foreach ($h in [W]::TopLevel([uint32]$p.Id)) {
    $r = New-Object W+RECT; [W]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $hh = $r.B - $r.T
    if ($w -ge 400 -and $w -le 700 -and $hh -ge 25 -and $hh -le 60) { $overlay = $h }
}
if (-not $overlay) { throw "overlay window not found" }
"overlay hwnd $overlay visible=$([W]::IsWindowVisible($overlay))"
[W]::PostMessage($overlay, 0x0312, [IntPtr]0xA17, [IntPtr]0) | Out-Null
Start-Sleep -Milliseconds 600
"after hotkey visible=$([W]::IsWindowVisible($overlay))"
$edit = [W]::Children($overlay) | Where-Object { [W]::Cls($_) -like "*EDIT*" } | Select-Object -First 1
if (-not $edit) { throw "text box not found" }
[W]::SendMessage($edit, 0x000C, [IntPtr]::Zero, $Text) | Out-Null
[W]::PostMessage($edit, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001) | Out-Null
Start-Sleep -Milliseconds 600
"after enter visible=$([W]::IsWindowVisible($overlay))"
