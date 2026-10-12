param(
    [ValidateSet('WindowInfo', 'PressEscape', 'ClickBattleTab', 'ClickP2', 'ClickRyu', 'ClickLuke', 'Confirm')]
    [string]$Action = 'WindowInfo'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BatchDumpInput {
    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref Point point);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extraInfo);
}
'@

$game = Get-Process | Where-Object { $_.MainWindowTitle -like '*Street Fighter 6*' -and $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
if (-not $game) { throw 'Street Fighter 6 window was not found.' }
$window = $game.MainWindowHandle
$rect = New-Object BatchDumpInput+Rect
if (-not [BatchDumpInput]::GetClientRect($window, [ref]$rect)) { throw 'Could not read game client rectangle.' }
$origin = New-Object BatchDumpInput+Point
if (-not [BatchDumpInput]::ClientToScreen($window, [ref]$origin)) { throw 'Could not read game window position.' }
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
Write-Output ("Game PID={0} title={1} bounds=({2},{3},{4},{5}) foreground={6}" -f $game.Id, $game.MainWindowTitle, $origin.X, $origin.Y, $width, $height, ([BatchDumpInput]::GetForegroundWindow() -eq $window))
if ($Action -eq 'WindowInfo') { return }

[void][BatchDumpInput]::SetForegroundWindow($window)
Start-Sleep -Milliseconds 250

function Press-Key([byte]$code) {
    [BatchDumpInput]::keybd_event($code, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [BatchDumpInput]::keybd_event($code, 0, 2, [UIntPtr]::Zero)
}
function Click-At([double]$x, [double]$y) {
    $px = $origin.X + [int][Math]::Round($x * $width)
    $py = $origin.Y + [int][Math]::Round($y * $height)
    [void][BatchDumpInput]::SetCursorPos($px, $py)
    Start-Sleep -Milliseconds 80
    [BatchDumpInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [BatchDumpInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Write-Output ("Clicked ({0},{1})" -f $px, $py)
}

switch ($Action) {
    'PressEscape' { Press-Key 0x1B }
    'ClickBattleTab' { Click-At 0.50 0.068 }
    'ClickP2' { Click-At 0.50 0.55 }
    'ClickRyu' { Click-At 0.542 0.355 }
    'ClickLuke' { Click-At 0.373 0.209 }
    'Confirm' { Press-Key 0x46 }
}
