# ============================================================
#  QuickLauncher - ultra-light fuzzy quick launcher (Windows 11)
#  Pure PowerShell 5.1 + WinForms + DWM APIs. Zero dependencies.
#
#  Usage:
#    QuickLauncher.ps1                       -> open GUI launcher
#    QuickLauncher.ps1 app <name> <path> [-Keywords "k1,k2"]
#    QuickLauncher.ps1 web <name> <url>  [-Keywords "k1,k2"]
#    QuickLauncher.ps1 list
#    QuickLauncher.ps1 del  <name>
#    QuickLauncher.ps1 edit                  -> open data file in notepad
#    QuickLauncher.ps1 manage                -> entry manager UI (Ctrl+M in launcher)
#    QuickLauncher.ps1 install               -> desktop shortcut + Ctrl+Alt+Space
#    QuickLauncher.ps1 help
#
#  Data file: launcher.json (same folder, UTF-8, auto-created)
#  Theme / effect settings live inside launcher.json -> "settings"
# ============================================================
param(
    [string]$Command  = '',
    [string]$Name     = '',
    [string]$Target   = '',
    [string]$Keywords = ''
)

$ErrorActionPreference = 'Stop'
$Script:ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:DataFile   = Join-Path $Script:ScriptDir 'launcher.json'
$Script:Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

# ---------------- data layer ----------------
function Read-DataFile {
    if (-not (Test-Path $Script:DataFile)) {
        $seed = [pscustomobject]@{ apps = @(); webs = @() }
        [System.IO.File]::WriteAllText($Script:DataFile, ($seed | ConvertTo-Json -Depth 5), $Script:Utf8NoBom)
    }
    $raw = [System.IO.File]::ReadAllText($Script:DataFile, [System.Text.Encoding]::UTF8)
    $d = $raw | ConvertFrom-Json
    if ($null -eq $d) { $d = [pscustomobject]@{ apps = @(); webs = @() } }
    $d.apps = @($d.apps)
    $d.webs = @($d.webs)
    if ($null -eq $d.settings) {
        $d | Add-Member NoteProperty settings ([pscustomobject]@{
            theme = 'system'; transparency = $true; acrylic = $false; showList = $true
            listStyle = 'details'
            hotkeys = [pscustomobject]@{ summon = 'Ctrl+Alt+Space'; manage = ''; settings = ''; toggleTheme = ''; toggleList = ''; import = '' }
        }) -Force
    } else {
        if ($null -eq $d.settings.theme)        { $d.settings | Add-Member NoteProperty theme 'system' -Force }
        if ($null -eq $d.settings.transparency) { $d.settings | Add-Member NoteProperty transparency $true -Force }
        if ($null -eq $d.settings.acrylic)      { $d.settings | Add-Member NoteProperty acrylic $false -Force }
        if ($null -eq $d.settings.showList)     { $d.settings | Add-Member NoteProperty showList $true -Force }
        if ($null -eq $d.settings.listStyle)    { $d.settings | Add-Member NoteProperty listStyle 'details' -Force }
        if ($null -eq $d.settings.hotkeys) {
            $d.settings | Add-Member NoteProperty hotkeys ([pscustomobject]@{ summon = 'Ctrl+Alt+Space'; manage = ''; settings = ''; toggleTheme = ''; toggleList = ''; import = '' }) -Force
        } else {
            foreach ($k in @('summon','manage','settings','toggleTheme','toggleList','import')) {
                if ($null -eq $d.settings.hotkeys.$k) { $d.settings.hotkeys | Add-Member NoteProperty $k '' -Force }
            }
        }
        # drop legacy keys no longer exposed in UI
        $d.settings.PSObject.Properties.Remove('liquid')
        $d.settings.PSObject.Properties.Remove('buttonAnim')
    }
    return $d
}

function Save-DataFile($d) {
    [System.IO.File]::WriteAllText($Script:DataFile, ($d | ConvertTo-Json -Depth 5), $Script:Utf8NoBom)
}

# ---------------- pinyin initials (GB2312 zone method, pure .NET) ----------------
$Script:GB2312 = [System.Text.Encoding]::GetEncoding('GB2312')
$Script:PyZones = @(
    @(0xB0A1,0xB0C4,'a'), @(0xB0C5,0xB2C0,'b'), @(0xB2C1,0xB4ED,'c'),
    @(0xB4EE,0xB6E9,'d'), @(0xB6EA,0xB7A1,'e'), @(0xB7A2,0xB8C0,'f'),
    @(0xB8C1,0xB9FD,'g'), @(0xB9FE,0xBBF6,'h'), @(0xBBF7,0xBFA5,'j'),
    @(0xBFA6,0xC0AB,'k'), @(0xC0AC,0xC2E7,'l'), @(0xC2E8,0xC4C2,'m'),
    @(0xC4C3,0xC5B5,'n'), @(0xC5B6,0xC5BD,'o'), @(0xC5BE,0xC6D9,'p'),
    @(0xC6DA,0xC8BA,'q'), @(0xC8BB,0xC8F5,'r'), @(0xC8F6,0xCBF9,'s'),
    @(0xCBFA,0xCDD9,'t'), @(0xCDDA,0xCEF3,'w'), @(0xCEF4,0xD188,'x'),
    @(0xD1B9,0xD4D0,'y'), @(0xD4D1,0xD7F9,'z')
)
function Get-PyInitials([string]$s) {
    if (-not $s) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -lt 128) { [void]$sb.Append([char]::ToLower($ch)); continue }
        $bytes = $null
        try { $bytes = $Script:GB2312.GetBytes([string]$ch) } catch {}
        if ($null -eq $bytes -or $bytes.Length -lt 2) { continue }
        $code = ([int]$bytes[0] -shl 8) + [int]$bytes[1]
        foreach ($z in $Script:PyZones) {
            if ($code -ge $z[0] -and $code -le $z[1]) { [void]$sb.Append($z[2]); break }
        }
    }
    return $sb.ToString()
}

# ---------------- fuzzy match scoring ----------------
function Get-MatchScore($item, [string]$q) {
    if (-not $q) { return 1 }
    $name = ([string]$item.name).ToLower()
    if ($name.StartsWith($q))  { return 100 }
    if ($name.Contains($q))    { return 80 }
    if ($item.keywords) {
        $kws = @((([string]$item.keywords) -split '[,;]') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
        foreach ($k in $kws) {
            if ($k.StartsWith($q)) { return 60 }
            if ($k.Contains($q))   { return 50 }
        }
    }
    if ($item.py) {
        if ($item.py.StartsWith($q)) { return 40 }
        if ($item.py.Contains($q))   { return 20 }
    }
    return 0
}

# ---------------- hotkey parser ----------------
# Parses strings like "Ctrl+Alt+M", "F1", "Ctrl+Shift+Esc" and matches KeyEventArgs.
function Test-Hotkey($e, [string]$spec) {
    if (-not $spec) { return $false }
    $parts = @($spec.Trim().Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $false }
    $mods = @($parts[0..($parts.Count - 2)] | ForEach-Object { $_.ToLower() })
    $keyName = $parts[-1]
    $ctrl = ($mods -contains 'ctrl' -or $mods -contains 'control')
    $alt  = ($mods -contains 'alt')
    $shift = ($mods -contains 'shift')
    $win  = ($mods -contains 'win')
    if ($e.Control -ne $ctrl) { return $false }
    if ($e.Alt -ne $alt) { return $false }
    if ($e.Shift -ne $shift) { return $false }
    # main key: accept both literal enum names and common aliases
    try {
        $target = [System.Windows.Forms.Keys]::Parse([System.Windows.Forms.Keys], $keyName)
        if ($e.KeyCode -eq $target) { return $true }
    } catch {}
    # a few aliases that Keys.Parse might not accept
    $alias = @{ 'Space' = 'Space'; 'Esc' = 'Escape'; 'Return' = 'Return'; 'Enter' = 'Return' }
    if ($alias.ContainsKey($keyName)) {
        try {
            $target = [System.Windows.Forms.Keys]::Parse([System.Windows.Forms.Keys], $alias[$keyName])
            if ($e.KeyCode -eq $target) { return $true }
        } catch {}
    }
    return $false
}

# ============================================================
#  THEME MODULE  (all visual decisions centralized here)
#  Add a new theme = add one entry to ThemePresets.
# ============================================================
$Script:ThemePresets = [ordered]@{
    dark = [ordered]@{
        Window      = '202024'
        Card        = '2B2B2F'
        Input       = '2D2D33'
        Fore        = 'FFFFFF'
        Dim         = '9D9DA6'
        Accent      = '60CDFF'
        OnAccent    = '001B26'
        AcrylicAbgr = 'CC242020'
    }
    light = [ordered]@{
        Window      = 'F3F3F3'
        Card        = 'FFFFFF'
        Input       = 'FFFFFF'
        Fore        = '000000'
        Dim         = '333333'
        Accent      = '0067C0'
        OnAccent    = 'FFFFFF'
        AcrylicAbgr = 'E6F3F3F3'
    }
}
$Script:Style = [ordered]@{
    Radius    = 12
    RadiusSm  = 7
    Font      = 'Microsoft YaHei UI'
    FontSize  = 10.5
}
$Script:ColorCache = @{}

function Get-UiColor([string]$hex) {
    if (-not $Script:ColorCache.ContainsKey($hex)) {
        $v = [Convert]::ToInt32($hex, 16)
        $Script:ColorCache[$hex] = [System.Drawing.Color]::FromArgb(255, ($v -shr 16) -band 0xFF, ($v -shr 8) -band 0xFF, $v -band 0xFF)
    }
    return $Script:ColorCache[$hex]
}

function Get-SystemIsLight {
    try {
        return ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 1)
    } catch { return $false }
}

function Get-Theme {
    $name = [string]$script:settings.theme
    if ($name -eq 'system') { $name = $(if (Get-SystemIsLight) { 'light' } else { 'dark' }) }
    if (-not $Script:ThemePresets.Contains($name)) { $name = 'dark' }
    return $Script:ThemePresets[$name]
}

