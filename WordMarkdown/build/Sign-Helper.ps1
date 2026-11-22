<#
  Clicks through Word's VBA "Digital Signature" dialogs so that the VBA project
  currently selected in the VBA editor gets signed.  Started (as a separate
  process) by Build-WordMarkdown.ps1 just before it opens Tools > Digital
  Signature in the VBA editor.  Exit code 0 = signed, 2 = gave up.

  Flow it drives:
    1. "Digital Signature" dialog (Office's own, owner-drawn: no UI Automation
       children)  -> mouse click on "Choose..."
    2. "Windows Security - Select a certificate" (XAML, UI Automation works)
       -> Invoke OK when it shows the wanted certificate
    3. back in "Digital Signature"  -> mouse click on "OK"
  Everything it sees is appended to the log file.
#>
param(
    [Parameter(Mandatory)][int]$WordPid,
    [Parameter(Mandatory)][string]$CertMatch,
    [Parameter(Mandatory)][string]$Log
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class SignNative {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc c, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
  public static string Describe(uint pid) {
    var sb = new StringBuilder();
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var c = new StringBuilder(256); var t = new StringBuilder(256);
      GetClassName(h, c, 256); GetWindowText(h, t, 256);
      sb.Append(" {" + c + " '" + t + "' en=" + IsWindowEnabled(h) + "}");
      return true; }, IntPtr.Zero);
    return sb.ToString();
  }
  public static long FindByClass(uint pid, string cls) {
    long found = 0;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (c.ToString() == cls) { found = h.ToInt64(); return false; }
      return true; }, IntPtr.Zero);
    return found;
  }
  public static void Click(IntPtr h, double fx, double fy) {
    RECT r; GetWindowRect(h, out r);
    SetForegroundWindow(h); System.Threading.Thread.Sleep(300);
    SetCursorPos((int)(r.L + fx * (r.R - r.L)), (int)(r.T + fy * (r.B - r.T)));
    System.Threading.Thread.Sleep(250);
    mouse_event(2, 0, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(80); mouse_event(4, 0, 0, 0, UIntPtr.Zero);
  }
}
'@
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

function L($m) { Add-Content -LiteralPath $Log -Value ('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m) }
function Dump($el, $depth) {
    if ($depth -gt 8) { return }
    $c = $el.Current
    L (('  ' * $depth) + ('[{0}] "{1}" class={2} id={3}' -f $c.ControlType.ProgrammaticName, $c.Name, $c.ClassName, $c.AutomationId))
    foreach ($k in $el.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)) { Dump $k ($depth + 1) }
}
function Get-SigDialog {
    $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $WordPid)
    foreach ($w in $AE::RootElement.FindAll($TS::Children, $cond)) {
        if ($w.Current.Name -eq 'Digital Signature') { return $w }
    }
    return $null
}

$deadline = (Get-Date).AddSeconds(100)
$stage = 0            # 0 start, 1 Choose clicked, 2 certificate confirmed, 3 OK clicked
$stageAt = Get-Date
$okClicks = 0
$loggedWinSec = $false
L "helper started: word pid $WordPid, certificate '$CertMatch'"
$lastStatus = [datetime]::MinValue
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    try {
        if (((Get-Date) - $lastStatus).TotalSeconds -ge 8) {
            $lastStatus = Get-Date
            L ('status stage=' + $stage + ' windows:' + [SignNative]::Describe([uint32]$WordPid))
        }
        # Windows Security "Select a certificate" (class below; UI Automation can read it)
        $h = [SignNative]::FindByClass([uint32]$WordPid, 'Credential Dialog Xaml Host')
        if ($h -ne 0) {
            $el = $AE::FromHandle([IntPtr]$h)
            if (-not $loggedWinSec) { $loggedWinSec = $true; L 'Windows Security dialog:'; Dump $el 1 }
            $texts = ($el.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text))) |
                      ForEach-Object { $_.Current.Name }) -join ' | '
            if ($texts -match [regex]::Escape($CertMatch)) {
                $ok = $el.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'OkButton')))
                if ($ok) {
                    L 'certificate shown; invoking OK'
                    $ok.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                    $stage = 2; $stageAt = Get-Date
                    Start-Sleep -Milliseconds 1200
                }
            } else {
                L "Windows Security shows a different certificate ($texts); trying 'More choices'"
                $more = $el.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'ChooseAnotherOption')))
                if ($more) { try { $more.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { L "more choices failed: $_" } }
                Start-Sleep -Milliseconds 1500
            }
            continue
        }

        # (plain Win32 lookup: UI Automation does not see this owner-drawn dialog reliably)
        $sigH = [SignNative]::FindByClass([uint32]$WordPid, 'bosa_sdm_msword')
        $sig = if ($sigH -ne 0) { $sigH } else { $null }
        if (-not $sig) {
            if ($stage -eq 3) { L 'Digital Signature dialog closed: signed'; exit 0 }
            continue
        }
        $wh = [IntPtr]$sigH
        if (-not [SignNative]::IsWindowEnabled($wh)) { continue }       # a child dialog is open
        $age = ((Get-Date) - $stageAt).TotalSeconds

        if ($stage -eq 0) {
            L 'Digital Signature dialog open; clicking Choose...'
            [SignNative]::Click($wh, 0.803, 0.703); $stage = 1; $stageAt = Get-Date
        }
        elseif ($stage -eq 2 -or ($stage -eq 1 -and $age -gt 8)) {
            if ($stage -eq 1) { L 'no certificate prompt appeared; assuming the certificate is already selected' }
            L 'clicking OK'
            [SignNative]::Click($wh, 0.55, 0.887); $stage = 3; $stageAt = Get-Date; $okClicks++
        }
        elseif ($stage -eq 3 -and $age -gt 4 -and $okClicks -lt 3) {
            L 'dialog still open; clicking OK again'
            [SignNative]::Click($wh, 0.55, 0.887); $stageAt = Get-Date; $okClicks++
        }
    } catch { L "helper error: $_" }
}
L "helper gave up (stage $stage)"
exit 2