function Walk-ThemeControls($controls, $t) {
    foreach ($ctl in $controls) {
        if ($ctl -is [System.Windows.Forms.TextBox]) {
            $ctl.BackColor = Get-UiColor $t.Input
            $ctl.ForeColor = Get-UiColor $t.Fore
        }
        elseif ($ctl -is [System.Windows.Forms.ListView]) {
            $ctl.BackColor = Get-UiColor $t.Card
            $ctl.ForeColor = Get-UiColor $t.Fore
        }
        elseif ($ctl -is [System.Windows.Forms.Button]) {
            if ($ctl.Tag -eq 'primary') {
                $ctl.BackColor = Get-UiColor $t.Accent
                $ctl.ForeColor = Get-UiColor $t.OnAccent
            } else {
                $ctl.BackColor = Get-UiColor $t.Card
                $ctl.ForeColor = Get-UiColor $t.Fore
            }
        }
        elseif ($ctl -is [System.Windows.Forms.Panel]) {
            if ($ctl.Tag -is [hashtable] -and $ctl.Tag.kind -eq 'uicheck') {
                $ctl.Tag.surf = Get-UiColor $t.Window
                $ctl.Tag.fore = Get-UiColor $t.Fore
                $ctl.BackColor = Get-UiColor $t.Window
                $ctl.Invalidate()
            }
            elseif ($ctl.Tag -is [hashtable] -and $ctl.Tag.kind -eq 'themeswitch') {
                $ctl.Tag.surf = Get-UiColor $t.Window
                $ctl.BackColor = Get-UiColor $t.Window
                $ctl.Invalidate()
            }
            else { $ctl.BackColor = Get-UiColor $t.Card }
        }
        elseif ($ctl -is [System.Windows.Forms.GroupBox]) {
            $ctl.ForeColor = Get-UiColor $t.Fore
            $ctl.BackColor = [System.Drawing.Color]::Transparent
        }
        elseif ($ctl -is [System.Windows.Forms.Label] -or $ctl -is [System.Windows.Forms.CheckBox] -or $ctl -is [System.Windows.Forms.RadioButton]) {
            # solid surface color: ClearType subpixel rendering only works on opaque backgrounds.
            # transparent text controls fall back to grayscale AA -> the "fuzzy text" issue.
            $surf = $t.Window
            if ($ctl.Parent -is [System.Windows.Forms.Panel]) { $surf = $(if ($ctl.Parent.Tag -eq 'input') { $t.Input } else { $t.Card }) }
            $ctl.BackColor = Get-UiColor $surf
            if ($ctl.Tag -eq 'dim') { $ctl.ForeColor = Get-UiColor $t.Dim } else { $ctl.ForeColor = Get-UiColor $t.Fore }
        }
        if ($ctl.HasChildren) { Walk-ThemeControls $ctl.Controls $t }
    }
}

function Apply-ThemeToForm($f, $t) {
    $f.BackColor = Get-UiColor $t.Window
    Walk-ThemeControls $f.Controls $t
    $f.Refresh()
}

function Register-ThemedForm($f) {
    [void]$script:ThemedForms.Add($f)
    Apply-ThemeToForm $f $script:theme
}

$script:ThemedMenus = New-Object System.Collections.ArrayList
function Set-MenuTheme($cms) {
    if (-not $script:FxOk) { return }
    if (-not $script:ThemedMenus.Contains($cms)) { [void]$script:ThemedMenus.Add($cms) }
    $t = $script:theme
    $back = Get-UiColor $t.Card
    [FluentFx+QlMenuColors]::Back   = $back.ToArgb()
    [FluentFx+QlMenuColors]::Fore   = (Get-UiColor $t.Fore).ToArgb()
    [FluentFx+QlMenuColors]::Border = (Get-UiColor $t.Dim).ToArgb()
    [FluentFx+QlMenuColors]::Hover  = (Get-Shade $back 16).ToArgb()
    $cms.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object FluentFx+QlMenuColorTable))
    $cms.BackColor = $back
    $cms.ForeColor = Get-UiColor $t.Fore
}

function Update-ThemeAll {
    foreach ($f in @($script:ThemedForms)) {
        if ($f -and -not $f.IsDisposed) {
            Apply-ThemeToForm $f $script:theme
            Set-FormChrome $f
        }
    }
    foreach ($m in @($script:ThemedMenus)) {
        if ($m -and -not $m.IsDisposed) { Set-MenuTheme $m }
    }
}

function Set-UiSetting([string]$key, $value) {
    $script:data.settings.$key = $value
    # acrylic requires transparency: enabling acrylic enables transparency, disabling transparency disables acrylic
    if ($key -eq 'acrylic' -and $value) { $script:data.settings.transparency = $true }
    if ($key -eq 'transparency' -and -not $value) { $script:data.settings.acrylic = $false }
    Save-DataFile $script:data
    $script:settings = $script:data.settings
    $script:theme = Get-Theme
    Update-ThemeAll
}

# ---------------- fluent window effects (tiny in-memory C# helper) ----------------
$script:FxOk = $false
$FxCode = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class FluentFx {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [StructLayout(LayoutKind.Sequential)]
    private struct AccentPolicy { public int AccentState; public int AccentFlags; public int GradientColor; public int AnimationId; }
    [StructLayout(LayoutKind.Sequential)]
    private struct WindowCompositionAttribData { public int Attrib; public IntPtr pvData; public int cbData; }
    [DllImport("user32.dll")]
    private static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttribData data);

    public static int SetCorners(IntPtr hwnd, bool rounded) {
        int pref = rounded ? 2 : 1;
        return DwmSetWindowAttribute(hwnd, 33, ref pref, 4);
    }

    public static int SetDarkTitleBar(IntPtr hwnd, bool dark) {
        int v = dark ? 1 : 0;
        int r = DwmSetWindowAttribute(hwnd, 20, ref v, 4);   // Win11 / late Win10
        if (r != 0) { r = DwmSetWindowAttribute(hwnd, 19, ref v, 4); } // older Win10 fallback
        return r;
    }

    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    // crisp text on scaled displays: without DPI awareness Windows bitmap-stretches
    // the whole window (fonts included) -> everything looks fuzzy
    public static void EnableDpiAwareness() {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }   // PER_MONITOR_AWARE_V2
        catch { try { SetProcessDPIAware(); } catch {} }          // legacy fallback
    }

    [DllImport("user32.dll")]
    public static extern int SendMessage(IntPtr hWnd, int Msg, IntPtr wParam, IntPtr lParam);
    public const int LVM_SETICONSPACING = 0x1000 + 53;
    public static IntPtr MAKELPARAM(int lo, int hi) {
        return new IntPtr((hi << 16) | (lo & 0xFFFF));
    }

    public static bool SetAcrylic(IntPtr hwnd, uint abgr, bool on) {
        try {
            AccentPolicy policy = new AccentPolicy();
            policy.AccentState = on ? 4 : 0;
            policy.AccentFlags = 2;
            policy.GradientColor = unchecked((int)abgr);
            int size = Marshal.SizeOf(policy);
            IntPtr ptr = Marshal.AllocHGlobal(size);
            Marshal.StructureToPtr(policy, ptr, false);
            WindowCompositionAttribData data = new WindowCompositionAttribData();
            data.Attrib = 19;
            data.pvData = ptr;
            data.cbData = size;
            int r = SetWindowCompositionAttribute(hwnd, ref data);
            Marshal.FreeHGlobal(ptr);
            return r != 0;
        } catch { return false; }
    }

    public class DropShadowForm : Form {
        protected override CreateParams CreateParams {
            get { CreateParams cp = base.CreateParams; cp.ClassStyle |= 0x00020000; return cp; }
        }
    }

    // themed context-menu colors (set from PowerShell whenever the theme changes)
    public class QlMenuColors {
        public static int Back   = unchecked((int)0xFF2B2B2F);
        public static int Fore   = unchecked((int)0xFFFFFFFF);
        public static int Border = unchecked((int)0xFF45454D);
        public static int Hover  = unchecked((int)0xFF3D3D44);
    }
    public class QlMenuColorTable : ProfessionalColorTable {
        private static Color C(int argb) { return Color.FromArgb(argb); }
        public override Color ToolStripDropDownBackground { get { return C(QlMenuColors.Back); } }
        public override Color ImageMarginGradientBegin    { get { return C(QlMenuColors.Back); } }
        public override Color ImageMarginGradientMiddle   { get { return C(QlMenuColors.Back); } }
        public override Color ImageMarginGradientEnd      { get { return C(QlMenuColors.Back); } }
        public override Color MenuBorder                  { get { return C(QlMenuColors.Border); } }
        public override Color MenuItemBorder              { get { return C(QlMenuColors.Hover); } }
        public override Color MenuItemSelected            { get { return C(QlMenuColors.Hover); } }
        public override Color MenuItemSelectedGradientBegin { get { return C(QlMenuColors.Hover); } }
        public override Color MenuItemSelectedGradientEnd   { get { return C(QlMenuColors.Hover); } }
        public override Color SeparatorDark               { get { return C(QlMenuColors.Border); } }
        public override Color SeparatorLight              { get { return C(QlMenuColors.Border); } }
    }
}
'@
try {
    Add-Type -TypeDefinition $FxCode -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -ErrorAction Stop
    $script:FxOk = $true
    [FluentFx]::EnableDpiAwareness()
} catch {}

# --- helpers for drawing / effects ---
function Get-Shade([System.Drawing.Color]$c, [int]$add) {
    $r = [Math]::Min(255, [Math]::Max(0, $c.R + $add))
    $g = [Math]::Min(255, [Math]::Max(0, $c.G + $add))
    $b = [Math]::Min(255, [Math]::Max(0, $c.B + $add))
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function Test-IsDarkTheme($t) {
    $c = Get-UiColor $t.Window
    return (($c.R * 0.299 + $c.G * 0.587 + $c.B * 0.114) -lt 128)
}

# one-stop chrome: rounded corners + themed title bar + acrylic + opacity
# applied to EVERY form -> effects are global and instant
function Set-FormChrome($f) {
    if ($null -eq $f -or $f.IsDisposed) { return }
    $h = $f.Handle
    $t = $script:theme
    if ($script:FxOk) {
        [void][FluentFx]::SetCorners($h, $true)
        [void][FluentFx]::SetDarkTitleBar($h, (Test-IsDarkTheme $t))
        if ([bool]$script:settings.acrylic) {
            [void][FluentFx]::SetAcrylic($h, [uint32][Convert]::ToUInt32($t.AcrylicAbgr, 16), $true)
        } else {
            [void][FluentFx]::SetAcrylic($h, 0, $false)
        }
    }
    # keep text crisp: let acrylic provide the blur; only dim slightly for plain transparency
    $f.Opacity = $(if ([bool]$script:settings.acrylic) { 1.0 } elseif ([bool]$script:settings.transparency) { 0.96 } else { 1.0 })
    $f.BackgroundImage = $null
}

# themed ListView column header (default header stays white in dark mode -> the "white bar")
function Use-ThemedHeader($lv) {
    $lv.OwnerDraw = $true
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $t = $script:theme
        $e.Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $br = New-Object System.Drawing.SolidBrush((Get-UiColor $t.Card))
        $e.Graphics.FillRectangle($br, $e.Bounds)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rf = New-Object System.Drawing.RectangleF(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 6), $e.Bounds.Height)
        $br2 = New-Object System.Drawing.SolidBrush((Get-UiColor $t.Fore))
        $e.Graphics.DrawString($e.Header.Text, $e.Font, $br2, $rf, $fmt)
        $pen = New-Object System.Drawing.Pen((Get-UiColor $t.Window))
        $e.Graphics.DrawLine($pen, ($e.Bounds.Right - 1), $e.Bounds.Top, ($e.Bounds.Right - 1), $e.Bounds.Bottom)
        $br.Dispose(); $br2.Dispose(); $fmt.Dispose(); $pen.Dispose()
    })
    $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
}

# ---------------- CLI management ----------------
if ($Command -ne '') {
    $c = $Command.ToLower()
    $d = Read-DataFile
    switch ($c) {
        'app' {
            if (-not $Name -or -not $Target) {
                Write-Host 'Usage: QuickLauncher.ps1 app <name> <exe-path> [-Keywords "k1,k2"]'
            } else {
                if ($Target -match '\.(exe|msc|lnk|bat|cmd)$' -and -not (Test-Path $Target)) {
                    Write-Host ("[WARN] path not found: {0} (added anyway)" -f $Target)
                }
                $d.apps = @(@($d.apps | Where-Object { $_.name -ne $Name }) + [pscustomobject]@{ name = $Name; target = $Target; keywords = $Keywords; hits = 0 })
                Save-DataFile $d
                Write-Host ("[OK] app added: {0} -> {1}" -f $Name, $Target)
            }
        }
        'web' {
            if (-not $Name -or -not $Target) {
                Write-Host 'Usage: QuickLauncher.ps1 web <name> <url> [-Keywords "k1,k2"]'
            } else {
                if ($Target -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $Target = 'https://' + $Target.TrimStart('/') }
                $d.webs = @(@($d.webs | Where-Object { $_.name -ne $Name }) + [pscustomobject]@{ name = $Name; target = $Target; keywords = $Keywords; hits = 0 })
                Save-DataFile $d
                Write-Host ("[OK] web added: {0} -> {1}" -f $Name, $Target)
            }
        }
        'list' {
            Write-Host ('{0,-6} {1,-24} {2}' -f 'TYPE', 'NAME', 'TARGET')
            Write-Host ('-' * 80)
            foreach ($a in @($d.apps)) { Write-Host ('{0,-6} {1,-24} {2}' -f 'APP', $a.name, $a.target) }
            foreach ($w in @($d.webs)) { Write-Host ('{0,-6} {1,-24} {2}' -f 'WEB', $w.name, $w.target) }
            if (@($d.apps).Count + @($d.webs).Count -eq 0) { Write-Host '(empty - use "app"/"web" to add)' }
        }
        'del' {
            if (-not $Name) { Write-Host 'Usage: QuickLauncher.ps1 del <name>'; break }
            $a2 = @($d.apps | Where-Object { $_.name -ne $Name })
            $w2 = @($d.webs | Where-Object { $_.name -ne $Name })
            $removed = (@($d.apps).Count - $a2.Count) + (@($d.webs).Count - $w2.Count)
            if ($removed -gt 0) {
                $d.apps = $a2; $d.webs = $w2
                Save-DataFile $d
                Write-Host ("[OK] removed {0} entr(y/ies) named '{1}'" -f $removed, $Name)
            } else {
                Write-Host ("[MISS] nothing named '{0}'" -f $Name)
            }
        }
        'edit' { Start-Process notepad -ArgumentList ('"{0}"' -f $Script:DataFile) }
        'manage' {
            $script:OpenManage = $true
        }
        'install' {
            $ws = New-Object -ComObject WScript.Shell
            $desktop = [Environment]::GetFolderPath('Desktop')
            $lnkPath = Join-Path $desktop 'QuickLauncher.lnk'
            $lnk = $ws.CreateShortcut($lnkPath)
            $lnk.TargetPath = (Join-Path $PSHOME 'powershell.exe')
            $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
            $lnk.WindowStyle = 7
            $hk = ($d.settings.hotkeys.summon -replace '\+', '+' -replace '\s+', '').ToUpper()
            if (-not $hk) { $hk = 'CTRL+ALT+SPACE' }
            $lnk.Hotkey = $hk
            $lnk.Description = 'QuickLauncher'
            $lnk.Save()
            Write-Host ("[OK] Desktop shortcut created. Hotkey: {0}." -f $hk)
        }
        'guicheck' {
            $script:AutoClose = $true
        }
        'fxcheck' {
            $script:AutoClose = $true
            $script:FxCheck = $true
            $script:OpenManage = $true
        }
        default {
            Write-Host @'
QuickLauncher commands:
  (no args)                        open GUI launcher
  app <name> <exe-path> [-Keywords "k1,k2"]
  web <name> <url>     [-Keywords "k1,k2"]
  list                             list all entries
  del  <name>                      remove one entry by name
  edit                             edit launcher.json in notepad
  manage                           open entry manager UI (or Ctrl+M in launcher)
  install                          create desktop shortcut + Ctrl+Alt+Space
'@
        }
    }
    if (-not $script:AutoClose -and -not $script:OpenManage) { exit 0 }
}

# ---------------- GUI ----------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:data = Read-DataFile
$script:settings = $script:data.settings
$script:theme = Get-Theme
$script:WantManage = $false
$script:WantSettings = $false
$script:WantImport = $false
$script:ThemedForms = New-Object System.Collections.ArrayList
$script:allItems = New-Object System.Collections.ArrayList
foreach ($a in @($script:data.apps)) {
    [void]$script:allItems.Add([pscustomobject]@{
        type = 'APP'; name = [string]$a.name; target = [string]$a.target
        keywords = [string]$a.keywords; hits = [int]$a.hits; py = (Get-PyInitials ([string]$a.name))
    })
}
foreach ($w in @($script:data.webs)) {
    [void]$script:allItems.Add([pscustomobject]@{
        type = 'WEB'; name = [string]$w.name; target = [string]$w.target
        keywords = [string]$w.keywords; hits = [int]$w.hits; py = (Get-PyInitials ([string]$w.name))
    })
}
$script:filtered = @()
$script:q = ''

# ---------- shared ui helpers ----------
function New-RoundedRegion([int]$w, [int]$h, [int]$r) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
    $path.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
    $path.CloseFigure()
    return (New-Object System.Drawing.Region($path))
}
function Set-Rounded($ctl, [int]$r) {
    if ($ctl.Region) { $ctl.Region.Dispose() }
    $ctl.Region = New-RoundedRegion $ctl.Width $ctl.Height $r
}

# rounded-rectangle GraphicsPath (for owner-drawn controls)
function New-RoundedPath([System.Drawing.Rectangle]$r, [int]$rad) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $rad * 2
    $path.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $path.AddArc($r.Right - $d - 1, $r.Y, $d, $d, 270, 90)
    $path.AddArc($r.Right - $d - 1, $r.Bottom - $d - 1, $d, $d, 0, 90)
    $path.AddArc($r.X, $r.Bottom - $d - 1, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

# stretch one column to fill the ListView's client width (responsive layout helper)
function Sync-StretchColumn($lv, [int]$colIndex, [int]$minWidth) {
    if ($lv.Columns.Count -le $colIndex) { return }
    $fixed = 0
    for ($i = 0; $i -lt $lv.Columns.Count; $i++) { if ($i -ne $colIndex) { $fixed += $lv.Columns[$i].Width } }
    $w = $lv.ClientSize.Width - $fixed - 4
    if ($w -lt $minWidth) { $w = $minWidth }
    $lv.Columns[$colIndex].Width = $w
}
function New-UiButton([string]$text, [int]$x, [int]$y, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.Font = New-Object System.Drawing.Font($Script:Style.Font, 9)
    Set-Rounded $b $Script:Style.RadiusSm
    return $b
}
function New-UiLabel([string]$text, [int]$x, [int]$y, [int]$w, [bool]$dim) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 24)
    $l.Font = New-Object System.Drawing.Font($Script:Style.Font, 9)
    if ($dim) { $l.Tag = 'dim' }
    return $l
}

# ---------- custom checkbox (uiverse elijahgummer style, GDI+ owner-drawn) ----------
# mint 3px border + rounded box; green #2DC38C checkmark wipes down on check / up on uncheck;
# white rotated tick with drop shadow. Animation is a short one-shot timer (stops at the end) -> no idle cost.
function New-UiCheck([string]$text, [int]$x, [int]$y, [bool]$checked, [scriptblock]$onChanged) {
    $font = New-Object System.Drawing.Font($Script:Style.Font, 9)
    $tw = [System.Windows.Forms.TextRenderer]::MeasureText($text, $font).Width
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size((38 + $tw + 6), 28)
    $p.Cursor = [System.Windows.Forms.Cursors]::Hand
    $st = @{
        kind = 'uicheck'; text = $text; font = $font
        checked = $checked; progress = $(if ($checked) { 1.0 } else { 0.0 })
        timer = $null; surf = [System.Drawing.Color]::White; fore = [System.Drawing.Color]::Black
        onChanged = $onChanged
    }
    $p.Tag = $st
    $p.Add_Paint({
        param($s, $e)
        $st = $s.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($st.surf)
        $boxRect = New-Object System.Drawing.Rectangle(2, 3, 22, 22)
        $boxPath = New-RoundedPath $boxRect 7
        # green checkmark box with wipe animation (fill grows downward / recedes upward)
        if ($st.progress -gt 0.01) {
            $g.SetClip($boxPath)
            $fh = [int](22 * $st.progress)
            $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0x2D, 0xC3, 0x8C))), 2, 3, 22, $fh)
            # inner shadow at the bottom of the fill
            if ($fh -ge 4) {
                $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 0, 0, 0))), 2, (3 + $fh - 3), 22, 3)
            }
            $g.ResetClip()
            # white rotated tick with drop shadow
            if ($st.progress -gt 0.6) {
                $shPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 0, 0, 0), 2.6)
                $whPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.6)
                $shPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $shPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $whPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $whPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                $g.DrawLines($shPen, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(9, 15)), (New-Object System.Drawing.Point(13, 19)), (New-Object System.Drawing.Point(20, 9))))
                $g.DrawLines($whPen, [System.Drawing.Point[]]@((New-Object System.Drawing.Point(8, 14)), (New-Object System.Drawing.Point(12, 18)), (New-Object System.Drawing.Point(19, 8))))
                $shPen.Dispose(); $whPen.Dispose()
            }
        }
        # mint 3px border
        $penB = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0xBE, 0xDD, 0xD0), 3)
        $g.DrawPath($penB, $boxPath)
        $penB.Dispose(); $boxPath.Dispose()
        # label text
        $g.DrawString($st.text, $st.font, (New-Object System.Drawing.SolidBrush($st.fore)), 34, 5)
    })
    # NOTE: PS scriptblocks use dynamic scoping — function locals die when the factory returns.
    # The toggle must reach its state via the event sender / Timer.Tag, never via captured locals.
    $toggle = {
        param($sender)
        $st = $sender.Tag
        $st.checked = -not $st.checked
        if ($st.timer) { $st.timer.Stop() }
        $tm = New-Object System.Windows.Forms.Timer
        $tm.Interval = 33   # ~0.6s total (18 frames), then stops — zero idle cost
        $tm.Tag = $sender   # tick handler reaches the panel (and its state) through here
        $st.timer = $tm
        $tm.Add_Tick({
            $pnl = $this.Tag
            $st2 = $pnl.Tag
            if ($st2.checked) { $st2.progress = [Math]::Min(1.0, $st2.progress + 0.14) } else { $st2.progress = [Math]::Max(0.0, $st2.progress - 0.14) }
            $pnl.Invalidate()
            if ($st2.progress -ge 1.0 -or $st2.progress -le 0.0) { $this.Stop() }
        })
        $tm.Start()
        if ($st.onChanged) { & $st.onChanged $st.checked }
    }
    $st.invoke = $toggle
    $p.Add_Click({ & $this.Tag.invoke $this })
    return $p
}

# programmatic state sync (no animation, no event)
function Set-UiCheckState($ctl, [bool]$v) {
    $ctl.Tag.checked = $v
    $ctl.Tag.progress = $(if ($v) { 1.0 } else { 0.0 })
    $ctl.Invalidate()
}

# ---------- sun/moon quick theme switch (uiverse mamyapro123 style, static GDI+ states) ----------
# light = sky-blue pill + sun knob (left) + clouds; dark = navy pill + moon knob (right) + stars.
# continuous CSS animations (rays/twinkle/comets) intentionally omitted -> zero per-frame CPU.
function New-ThemeSwitch([int]$x, [int]$y) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($x, $y)
    $p.Size = New-Object System.Drawing.Size(68, 28)
    $p.Cursor = [System.Windows.Forms.Cursors]::Hand
    $p.Tag = @{ kind = 'themeswitch'; surf = [System.Drawing.Color]::White }
    $p.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($s.Tag.surf)
        $dark = Test-IsDarkTheme $script:theme
        $pillRect = New-Object System.Drawing.Rectangle(2, 2, 64, 24)
        $pill = New-RoundedPath $pillRect 12
        $c1 = $(if ($dark) { [System.Drawing.Color]::FromArgb(0x1B, 0x1E, 0x36) } else { [System.Drawing.Color]::FromArgb(0x5C, 0xAA, 0xD4) })
        $c2 = $(if ($dark) { [System.Drawing.Color]::FromArgb(0x25, 0x2A, 0x4A) } else { [System.Drawing.Color]::FromArgb(0x4A, 0x92, 0xBD) })
        $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($pillRect, $c1, $c2, 90)
        $g.FillPath($br, $pill)
        $br.Dispose()
        $g.SetClip($pill)
        if ($dark) {
            # stars
            $starBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0xFF, 0xF8, 0xE1))
            foreach ($pt in @(@(11, 8), @(20, 14), @(28, 7), @(15, 18))) {
                $g.FillEllipse($starBr, $pt[0], $pt[1], 2, 2)
            }
            $starBr.Dispose()
        } else {
            # clouds
            $clBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 0xF4, 0xF4, 0xF4))
            $g.FillEllipse($clBr, 36, 16, 20, 9)
            $g.FillEllipse($clBr, 47, 12, 17, 10)
            $clBr.Dispose()
        }
        $knobX = $(if ($dark) { 44 } else { 6 })
        if (-not $dark) {
            # sun rays (clipped to pill)
            $rayPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 0xF5, 0xC5, 0x18), 2)
            $cx = $knobX + 10; $cy = 14
            for ($a = 0; $a -lt 360; $a += 45) {
                $rad = $a * [Math]::PI / 180
                $g.DrawLine($rayPen, [int]($cx + 13 * [Math]::Cos($rad)), [int]($cy + 13 * [Math]::Sin($rad)), [int]($cx + 16 * [Math]::Cos($rad)), [int]($cy + 16 * [Math]::Sin($rad)))
            }
            $rayPen.Dispose()
        }
        $g.ResetClip()
        if ($dark) {
            # moon knob with craters
            $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0xD8, 0xD4, 0xC0))), $knobX, 4, 20, 20)
            $spBr = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0x9B, 0x97, 0x87))
            $g.FillEllipse($spBr, ($knobX + 4), 8, 5, 5)
            $g.FillEllipse($spBr, ($knobX + 11), 15, 4, 4)
            $g.FillEllipse($spBr, ($knobX + 12), 6, 3, 3)
            $spBr.Dispose()
        } else {
            # sun knob
            $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0xF5, 0xC5, 0x18))), $knobX, 4, 20, 20)
        }
        # hairline outline
        $outPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 0, 0, 0), 1)
        $g.DrawPath($outPen, $pill)
        $outPen.Dispose(); $pill.Dispose()
    })
    $p.Add_Click({
        $dark = Test-IsDarkTheme $script:theme
        Set-UiSetting 'theme' $(if ($dark) { 'light' } else { 'dark' })
    })
    $tt = New-Object System.Windows.Forms.ToolTip
    $tt.SetToolTip($p, '快速切换白天 / 夜间模式')
    return $p
}

function New-LetterIcon([string]$name, [int]$size = 24) {
    if (-not $name) { $name = '?' }
    if ($size -lt 16) { $size = 16 }
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $palette = @(0x4C6EF5, 0x12B886, 0xE8590C, 0x7048E8, 0x0CA678, 0xE03131, 0x1971C2, 0xF08C00)
    $h = 0
    foreach ($ch in $name.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 100000 }
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($palette[$h % $palette.Length]))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $size - 1
    $path.AddEllipse(0, 0, $d, $d)
    $g.FillPath($brush, $path)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $fontSize = [Math]::Max(8, $size * 0.45)
    $g.DrawString($name.Substring(0, 1), (New-Object System.Drawing.Font($Script:Style.Font, $fontSize, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $sf)
    $g.Dispose()
    return $bmp
}

function Get-IconBitmap($it, [int]$size) {
    $custom = [string]$it.icon
    $bmp = $null
    if ($custom -and (Test-Path $custom)) {
        try {
            if     ($custom -match '\.ico$')                    { $bmp = (New-Object System.Drawing.Icon($custom, $size, $size)).ToBitmap() }
            elseif ($custom -match '\.(png|jpg|jpeg|bmp|gif)$') { $bmp = New-Object System.Drawing.Bitmap($custom) }
            else                                                { $bmp = ([System.Drawing.Icon]::ExtractAssociatedIcon($custom)).ToBitmap() }
        } catch { $bmp = $null }
    }
    if (-not $bmp -and $it.type -eq 'APP') {
        try { $bmp = ([System.Drawing.Icon]::ExtractAssociatedIcon($it.target)).ToBitmap() } catch {}
    }
    if (-not $bmp) { $bmp = New-LetterIcon ([string]$it.name) $size }
    if ($bmp.Width -ne $size -or $bmp.Height -ne $size) {
        $scaled = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($scaled)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($bmp, 0, 0, $size, $size)
        $g.Dispose(); $bmp.Dispose()
        $bmp = $scaled
    }
    return $bmp
}

function Get-IconIndex($it) {
    $custom = [string]$it.icon
    $key = $it.type + '|' + $it.target + '|' + $custom
    if ($script:iconCache.ContainsKey($key)) { return $script:iconCache[$key] }
    $bmp = Get-IconBitmap $it 32
    [void]$script:imgs.Images.Add($bmp)
    $script:iconCache[$key] = $script:imgs.Images.Count - 1
    return $script:iconCache[$key]
}

function Get-IconIndexLarge($it) {
    $custom = [string]$it.icon
    $key = $it.type + '|' + $it.target + '|' + $custom
    if ($script:iconCacheLarge.ContainsKey($key)) { return $script:iconCacheLarge[$key] }
    $bmp = Get-IconBitmap $it 72
    [void]$script:imgsLarge.Images.Add($bmp)
    $script:iconCacheLarge[$key] = $script:imgsLarge.Images.Count - 1
    return $script:iconCacheLarge[$key]
}

function Update-List {
    $script:filtered = @()
    $script:lv.Items.Clear()
    $cands = @()
    foreach ($it in $script:allItems) {
        $s = Get-MatchScore $it $script:q
        if ($s -gt 0) { $cands += [pscustomobject]@{ it = $it; s = $s } }
    }
    if ([bool]$script:settings.showList) {
        # list mode: most-used first (relevance breaks ties)
        $sorted = @($cands | Sort-Object -Descending { ([int]$_.it.hits * 100000) + $_.s })
    } else {
        # suggestion mode: best match first (usage breaks ties)
        $sorted = @($cands | Sort-Object -Descending { ($_.s * 1000) + [int]$_.it.hits })
    }
    $large = ([string]$script:settings.listStyle -eq 'large')
    if ($large) {
        $script:lv.View = [System.Windows.Forms.View]::LargeIcon
        $script:lv.LargeImageList = $script:imgsLarge
        # enlarge each icon cell so the 72x72 image and its label are not clipped
        if ($script:FxOk -and $script:lv.IsHandleCreated) {
            [void][FluentFx]::SendMessage($script:lv.Handle, [FluentFx]::LVM_SETICONSPACING, [IntPtr]::Zero, [FluentFx]::MAKELPARAM(140, 120))
        }
    } else {
        $script:lv.View = [System.Windows.Forms.View]::Details
        $script:lv.SmallImageList = $script:imgs
    }
    foreach ($c in $sorted) {
        $script:filtered += $c.it
        $row = New-Object System.Windows.Forms.ListViewItem([string]$c.it.name)
        if (-not $large) {
            [void]$row.SubItems.Add($(if ($c.it.type -eq 'APP') { '软件' } else { '网页' }))
            $tg = $c.it.target
            if ($tg.Length -gt 56) { $tg = $tg.Substring(0, 56) + '...' }
            [void]$row.SubItems.Add($tg)
            $row.ImageIndex = Get-IconIndex $c.it
        } else {
            $row.ImageIndex = Get-IconIndexLarge $c.it
        }
        [void]$script:lv.Items.Add($row)
    }
    if ($script:lv.Items.Count -gt 0) { $script:lv.Items[0].Selected = $true }
}

function Open-Selected {
    if ($script:lv.SelectedItems.Count -eq 0) { return }
    $it = $script:filtered[$script:lv.SelectedIndices[0]]
    try {
        if ($it.type -eq 'APP') { Start-Process -FilePath $it.target }
        else { Start-Process $it.target }
        if ($it.type -eq 'APP') {
            foreach ($a in @($script:data.apps)) { if ($a.name -eq $it.name) { $a.hits = [int]$a.hits + 1; break } }
        } else {
            foreach ($w in @($script:data.webs)) { if ($w.name -eq $it.name) { $w.hits = [int]$w.hits + 1; break } }
        }
        Save-DataFile $script:data
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(('无法打开：' + $_.Exception.Message), 'QuickLauncher')
    }
    $script:form.Close()
}

# ---------------- entry editor dialog ----------------
function Show-EntryDialog {
    param([string]$Type, $Owner, $Existing)
    $df = New-Object System.Windows.Forms.Form
    $df.Text = $(if ($Existing) { '编辑' } else { '添加' }) + $(if ($Type -eq 'APP') { '软件' } else { '网页' })
    $df.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $df.MaximizeBox = $false
    $df.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $df.ClientSize = New-Object System.Drawing.Size(520, 228)
    Register-ThemedForm $df

    [void]$df.Controls.Add((New-UiLabel '名称：' 14 18 96 $false))
    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Font = New-Object System.Drawing.Font($Script:Style.Font, 11)
    $txtName.Location = New-Object System.Drawing.Point(118, 15)
    $txtName.Size = New-Object System.Drawing.Size(388, 28)
    $txtName.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    Set-Rounded $txtName 6

    [void]$df.Controls.Add((New-UiLabel $(if ($Type -eq 'APP') { '程序路径：' } else { '网址：' }) 14 58 96 $false))
    $txtTarget = New-Object System.Windows.Forms.TextBox
    $txtTarget.Font = New-Object System.Drawing.Font($Script:Style.Font, 11)
    $txtTarget.Location = New-Object System.Drawing.Point(118, 55)
    $txtTarget.Size = New-Object System.Drawing.Size($(if ($Type -eq 'APP') { 296 } else { 388 }), 28)
    $txtTarget.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    Set-Rounded $txtTarget 6

    if ($Type -eq 'APP') {
        $btnBrowse = New-UiButton '浏览...' 422 52 84
        $btnBrowse.Add_Click({
            $od = New-Object System.Windows.Forms.OpenFileDialog
            $od.Filter = '程序 (*.exe;*.lnk;*.bat;*.cmd;*.msc)|*.exe;*.lnk;*.bat;*.cmd;*.msc|全部文件 (*.*)|*.*'
            if ($od.ShowDialog($df) -eq [System.Windows.Forms.DialogResult]::OK) { $txtTarget.Text = $od.FileName }
        })
        [void]$df.Controls.Add($btnBrowse)
    }

    [void]$df.Controls.Add((New-UiLabel '关键词：' 14 98 96 $false))
    $txtKw = New-Object System.Windows.Forms.TextBox
    $txtKw.Font = New-Object System.Drawing.Font($Script:Style.Font, 11)
    $txtKw.Location = New-Object System.Drawing.Point(118, 95)
    $txtKw.Size = New-Object System.Drawing.Size(388, 28)
    $txtKw.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    Set-Rounded $txtKw 6

    # custom icon (optional; empty = auto from target / letter avatar)
    [void]$df.Controls.Add((New-UiLabel '图标：' 14 138 96 $false))
    $txtIcon = New-Object System.Windows.Forms.TextBox
    $txtIcon.Font = New-Object System.Drawing.Font($Script:Style.Font, 11)
    $txtIcon.Location = New-Object System.Drawing.Point(118, 135)
    $txtIcon.Size = New-Object System.Drawing.Size(210, 28)
    $txtIcon.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    Set-Rounded $txtIcon 6

    $btnIconBrowse = New-UiButton '浏览...' 336 132 80
    $btnIconBrowse.Add_Click({
        $od = New-Object System.Windows.Forms.OpenFileDialog
        $od.Filter = '图标 (*.ico;*.exe;*.dll;*.lnk;*.png)|*.ico;*.exe;*.dll;*.lnk;*.png|全部文件 (*.*)|*.*'
        if ($od.ShowDialog($df) -eq [System.Windows.Forms.DialogResult]::OK) { $txtIcon.Text = $od.FileName }
    })
    $btnIconAuto = New-UiButton '自动' 424 132 82
    $btnIconAuto.Add_Click({ $txtIcon.Text = '' })

    $btnOk = New-UiButton '✓ 保存' 314 178 88
    $btnOk.Tag = 'primary'
    $btnCancel = New-UiButton '取消' 418 178 88
    $btnCancel.Add_Click({ $df.Close() })

    if ($Existing) {
        $txtName.Text = [string]$Existing.name
        $txtTarget.Text = [string]$Existing.target
        $txtKw.Text = [string]$Existing.keywords
        $txtIcon.Text = [string]$Existing.icon
    }

    $btnOk.Add_Click({
        if (-not $txtName.Text.Trim() -or -not $txtTarget.Text.Trim()) {
            [void][System.Windows.Forms.MessageBox]::Show('名称和目标不能为空。', 'QuickLauncher')
            return
        }
        $df.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $df.Close()
    })
    $df.AcceptButton = $btnOk
    $df.CancelButton = $btnCancel

    [void]$df.Controls.Add($txtName)
    [void]$df.Controls.Add($txtTarget)
    [void]$df.Controls.Add($txtKw)
    [void]$df.Controls.Add($txtIcon)
    [void]$df.Controls.Add($btnIconBrowse)
    [void]$df.Controls.Add($btnIconAuto)
    [void]$df.Controls.Add($btnOk)
    [void]$df.Controls.Add($btnCancel)

    Apply-ThemeToForm $df $script:theme
    Set-FormChrome $df

    if ($df.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) {
        $tg = $txtTarget.Text.Trim()
        if ($Type -eq 'WEB' -and $tg -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $tg = 'https://' + $tg.TrimStart('/') }
        return [pscustomobject]@{ name = $txtName.Text.Trim(); target = $tg; kw = $txtKw.Text.Trim(); icon = $txtIcon.Text.Trim() }
    }
    return $null
}

# ---------------- import desktop shortcuts form ----------------
function Show-ImportForm {
    param($Owner)
    $iform = New-Object System.Windows.Forms.Form
    $iform.Text = '从桌面导入快捷方式'
    $iform.Size = New-Object System.Drawing.Size(800, 600)
    $iform.MinimumSize = New-Object System.Drawing.Size(560, 400)
    $iform.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $iform.MinimizeBox = $false
    Register-ThemedForm $iform

    $ilv = New-Object System.Windows.Forms.ListView
    $ilv.View = [System.Windows.Forms.View]::Details
    $ilv.FullRowSelect = $true
    $ilv.CheckBoxes = $true
    $ilv.HideSelection = $false
    $ilv.Location = New-Object System.Drawing.Point(12, 12)
    $ilv.Size = New-Object System.Drawing.Size(764, 472)
    $ilv.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $ilv.Font = New-Object System.Drawing.Font($Script:Style.Font, $Script:Style.FontSize)
    [void]$ilv.Columns.Add('名称', 190)
    [void]$ilv.Columns.Add('指向', 460)
    [void]$ilv.Columns.Add('状态', 90)
    $ilv.Add_Resize({ Sync-StretchColumn $ilv 1 160 })

    $gray = [System.Drawing.Color]::FromArgb(140, 140, 148)
    $ws = New-Object -ComObject WScript.Shell
    $desks = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $seen = @{}
    foreach ($d in $desks) {
        foreach ($f in (Get-ChildItem -Path $d -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
            if ($seen.ContainsKey($f.BaseName)) { continue }
            $seen[$f.BaseName] = $true
            $s = $ws.CreateShortcut($f.FullName)
            $tp = [string]$s.TargetPath
            if ($tp -match 'powershell(\.exe)?$' -and ([string]$s.Arguments) -match 'QuickLauncher') { continue }
            $exists = $false
            foreach ($a in @($script:data.apps)) { if ($a.name -eq $f.BaseName) { $exists = $true; break } }
            $ok = $true
            if (-not $tp -or ($tp -and -not (Test-Path $tp))) { $ok = $false }
            $item = $ilv.Items.Add($f.BaseName)
            [void]$item.SubItems.Add($tp)
            if ($exists) { [void]$item.SubItems.Add('已存在') }
            elseif (-not $ok) { [void]$item.SubItems.Add('目标缺失') }
            else { [void]$item.SubItems.Add('待导入') }
            $item.Checked = ($ok -and -not $exists)
            if (-not ($ok -and -not $exists)) { $item.ForeColor = $gray }
            $item.Tag = @{ name = $f.BaseName; lnk = $f.FullName; exists = $exists; ok = $ok }
        }
    }

    $btnAll = New-UiButton '全选' 12 496 72
    $anchorIBL = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnAll.Anchor = $anchorIBL
    $btnAll.Add_Click({
        foreach ($it in $ilv.Items) { if ($it.Tag.ok -and -not $it.Tag.exists) { $it.Checked = $true } }
    })
    $btnNone = New-UiButton '清空' 92 496 72
    $btnNone.Anchor = $anchorIBL
    $btnNone.Add_Click({
        foreach ($it in $ilv.Items) { $it.Checked = $false }
    })
    $btnGo = New-UiButton '✓ 导入选中' 184 496 104
    $btnGo.Anchor = $anchorIBL
    $btnGo.Tag = 'primary'
    $btnGo.Add_Click({
        $n = 0
        foreach ($it in $ilv.Items) {
            if ($it.Checked -and $it.Tag.ok -and -not $it.Tag.exists) {
                $script:data.apps = @($script:data.apps + [pscustomobject]@{ name = $it.Tag.name; target = $it.Tag.lnk; keywords = ''; hits = 0 })
                $n++
            }
        }
        if ($n -gt 0) { Save-DataFile $script:data }
        [void][System.Windows.Forms.MessageBox]::Show(('已导入 {0} 个条目，搜索框直接可用（含拼音首字母）。' -f $n), '从桌面导入')
        $iform.Close()
    })
    $btnClose = New-UiButton '关闭' 688 496 88
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.Add_Click({ $iform.Close() })

    [void]$iform.Controls.Add($ilv)
    [void]$iform.Controls.Add($btnAll)
    [void]$iform.Controls.Add($btnNone)
    [void]$iform.Controls.Add($btnGo)
    [void]$iform.Controls.Add($btnClose)

    Apply-ThemeToForm $iform $script:theme
    Set-FormChrome $iform
    Use-ThemedHeader $ilv

    [void]$iform.ShowDialog($Owner)
    $iform.Dispose()
}

# ---------------- drag-drop batch import dialog ----------------
function Show-DropBatchDialog($files, $Owner) {
    $bform = New-Object System.Windows.Forms.Form
    $bform.Text = '拖拽导入：选择类型'
    $bform.Size = New-Object System.Drawing.Size(640, 480)
    $bform.MinimumSize = New-Object System.Drawing.Size(480, 320)
    $bform.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $bform.MinimizeBox = $false
    Register-ThemedForm $bform

    $blv = New-Object System.Windows.Forms.ListView
    $blv.View = [System.Windows.Forms.View]::Details
    $blv.FullRowSelect = $true
    $blv.HideSelection = $false
    $blv.CheckBoxes = $true
    $blv.Location = New-Object System.Drawing.Point(12, 12)
    $blv.Size = New-Object System.Drawing.Size(600, 344)
    $blv.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $blv.Font = New-Object System.Drawing.Font($Script:Style.Font, $Script:Style.FontSize)
    [void]$blv.Columns.Add('名称', 180)
    [void]$blv.Columns.Add('指向', 320)
    [void]$blv.Columns.Add('类型', 80)
    $blv.Add_Resize({ Sync-StretchColumn $blv 1 120 })

    $ws = New-Object -ComObject WScript.Shell
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $target = ''
        $type = 'APP'
        if ($f -match '\.url$') {
            $type = 'WEB'
            $ini = Get-Content $f -ErrorAction SilentlyContinue
            foreach ($line in $ini) { if ($line -match '^URL=(.+)$') { $target = $matches[1]; break } }
        } else {
            try {
                $s = $ws.CreateShortcut($f)
                $target = [string]$s.TargetPath
                if (-not $target) { $target = [string]$s.Target }
                if ($target -match '^https?://') { $type = 'WEB' }
            } catch { $target = $f }
        }
        if (-not $target) { $target = $f }
        $i = $blv.Items.Add($name)
        [void]$i.SubItems.Add($target)
        [void]$i.SubItems.Add($(if ($type -eq 'APP') { '软件' } else { '网页' }))
        $i.Checked = $true
        $i.Tag = @{ name = $name; target = $target; type = $type }
    }

    function Toggle-Type($it) {
        if ($it.Tag.type -eq 'APP') { $it.Tag.type = 'WEB'; $it.SubItems[2].Text = '网页' }
        else { $it.Tag.type = 'APP'; $it.SubItems[2].Text = '软件' }
    }
    function Set-AllType($t) {
        foreach ($it in $blv.Items) { if ($it.Checked) { $it.Tag.type = $t; $it.SubItems[2].Text = $(if ($t -eq 'APP') { '软件' } else { '网页' }) } }
    }

    $blv.Add_DoubleClick({ if ($blv.SelectedItems.Count -gt 0) { Toggle-Type $blv.SelectedItems[0] } })

    $btnApp = New-UiButton '全部软件' 12 368 84
    $btnApp.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnApp.Add_Click({ Set-AllType 'APP' })
    $btnWeb = New-UiButton '全部网页' 104 368 84
    $btnWeb.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnWeb.Add_Click({ Set-AllType 'WEB' })
    $btnImport = New-UiButton '✓ 导入选中' 196 368 104
    $btnImport.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $btnImport.Tag = 'primary'
    $btnImport.Add_Click({
        $n = 0
        foreach ($it in $blv.Items) {
            if (-not $it.Checked) { continue }
            $existing = @($script:data.apps) + @($script:data.webs) | Where-Object { $_.name -eq $it.Tag.name }
            if ($existing) { continue }
            if ($it.Tag.type -eq 'APP') {
                $script:data.apps = @($script:data.apps + [pscustomobject]@{ name = $it.Tag.name; target = $it.Tag.target; keywords = ''; icon = ''; hits = 0 })
            } else {
                $script:data.webs = @($script:data.webs + [pscustomobject]@{ name = $it.Tag.name; target = $it.Tag.target; keywords = ''; icon = ''; hits = 0 })
            }
            $n++
        }
        if ($n -gt 0) {
            Save-DataFile $script:data
            [void][System.Windows.Forms.MessageBox]::Show(("已导入 {0} 个条目。" -f $n), '拖拽导入')
        }
        $bform.Close()
    })
    $btnClose = New-UiButton '关闭' 524 368 88
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $btnClose.Add_Click({ $bform.Close() })

    [void]$bform.Controls.Add($blv)
    [void]$bform.Controls.Add($btnApp); [void]$bform.Controls.Add($btnWeb); [void]$bform.Controls.Add($btnImport); [void]$bform.Controls.Add($btnClose)
    Apply-ThemeToForm $bform $script:theme
    Set-FormChrome $bform
    Use-ThemedHeader $blv
    [void]$bform.ShowDialog($Owner)
    $bform.Dispose()
}

# ---------------- config import / export ----------------
function Export-Config($Owner) {
    $sd = New-Object System.Windows.Forms.SaveFileDialog
    $sd.Filter = 'JSON 配置文件 (*.json)|*.json'
    $sd.FileName = 'QuickLauncher-config.json'
    if ($sd.ShowDialog($Owner) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    [System.IO.File]::WriteAllText($sd.FileName, ($script:data | ConvertTo-Json -Depth 5), $Script:Utf8NoBom)
    [void][System.Windows.Forms.MessageBox]::Show(('配置已导出到：' + $sd.FileName), '导出配置')
}

function Import-Config($Owner) {
    $od = New-Object System.Windows.Forms.OpenFileDialog
    $od.Filter = 'JSON 配置文件 (*.json)|*.json'
    if ($od.ShowDialog($Owner) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $raw = [System.IO.File]::ReadAllText($od.FileName, [System.Text.Encoding]::UTF8)
        $imp = $raw | ConvertFrom-Json
        if ($null -eq $imp -or $null -eq $imp.apps -or $null -eq $imp.webs -or $null -eq $imp.settings) {
            throw '文件缺少必要的 apps/webs/settings 字段'
        }
        $cnt = @($imp.apps).Count + @($imp.webs).Count
        $ans = [System.Windows.Forms.MessageBox]::Show(("导入将覆盖当前 {0} 个条目和全部设置，是否继续？" -f $cnt), '确认导入', [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:data = $imp
        Save-DataFile $script:data
        $script:settings = $script:data.settings
        $script:theme = Get-Theme
        # rebuild allItems
        $script:allItems.Clear()
        foreach ($a in @($script:data.apps)) {
            [void]$script:allItems.Add([pscustomobject]@{ type = 'APP'; name = [string]$a.name; target = [string]$a.target; keywords = [string]$a.keywords; hits = [int]$a.hits; py = (Get-PyInitials ([string]$a.name)); icon = [string]$a.icon })
        }
        foreach ($w in @($script:data.webs)) {
            [void]$script:allItems.Add([pscustomobject]@{ type = 'WEB'; name = [string]$w.name; target = [string]$w.target; keywords = [string]$w.keywords; hits = [int]$w.hits; py = (Get-PyInitials ([string]$w.name)); icon = [string]$w.icon })
        }
        Update-ThemeAll
        [void][System.Windows.Forms.MessageBox]::Show('导入成功，配置已保存。', '导入配置')
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show(('导入失败：' + $_.Exception.Message), '导入配置')
    }
}

# ---------------- settings form ----------------
function Show-SettingsForm {
    param($Owner)
    $sf = New-Object System.Windows.Forms.Form
    $sf.Text = '设置'
    $sf.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $sf.MaximizeBox = $true
    $sf.MinimizeBox = $false
    $sf.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $sf.ClientSize = New-Object System.Drawing.Size(440, 540)
    $sf.MinimumSize = New-Object System.Drawing.Size(400, 420)
    Register-ThemedForm $sf

    $anchorTop = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $anchorAll = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $anchorTL  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $anchorTR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $anchorBL = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $anchorBR = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

    $lblTheme = New-UiLabel '主题模式' 20 18 200 $false
    $lblTheme.Font = New-Object System.Drawing.Font($Script:Style.Font, 10, [System.Drawing.FontStyle]::Bold)
    $lblTheme.Anchor = $anchorTop

    $rbSys   = New-Object System.Windows.Forms.RadioButton
    $rbLight = New-Object System.Windows.Forms.RadioButton
    $rbDark  = New-Object System.Windows.Forms.RadioButton
    $rbSys.Text = '跟随系统';   $rbLight.Text = '白天模式';   $rbDark.Text = '夜间模式'
    $rbSys.Location = New-Object System.Drawing.Point(24, 46)
    $rbLight.Location = New-Object System.Drawing.Point(24, 72)
    $rbDark.Location = New-Object System.Drawing.Point(24, 98)
    foreach ($rb in @($rbSys, $rbLight, $rbDark)) {
        $rb.Size = New-Object System.Drawing.Size(180, 24)
        $rb.Font = New-Object System.Drawing.Font($Script:Style.Font, 9)
        $rb.Anchor = $anchorTop
    }
    switch ([string]$script:settings.theme) {
        'light' { $rbLight.Checked = $true }
        'dark'  { $rbDark.Checked = $true }
        default { $rbSys.Checked = $true }
    }
    $rbSys.Add_CheckedChanged({ if ($rbSys.Checked)     { Set-UiSetting 'theme' 'system' } })
    $rbLight.Add_CheckedChanged({ if ($rbLight.Checked) { Set-UiSetting 'theme' 'light' } })
    $rbDark.Add_CheckedChanged({ if ($rbDark.Checked)   { Set-UiSetting 'theme' 'dark' } })

    # ---- window effects group ----
    $grp = New-Object System.Windows.Forms.GroupBox
    $grp.Text = '窗口效果'
    $grp.Location = New-Object System.Drawing.Point(16, 130)
    $grp.Size = New-Object System.Drawing.Size(408, 100)
    $grp.Font = New-Object System.Drawing.Font($Script:Style.Font, 10, [System.Drawing.FontStyle]::Bold)
    $grp.Anchor = $anchorTop

    $script:FxSync = $false
    function Sync-EffectCheckboxes {
        $script:FxSync = $true
        Set-UiCheckState $cbT ([bool]$script:settings.transparency)
        Set-UiCheckState $cbA ([bool]$script:settings.acrylic)
        $script:FxSync = $false
    }
    $cbT = New-UiCheck '透明效果（窗口半透明）' 16 28 ([bool]$script:settings.transparency) {
        param($v)
        if ($script:FxSync) { return }
        Set-UiSetting 'transparency' $v
        Sync-EffectCheckboxes
    }
    $cbA = New-UiCheck '毛玻璃（亚克力）效果' 16 56 ([bool]$script:settings.acrylic) {
        param($v)
        if ($script:FxSync) { return }
        Set-UiSetting 'acrylic' $v
        Sync-EffectCheckboxes
    }

    [void]$grp.Controls.Add($cbT)
    [void]$grp.Controls.Add($cbA)

    # ---- hotkeys group ----
    $grpHk = New-Object System.Windows.Forms.GroupBox
    $grpHk.Text = '快捷键设置'
    $grpHk.Location = New-Object System.Drawing.Point(16, 240)
    $grpHk.Size = New-Object System.Drawing.Size(408, 236)
    $grpHk.Font = New-Object System.Drawing.Font($Script:Style.Font, 10, [System.Drawing.FontStyle]::Bold)
    $grpHk.Anchor = $anchorAll

    function New-HotkeyRow($label, $value, $y, $key) {
        $l = New-UiLabel $label 16 $y 90 $false
        $l.Anchor = $anchorTL
        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Text = [string]$value
        $txt.Location = New-Object System.Drawing.Point(110, ($y - 2))
        $txt.Size = New-Object System.Drawing.Size(220, 26)
        $txt.Font = New-Object System.Drawing.Font($Script:Style.Font, 9)
        $txt.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $txt.Anchor = $anchorTop
        Set-Rounded $txt 5
        $txt.Add_Leave({
            $v = $this.Text.Trim()
            if ($v) {
                $parts = @($v.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                try { [void][System.Windows.Forms.Keys]::Parse([System.Windows.Forms.Keys], $parts[-1]) } catch {
                    [void][System.Windows.Forms.MessageBox]::Show('快捷键格式无效，示例：Ctrl+Alt+M、F1、Ctrl+Shift+E', '快捷键')
                    $this.Focus()
                }
            }
        })
        $txt.Add_TextChanged({
            $v = $this.Text.Trim()
            $script:settings.hotkeys.$key = $v
            Save-DataFile $script:data
        })
        [void]$grpHk.Controls.Add($l)
        [void]$grpHk.Controls.Add($txt)
    }
    New-HotkeyRow '召唤搜索框：'   $script:settings.hotkeys.summon     28  'summon'
    New-HotkeyRow '打开管理页：'   $script:settings.hotkeys.manage     56  'manage'
    New-HotkeyRow '打开设置：'     $script:settings.hotkeys.settings   84  'settings'
    New-HotkeyRow '切换主题：'     $script:settings.hotkeys.toggleTheme 112 'toggleTheme'
    New-HotkeyRow '切换列表：'     $script:settings.hotkeys.toggleList  140 'toggleList'
    New-HotkeyRow '打开导入：'     $script:settings.hotkeys.import     168 'import'

    $btnUpdateSummon = New-UiButton '更新' 340 25 52
    $btnUpdateSummon.Anchor = $anchorTR
    $btnUpdateSummon.Add_Click({
        try {
            $ws = New-Object -ComObject WScript.Shell
            $desktop = [Environment]::GetFolderPath('Desktop')
            $lnkPath = Join-Path $desktop 'QuickLauncher.lnk'
            $lnk = $ws.CreateShortcut($lnkPath)
            $lnk.TargetPath = (Join-Path $PSHOME 'powershell.exe')
            $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
            $lnk.WindowStyle = 7
            $hk = ($script:settings.hotkeys.summon -replace '\+', '+' -replace '\s+', '').ToUpper()
            if (-not $hk) { $hk = 'CTRL+ALT+SPACE' }
            $lnk.Hotkey = $hk
            $lnk.Description = 'QuickLauncher'
            $lnk.Save()
            [void][System.Windows.Forms.MessageBox]::Show(("召唤热键已更新为：{0}" -f $hk), '快捷键')
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show(('更新失败：' + $_.Exception.Message), '快捷键')
        }
    })
    [void]$grpHk.Controls.Add($btnUpdateSummon)

    # ---- import / export buttons ----
    $btnExport = New-UiButton '导出配置' 16 488 88
    $btnExport.Anchor = $anchorBL
    $btnExport.Add_Click({ Export-Config $sf })
    $btnImport = New-UiButton '导入配置' 112 488 88
    $btnImport.Anchor = $anchorBL
    $btnImport.Add_Click({ Import-Config $sf })

    $btnClose = New-UiButton '关闭' 332 488 88
    $btnClose.Anchor = $anchorBR
    $btnClose.Add_Click({ $sf.Close() })

    [void]$sf.Controls.Add($lblTheme)
    [void]$sf.Controls.Add($rbSys); [void]$sf.Controls.Add($rbLight); [void]$sf.Controls.Add($rbDark)
    [void]$sf.Controls.Add($grp)
    [void]$sf.Controls.Add($grpHk)
    [void]$sf.Controls.Add($btnExport); [void]$sf.Controls.Add($btnImport)
    [void]$sf.Controls.Add($btnClose)

    Sync-EffectCheckboxes

    Apply-ThemeToForm $sf $script:theme
    Set-FormChrome $sf

    if ($script:FxCheck) {
        $ft = New-Object System.Windows.Forms.Timer
        $ft.Interval = 450
        $script:FxStep = 0
        $ft.Add_Tick({
            $script:FxStep++
            try {
                switch ($script:FxStep) {
                    1 { & $cbA.Tag.invoke $cbA }
                    2 { if (-not $cbT.Tag.checked) { throw 'linkage: transparency not auto-enabled by acrylic' }
                        if (-not [bool]$script:settings.transparency) { throw 'linkage: settings.transparency not saved' } }
                    3 { & $cbT.Tag.invoke $cbT }
                    4 { if ($cbA.Tag.checked) { throw 'acrylic should turn off when transparency disabled' }
                        if ([bool]$script:settings.acrylic) { throw 'settings.acrylic should turn off when transparency disabled' } }
                    5 { $ft.Stop(); $sf.Close() }
                }
            } catch {
                $ft.Stop()
                [System.IO.File]::WriteAllText((Join-Path $Script:ScriptDir '_gui_ok.txt'), ('FXCHECK-FAIL step {0}: {1}' -f $script:FxStep, $_.Exception.Message))
                $sf.Close()
            }
        })
        $ft.Start()
    }

    [void]$sf.ShowDialog($Owner)
    $sf.Dispose()
}

# ---------------- entry manager form ----------------
function Show-ManageForm {
    $mform = New-Object System.Windows.Forms.Form
    $mform.Text = 'QuickLauncher 条目管理'
    $mform.Size = New-Object System.Drawing.Size(820, 600)
    $mform.MinimumSize = New-Object System.Drawing.Size(640, 420)
    $mform.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $mform.MinimizeBox = $false
    $mform.KeyPreview = $true
    Register-ThemedForm $mform

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = [System.Windows.Forms.View]::Details
    $lv.FullRowSelect = $true
    $lv.HideSelection = $false
    $lv.Location = New-Object System.Drawing.Point(12, 12)
    $lv.Size = New-Object System.Drawing.Size(784, 472)
    $lv.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $lv.Font = New-Object System.Drawing.Font($Script:Style.Font, $Script:Style.FontSize)
    [void]$lv.Columns.Add('', 40)
    [void]$lv.Columns.Add('类型', 50)
    [void]$lv.Columns.Add('名称', 150)
    [void]$lv.Columns.Add('关键词', 140)
    [void]$lv.Columns.Add('目标', 340)
    [void]$lv.Columns.Add('次数', 64)
    $lv.SmallImageList = $script:imgs
    $lv.Add_Resize({ Sync-StretchColumn $lv 4 120 })
    $lv.AllowDrop = $true
    $lv.Add_DragEnter({
        if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $files = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            if (@($files | Where-Object { $_ -match '\.(lnk|url)$' }).Count -gt 0) { $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy }
        }
    })
    $lv.Add_DragDrop({
        $files = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        $lnks = @($files | Where-Object { $_ -match '\.(lnk|url)$' })
        if ($lnks.Count -gt 0) {
            Show-DropBatchDialog $lnks $mform
            Refresh-MList
        }
    })

    $btnAddApp   = New-UiButton '＋ 添加软件'   12 496 96
    $btnAddWeb   = New-UiButton '＋ 添加网页'  114 496 96
    $btnImport   = New-UiButton '⤓ 从桌面导入'  216 496 108
    $btnSettings = New-UiButton '⚙ 设置'       330 496 84
    $btnDone     = New-UiButton '完成'         708 496 88
    $anchorBL = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    foreach ($b in @($btnAddApp, $btnAddWeb, $btnImport, $btnSettings)) { $b.Anchor = $anchorBL }
    $btnDone.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

    function Refresh-MList {
        $lv.Items.Clear()
        foreach ($a in @($script:data.apps)) {
            $i = $lv.Items.Add('')
            [void]$i.SubItems.Add('软件')
            [void]$i.SubItems.Add([string]$a.name)
            [void]$i.SubItems.Add([string]$a.keywords)
            [void]$i.SubItems.Add([string]$a.target)
            [void]$i.SubItems.Add([string]$a.hits)
            $i.ImageIndex = Get-IconIndex ([pscustomobject]@{ type = 'APP'; name = $a.name; target = $a.target; icon = $a.icon })
            $i.Tag = @{ coll = 'apps'; name = [string]$a.name; type = 'APP' }
        }
        foreach ($w in @($script:data.webs)) {
            $i = $lv.Items.Add('')
            [void]$i.SubItems.Add('网页')
            [void]$i.SubItems.Add([string]$w.name)
            [void]$i.SubItems.Add([string]$w.keywords)
            [void]$i.SubItems.Add([string]$w.target)
            [void]$i.SubItems.Add([string]$w.hits)
            $i.ImageIndex = Get-IconIndex ([pscustomobject]@{ type = 'WEB'; name = $w.name; target = $w.target; icon = $w.icon })
            $i.Tag = @{ coll = 'webs'; name = [string]$w.name; type = 'WEB' }
        }
    }

    function Edit-Selected {
        if ($lv.SelectedItems.Count -eq 0) { return }
        $sel = $lv.SelectedItems[0]
        $ent = @($script:data.($sel.Tag.coll)) | Where-Object { $_.name -eq $sel.Tag.name } | Select-Object -First 1
        if (-not $ent) { return }
        $r = Show-EntryDialog -Type ([string]$sel.Tag.type) -Owner $mform -Existing $ent
        if ($r) {
            $ent.name = $r.name; $ent.target = $r.target; $ent.keywords = $r.kw; $ent.icon = $r.icon
            Save-DataFile $script:data
            Refresh-MList
        }
    }

    # quick type conversion: move the entry between the apps and webs collections in place
    function Convert-Selected {
        if ($lv.SelectedItems.Count -eq 0) { return }
        $sel = $lv.SelectedItems[0]
        $fromColl = $sel.Tag.coll
        $toColl = $(if ($fromColl -eq 'apps') { 'webs' } else { 'apps' })
        $ent = @($script:data.$fromColl) | Where-Object { $_.name -eq $sel.Tag.name } | Select-Object -First 1
        if (-not $ent) { return }
        $script:data.$fromColl = @($script:data.$fromColl | Where-Object { $_.name -ne $sel.Tag.name })
        $script:data.$toColl = @($script:data.$toColl + $ent)
        Save-DataFile $script:data
        Refresh-MList
    }

    function Remove-Selected {
        if ($lv.SelectedItems.Count -eq 0) { return }
        $sel = $lv.SelectedItems[0]
        $coll = $sel.Tag.coll
        $cname = $sel.Tag.name
        $ans = [System.Windows.Forms.MessageBox]::Show(("确定删除「{0}」？" -f $cname), '确认', [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:data.$coll = @($script:data.$coll | Where-Object { $_.name -ne $cname })
            Save-DataFile $script:data
            Refresh-MList
        }
    }

    $btnAddApp.Add_Click({
        $r = Show-EntryDialog -Type 'APP' -Owner $mform
        if ($r) {
            $script:data.apps = @($script:data.apps + [pscustomobject]@{ name = $r.name; target = $r.target; keywords = $r.kw; icon = $r.icon; hits = 0 })
            Save-DataFile $script:data
            Refresh-MList
        }
    })
    $btnAddWeb.Add_Click({
        $r = Show-EntryDialog -Type 'WEB' -Owner $mform
        if ($r) {
            $script:data.webs = @($script:data.webs + [pscustomobject]@{ name = $r.name; target = $r.target; keywords = $r.kw; icon = $r.icon; hits = 0 })
            Save-DataFile $script:data
            Refresh-MList
        }
    })
    $btnImport.Add_Click({ Show-ImportForm -Owner $mform })
    $btnSettings.Add_Click({ Show-SettingsForm -Owner $mform })
    $btnDone.Add_Click({ $mform.Close() })
    $lv.Add_DoubleClick({ Edit-Selected })

    # right-click menu: edit / convert type / delete (replaces the old standalone buttons)
    $cms = New-Object System.Windows.Forms.ContextMenuStrip
    $miEdit = $cms.Items.Add('✎ 编辑')
    $miConv = $cms.Items.Add('')
    $miDel  = $cms.Items.Add('✕ 删除')
    $miEdit.Add_Click({ Edit-Selected })
    $miConv.Add_Click({ Convert-Selected })
    $miDel.Add_Click({ Remove-Selected })
    $cms.Add_Opening({
        if ($lv.SelectedItems.Count -eq 0) { $_.Cancel = $true; return }
        $miConv.Text = $(if ($lv.SelectedItems[0].Tag.type -eq 'APP') { '⇄ 转为网页' } else { '⇄ 转为软件' })
    })
    $lv.ContextMenuStrip = $cms
    Set-MenuTheme $cms

    $mform.Add_KeyDown({
        if     ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $mform.Close() }
        elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Delete) { Remove-Selected }
    })

    [void]$mform.Controls.Add($lv)
    foreach ($b in @($btnAddApp, $btnAddWeb, $btnImport, $btnSettings, $btnDone)) {
        [void]$mform.Controls.Add($b)
    }

    if ($script:AutoClose) {
        $mt = New-Object System.Windows.Forms.Timer
        $mt.Interval = 2500
        $mt.Add_Tick({ $mform.Close() })
        $mt.Start()
    }

    Apply-ThemeToForm $mform $script:theme
    Set-FormChrome $mform
    Use-ThemedHeader $lv
    Refresh-MList
    Sync-StretchColumn $lv 4 120
    [void]$mform.ShowDialog()
    $mform.Dispose()
}

# ---------------- launcher form ----------------
$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'QuickLauncher'
$script:form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$script:form.TopMost = $true
$script:form.ShowInTaskbar = $false
$script:form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$script:form.KeyPreview = $true

function Invoke-Hotkey($e) {
    $hk = $script:settings.hotkeys
    if (Test-Hotkey $e $hk.manage)     { $script:WantManage = $true; $script:form.Close(); return $true }
    if (Test-Hotkey $e $hk.settings)   { $script:WantSettings = $true; $script:form.Close(); return $true }
    if (Test-Hotkey $e $hk.import)     { $script:WantImport = $true; $script:form.Close(); return $true }
    if (Test-Hotkey $e $hk.toggleTheme) { $dark = Test-IsDarkTheme $script:theme; Set-UiSetting 'theme' $(if ($dark) { 'light' } else { 'dark' }); return $true }
    if (Test-Hotkey $e $hk.toggleList)  { Set-UiSetting 'showList' (-not [bool]$script:settings.showList); Update-List; Update-ListMode; return $true }
    return $false
}
$script:form.Size = New-Object System.Drawing.Size(620, 470)
$script:form.MinimumSize = New-Object System.Drawing.Size(480, 360)
Register-ThemedForm $script:form

# standard search textbox (default skin, resizable with the window)
$script:tb = New-Object System.Windows.Forms.TextBox
$script:tb.Font = New-Object System.Drawing.Font($Script:Style.Font, 16)
$script:tb.Location = New-Object System.Drawing.Point(16, 16)
$script:tb.Size = New-Object System.Drawing.Size(588, 32)
$script:tb.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:form.Add_Resize({ $script:tb.Width = [Math]::Max(100, $script:form.ClientSize.Width - 32) })

$script:lv = New-Object System.Windows.Forms.ListView
$script:lv.View = [System.Windows.Forms.View]::Details
$script:lv.FullRowSelect = $true
$script:lv.HideSelection = $false
$script:lv.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::None
$script:lv.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:lv.Location = New-Object System.Drawing.Point(16, 96)
$script:lv.Size = New-Object System.Drawing.Size(588, 294)
$script:lv.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:lv.Font = New-Object System.Drawing.Font($Script:Style.Font, $Script:Style.FontSize)
[void]$script:lv.Columns.Add('名称', 216)
[void]$script:lv.Columns.Add('类型', 52)
[void]$script:lv.Columns.Add('目标', 320)
$script:lv.Add_Resize({ Sync-StretchColumn $script:lv 2 120 })

$script:imgs = New-Object System.Windows.Forms.ImageList
$script:imgs.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$script:imgs.ImageSize = New-Object System.Drawing.Size(32, 32)
$script:lv.SmallImageList = $script:imgs
$script:imgsLarge = New-Object System.Windows.Forms.ImageList
$script:imgsLarge.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit
$script:imgsLarge.ImageSize = New-Object System.Drawing.Size(72, 72)
$script:lv.LargeImageList = $script:imgsLarge
$script:iconCache = @{}
$script:iconCacheLarge = @{}

# list display toggle (below the search box, left side) + sun/moon quick theme switch:
#   list ON  = full list, most-used first
#   list OFF = compact bar; suggestions pop up only while typing; manage button docks to the search box's bottom-right
$script:cbList = New-UiCheck '显示列表' 18 66 ([bool]$script:settings.showList) {
    param($v)
    if ($script:ListModeSync) { return }
    Set-UiSetting 'showList' $v
    Update-List
    Update-ListMode
}
$script:themeSwitch = New-ThemeSwitch 132 66

$script:cbStyle = New-UiCheck '大图标' 210 66 ([string]$script:settings.listStyle -eq 'large') {
    param($v)
    Set-UiSetting 'listStyle' $(if ($v) { 'large' } else { 'details' })
    Update-List
    if (-not [bool]$script:settings.showList) { Update-ListMode }
}

$script:hint = New-UiLabel '回车打开 · Esc 或点别处关闭 · ↑↓ 选择 · 支持名称 / 关键词 / 拼音首字母' 18 402 470 $true
$script:hint.AutoSize = $true
$script:hint.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

# manage entry (bottom-right); width sized so the full text is visible
$script:btnManage = New-UiButton '⚙ 管理' 520 398 84
$script:btnManage.Size = New-Object System.Drawing.Size(84, 30)
$script:btnManage.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
Set-Rounded $script:btnManage $Script:Style.RadiusSm
$script:btnManage.Add_Click({ $script:WantManage = $true; $script:form.Close() })

[void]$script:form.Controls.Add($script:tb)
[void]$script:form.Controls.Add($script:cbList)
[void]$script:form.Controls.Add($script:themeSwitch)
[void]$script:form.Controls.Add($script:cbStyle)
[void]$script:form.Controls.Add($script:lv)
[void]$script:form.Controls.Add($script:hint)
[void]$script:form.Controls.Add($script:btnManage)

# ---------- list-mode (toggle) logic ----------
$script:savedSize = $null
$script:ListModeSync = $false
$script:anchorTLR = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$script:anchorAll = $script:anchorTLR -bor [System.Windows.Forms.AnchorStyles]::Bottom
$script:anchorTR  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$script:anchorBR  = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right

function Update-ListMode {
    $on = [bool]$script:settings.showList
    $script:ListModeSync = $true
    Set-UiCheckState $script:cbList $on
    $script:ListModeSync = $false
    if ($on) {
        # full list mode
        $script:form.MinimumSize = New-Object System.Drawing.Size(480, 360)
        if ($script:savedSize) { $script:form.Size = $script:savedSize; $script:savedSize = $null }
        $script:lv.Anchor = $script:anchorAll
        $script:lv.Visible = $true
        $script:hint.Visible = $true
        $script:btnManage.Anchor = $script:anchorTR
        $script:btnManage.Location = New-Object System.Drawing.Point(($script:form.ClientSize.Width - 100), ($script:form.ClientSize.Height - 72))
        $script:btnManage.Anchor = $script:anchorBR
    } else {
        # suggestion mode: compact bar, list pops up while typing; bottom hint hidden
        if (-not $script:savedSize) { $script:savedSize = $script:form.Size }
        $script:form.MinimumSize = New-Object System.Drawing.Size(480, 140)
        $script:hint.Visible = $false
        $script:btnManage.Anchor = $script:anchorTR
        $script:btnManage.Location = New-Object System.Drawing.Point(($script:form.ClientSize.Width - 100), 64)
        $script:lv.Anchor = $script:anchorTLR
        $rows = $script:lv.Items.Count
        if ($script:q -and $rows -gt 0) {
            $listH = [Math]::Min($rows, 8) * 28 + 8
            $script:lv.Location = New-Object System.Drawing.Point(16, 96)
            $script:lv.Size = New-Object System.Drawing.Size(($script:form.ClientSize.Width - 32), $listH)
            $script:lv.Visible = $true
            $script:form.Height = 96 + $listH + 48
        } else {
            $script:lv.Visible = $false
            $script:form.Height = 140
        }
    }
}

$script:tb.Add_TextChanged({
    $script:q = $script:tb.Text.Trim().ToLower()
    Update-List
    if (-not [bool]$script:settings.showList) { Update-ListMode }
})
$script:form.Add_KeyDown({
    if (Invoke-Hotkey $_) { $_.Handled = $true }
})
$script:tb.Add_KeyDown({
    if     ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter)  { Open-Selected }
    elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $script:form.Close() }
    elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Down)   { if ($script:lv.Items.Count -gt 0 -and $script:lv.Visible) { $script:lv.Focus() } }
    elseif (Invoke-Hotkey $_) { $_.Handled = $true }
})
$script:lv.Add_KeyDown({
    if     ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter)  { Open-Selected }
    elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $script:form.Close() }
    elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Up)     { if ($script:lv.SelectedItems.Count -gt 0 -and $script:lv.SelectedIndices[0] -eq 0) { $script:tb.Focus() } }
    elseif (Invoke-Hotkey $_) { $_.Handled = $true }
})
$script:lv.Add_DoubleClick({ Open-Selected })
$script:form.Add_Deactivate({ $script:form.Close() })
$script:form.Add_Shown({ $script:tb.Focus() })

# ---------------- run ----------------
if ($script:OpenManage) {
    Show-ManageForm
    if ($script:FxCheck) {
        Show-SettingsForm $null
        $okPath = Join-Path $Script:ScriptDir '_gui_ok.txt'
        if (-not (Test-Path $okPath)) {
            [System.IO.File]::WriteAllText($okPath, 'fxcheck OK: effect toggles + linkage all passed')
        }
    }
} else {
    Update-List
    Sync-StretchColumn $script:lv 2 120
    Update-ListMode
    Apply-ThemeToForm $script:form $script:theme
    Set-FormChrome $script:form
    if ($script:AutoClose) {
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = 1500
        $t.Add_Tick({
            $t.Stop()
            try {
                # ensure predictable starting state for the self-test
                if (-not [bool]$script:settings.showList) {
                    Set-UiSetting 'showList' $true
                    Update-List
                    Update-ListMode
                }
                # responsive layout self-test: stretch the window, controls must follow
                $script:form.Size = New-Object System.Drawing.Size(760, 560)
                $script:form.PerformLayout()
                $cw = $script:form.ClientSize.Width
                $ch = $script:form.ClientSize.Height
                $checks = @(
                    ('search-follows=' + ($script:tb.Right -ge ($cw - 18) -and $script:tb.Right -le ($cw - 14))),
                    ('list-follows=' + ($script:lv.Bottom -ge ($ch - 90))),
                    ('manage-btn-right=' + ($script:btnManage.Right -eq ($cw - 16)))
                )
                # list-mode toggle: OFF = compact + suggestions on typing, ON = restored
                & $script:cbList.Tag.invoke $script:cbList
                $checks += 'off-hidden=' + (-not $script:lv.Visible)
                $checks += 'off-compact=' + ($script:form.Height -le 160)
                $checks += 'off-hint-hidden=' + (-not $script:hint.Visible)
                $checks += 'off-btn-docked=' + ($script:btnManage.Top -ge 60 -and $script:btnManage.Top -le 70 -and $script:btnManage.Right -eq ($script:form.ClientSize.Width - 16))
                $script:tb.Text = 'git'
                $checks += 'suggest-shown=' + $script:lv.Visible
                $checks += 'suggest-fit=' + ($script:form.Height -gt 150)
                $script:tb.Text = ''
                & $script:cbList.Tag.invoke $script:cbList
                $checks += 'on-restored=' + ($script:lv.Visible -and $script:form.Height -ge 500)
                $checks += 'on-hint-shown=' + $script:hint.Visible
                [System.IO.File]::WriteAllText((Join-Path $Script:ScriptDir '_layout.txt'), ($checks -join ' '))
            } catch {
                [System.IO.File]::WriteAllText((Join-Path $Script:ScriptDir '_layout.txt'), ('LAYOUT-FAIL: ' + $_.Exception.Message + ' || ' + $_.InvocationInfo.PositionMessage))
            }
            $script:form.Close()
        })
        $t.Start()
    }
    [void]$script:form.ShowDialog()
    $script:form.Dispose()
    if ($script:WantManage) { Show-ManageForm }
    if ($script:WantSettings) { Show-SettingsForm $null }
    if ($script:WantImport) { Show-ImportForm $null }
    if ($script:AutoClose) {
        Show-ManageForm
        [System.IO.File]::WriteAllText((Join-Path $Script:ScriptDir '_gui_ok.txt'), ('ok, entries=' + $script:filtered.Count + ' + manage + fx=' + $script:FxOk))
    }
}
