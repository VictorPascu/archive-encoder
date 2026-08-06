<#
  Minimal WPF front-end for the drop-folder workflow. Launcher + viewer ONLY:
    - shows what is in sources/important and sources/regular, with encode status
    - "+" copies videos IN (never moves; staged as .copying then renamed, so a
      half-copied file can never be seen by the list or the encoder)
    - "Run Encode" launches run_encode.ps1 in its own console window -- the UI
      never owns the encode process, so closing the window costs nothing
    - double-click a row: plays the ENCODED version when it exists, else the
      source; right-click for explicit Play Source / Play Encoded / Explorer

  Design rule: this file contains no encoding logic and no deletion of anything.

  -SelfTest runs the headless checks (row building, play-target resolution,
  staged copy, XAML loads, controls resolve) against a temp scaffold and exits.
#>

[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is EMPTY inside param defaults when launched via `powershell
# -File` (the LaunchUI.bat path) -- resolve after binding instead.
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:VideoExt = @('.mp4','.mov','.m4v','.mkv','.avi','.webm','.3gp','.mts','.m2ts','.wmv')

# WPF binds to real .NET properties; PSCustomObject note-properties bind as
# nothing (silently blank rows) -- hence a native PS class.
class VideoRow {
  [string]$Name
  [string]$RelPath
  [string]$SrcPath
  [string]$EncPath
  [string]$SrcMB
  [string]$EncMB
  [string]$Status
  [bool]$HasEncoded
}

function Get-TierRows {
  param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Tier)
  $srcRoot = Join-Path $Root "sources\$Tier"
  $encRoot = Join-Path $Root "encoded_outputs\$Tier"
  $rows = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $srcRoot)) { return $rows }
  foreach ($f in (Get-ChildItem -LiteralPath $srcRoot -File -Recurse |
                  Where-Object { $script:VideoExt -contains $_.Extension.ToLower() } |
                  Sort-Object FullName)) {
    $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\')
    $enc = Join-Path $encRoot $rel
    $hasEnc = Test-Path -LiteralPath $enc
    $r = [VideoRow]::new()
    $r.Name = $rel
    $r.RelPath = $rel
    $r.SrcPath = $f.FullName
    $r.EncPath = $enc
    $r.SrcMB = '{0:N1}' -f ($f.Length / 1MB)
    $r.EncMB = if ($hasEnc) { '{0:N1}' -f ((Get-Item -LiteralPath $enc).Length / 1MB) } else { '' }
    $r.Status = if ($hasEnc) { [char]0x2713 + ' encoded' } else { 'pending' }
    $r.HasEncoded = $hasEnc
    $rows.Add($r)
  }
  return $rows
}

function Resolve-PlayTarget {
  <# Double-click semantics: the encoded file when it exists, else the source. #>
  param([Parameter(Mandatory)]$Row)
  if ($Row.HasEncoded) { return $Row.EncPath }
  return $Row.SrcPath
}

function Copy-VideosIntoTier {
  <# Staged copy: <name>.copying -> rename. Never overwrites; returns a result
     per file. Synchronous core -- the UI wraps it in a spawned console for big
     files, the self-test calls it directly. #>
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Tier,
    [Parameter(Mandatory)][string[]]$Files
  )
  $dest = Join-Path $Root "sources\$Tier"
  if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
  $results = @()
  foreach ($src in $Files) {
    $name  = [IO.Path]::GetFileName($src)
    $final = Join-Path $dest $name
    if (Test-Path -LiteralPath $final) {
      $results += [pscustomobject]@{ Name=$name; Result='SKIPPED (already exists -- never overwritten)' }
      continue
    }
    $tmp = "$final.copying"
    try {
      Copy-Item -LiteralPath $src -Destination $tmp -Force
      Move-Item -LiteralPath $tmp -Destination $final
      $results += [pscustomobject]@{ Name=$name; Result='copied' }
    } catch {
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
      $results += [pscustomobject]@{ Name=$name; Result="FAILED: $($_.Exception.Message)" }
    }
  }
  return $results
}

# ============================================================== XAML
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Video Encoding" Width="980" Height="620" WindowStartupLocation="CenterScreen">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="10"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <GroupBox Grid.Column="0" Header=" Important  -  x265 archival quality (slow) ">
        <DockPanel Margin="4">
          <Button x:Name="AddImportant" DockPanel.Dock="Bottom" Margin="0,6,0,0" Padding="6,4"
                  Content="+  Add videos (copies, never moves)"/>
          <ListView x:Name="ListImportant">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Video" Width="230" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Src MB" Width="70" DisplayMemberBinding="{Binding SrcMB}"/>
                <GridViewColumn Header="Enc MB" Width="70" DisplayMemberBinding="{Binding EncMB}"/>
                <GridViewColumn Header="Status" Width="80" DisplayMemberBinding="{Binding Status}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>
      </GroupBox>

      <GroupBox Grid.Column="2" Header=" Regular  -  NVENC fast (~5x) ">
        <DockPanel Margin="4">
          <Button x:Name="AddRegular" DockPanel.Dock="Bottom" Margin="0,6,0,0" Padding="6,4"
                  Content="+  Add videos (copies, never moves)"/>
          <ListView x:Name="ListRegular">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="Video" Width="230" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Src MB" Width="70" DisplayMemberBinding="{Binding SrcMB}"/>
                <GridViewColumn Header="Enc MB" Width="70" DisplayMemberBinding="{Binding EncMB}"/>
                <GridViewColumn Header="Status" Width="80" DisplayMemberBinding="{Binding Status}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>
      </GroupBox>
    </Grid>

    <DockPanel Grid.Row="1" Margin="0,8,0,0">
      <Button x:Name="RunEncode" DockPanel.Dock="Right" Padding="14,6" FontWeight="Bold"
              Content="Run Encode"/>
      <Button x:Name="RefreshBtn" DockPanel.Dock="Right" Padding="10,6" Margin="0,0,8,0" Content="Refresh"/>
      <TextBlock x:Name="StatusText" VerticalAlignment="Center" Foreground="Gray"
                 Text="Double-click: plays encoded when available, else source. Right-click for more."/>
    </DockPanel>
  </Grid>
</Window>
'@

function New-MainWindow {
  $reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlText)
  return [Windows.Markup.XamlReader]::Load($reader)
}

# ============================================================== self-test
if ($SelfTest) {
  $pass = 0; $fail = 0
  function Check { param([string]$N, [bool]$Ok, [string]$D = '')
    if ($Ok) { $script:pass++; Write-Host "  PASS  $N  $D" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $N  $D" -ForegroundColor Red } }

  $tmp = Join-Path $env:TEMP ("ui_selftest_" + [guid]::NewGuid().ToString('N').Substring(0,8))
  try {
    New-Item -ItemType Directory -Path (Join-Path $tmp 'sources\important') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmp 'sources\regular\sub') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmp 'encoded_outputs\important') -Force | Out-Null
    'x' | Set-Content (Join-Path $tmp 'sources\important\a.mp4')
    'x' | Set-Content (Join-Path $tmp 'sources\regular\sub\b.mp4')
    'y' | Set-Content (Join-Path $tmp 'encoded_outputs\important\a.mp4')
    'n' | Set-Content (Join-Path $tmp 'sources\important\notes.txt')   # must be ignored

    $imp = Get-TierRows -Root $tmp -Tier 'important'
    $reg = Get-TierRows -Root $tmp -Tier 'regular'
    Check 'important tier: 1 video row (txt ignored)' ($imp.Count -eq 1)
    Check 'important row marked encoded' ($imp[0].HasEncoded -and $imp[0].Status -like '*encoded*')
    Check 'regular tier: nested row found' ($reg.Count -eq 1 -and $reg[0].RelPath -eq 'sub\b.mp4')
    Check 'regular row pending' (-not $reg[0].HasEncoded)

    Check 'play target: encoded when present' ((Resolve-PlayTarget $imp[0]) -eq $imp[0].EncPath)
    Check 'play target: source when pending' ((Resolve-PlayTarget $reg[0]) -eq $reg[0].SrcPath)

    $ext = Join-Path $tmp 'external.mp4'; 'v' | Set-Content $ext
    $r1 = Copy-VideosIntoTier -Root $tmp -Tier 'regular' -Files @($ext)
    Check 'copy-in lands the file' ($r1[0].Result -eq 'copied' -and (Test-Path (Join-Path $tmp 'sources\regular\external.mp4')))
    Check 'no .copying residue' (-not (Test-Path (Join-Path $tmp 'sources\regular\external.mp4.copying')))
    Check 'original external file untouched' (Test-Path $ext)
    $r2 = Copy-VideosIntoTier -Root $tmp -Tier 'regular' -Files @($ext)
    Check 'collision skipped, never overwritten' ($r2[0].Result -like 'SKIPPED*')

    $w = New-MainWindow
    Check 'XAML loads' ($null -ne $w)
    $ok = $true
    foreach ($n in @('ListImportant','ListRegular','AddImportant','AddRegular','RunEncode','RefreshBtn','StatusText')) {
      if ($null -eq $w.FindName($n)) { $ok = $false }
    }
    Check 'all named controls resolve' $ok
    # NB: @() wrap is load-bearing -- PowerShell unrolls a 1-element list into a
    # bare VideoRow on return, which WPF rejects as non-enumerable. The live
    # Update-Lists uses the same @() pattern; this asserts it.
    $lv = $w.FindName('ListImportant'); $lv.ItemsSource = @($imp)
    Check 'ItemsSource accepts VideoRow list' ($lv.Items.Count -eq 1)
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  Write-Host ""
  Write-Host "UI SELF-TEST  Passed: $pass  Failed: $fail" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
  if ($fail) { exit 1 } else { exit 0 }
}

# ============================================================== live UI
$window = New-MainWindow
$listImp    = $window.FindName('ListImportant')
$listReg    = $window.FindName('ListRegular')
$btnAddImp  = $window.FindName('AddImportant')
$btnAddReg  = $window.FindName('AddRegular')
$btnRun     = $window.FindName('RunEncode')
$btnRefresh = $window.FindName('RefreshBtn')
$statusText = $window.FindName('StatusText')

$script:EncodeProc = $null

function Update-Lists {
  $listImp.ItemsSource = @(Get-TierRows -Root $RepoRoot -Tier 'important')
  $listReg.ItemsSource = @(Get-TierRows -Root $RepoRoot -Tier 'regular')
  $running = ($script:EncodeProc -and -not $script:EncodeProc.HasExited)
  $btnRun.IsEnabled = -not $running
  $btnRun.Content = if ($running) { 'Encoding... (see console)' } else { 'Run Encode' }
  $nImp = @($listImp.ItemsSource).Count; $nReg = @($listReg.ItemsSource).Count
  $pend = @(@($listImp.ItemsSource) + @($listReg.ItemsSource) | Where-Object { -not $_.HasEncoded }).Count
  $statusText.Text = "important: $nImp   regular: $nReg   pending: $pend   |   double-click plays encoded when available, else source"
}

function Add-VideosViaDialog {
  param([string]$Tier)
  $dlg = New-Object Microsoft.Win32.OpenFileDialog
  $dlg.Multiselect = $true
  $dlg.Title = "Add videos to sources\$Tier (files are COPIED, originals untouched)"
  $dlg.Filter = 'Videos|*' + ($script:VideoExt -join ';*') + '|All files|*.*'
  if (-not $dlg.ShowDialog()) { return }
  $files = @($dlg.FileNames)
  # big copies must not freeze the window: spawn a visible console that stages
  # each file as .copying then renames; the refresh timer picks results up
  $quoted = @($files | ForEach-Object { '"{0}"' -f $_ })
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',
               ('"{0}"' -f (Join-Path $PSScriptRoot 'scripts_internal\copy_in.ps1')),
               '-RepoRoot', ('"{0}"' -f $RepoRoot), '-Tier', $Tier) + $quoted
  Start-Process -FilePath 'powershell.exe' -ArgumentList $argList | Out-Null
  $statusText.Text = "Copying $($files.Count) file(s) into sources\$Tier in the console window..."
}

$btnAddImp.add_Click({ Add-VideosViaDialog -Tier 'important' })
$btnAddReg.add_Click({ Add-VideosViaDialog -Tier 'regular' })
$btnRefresh.add_Click({ Update-Lists })

$btnRun.add_Click({
  if ($script:EncodeProc -and -not $script:EncodeProc.HasExited) { return }
  $script:EncodeProc = Start-Process -FilePath 'powershell.exe' -PassThru -ArgumentList @(
    '-NoExit','-NoProfile','-ExecutionPolicy','Bypass',
    '-File', ('"{0}"' -f (Join-Path $PSScriptRoot 'run_encode.ps1')),
    '-RepoRoot', ('"{0}"' -f $RepoRoot))
  Update-Lists
})

$openRow = {
  param($sender, $e)
  $row = $sender.SelectedItem
  if ($null -eq $row) { return }
  $t = Resolve-PlayTarget $row
  if (Test-Path -LiteralPath $t) { Start-Process -FilePath $t }
}
$listImp.add_MouseDoubleClick($openRow)
$listReg.add_MouseDoubleClick($openRow)

# right-click: explicit choices
foreach ($lv in @($listImp, $listReg)) {
  $menu = New-Object System.Windows.Controls.ContextMenu
  foreach ($def in @(
      @{ H='Play source';        A={ param($r) if (Test-Path -LiteralPath $r.SrcPath) { Start-Process -FilePath $r.SrcPath } } },
      @{ H='Play encoded';       A={ param($r) if ($r.HasEncoded) { Start-Process -FilePath $r.EncPath } } },
      @{ H='Show source in Explorer'; A={ param($r) Start-Process explorer.exe ('/select,"{0}"' -f $r.SrcPath) } }
    )) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $def.H
    $action = $def.A
    $owner = $lv
    $mi.add_Click({ if ($owner.SelectedItem) { & $action $owner.SelectedItem } }.GetNewClosure())
    $menu.Items.Add($mi) | Out-Null
  }
  $lv.ContextMenu = $menu
}

# periodic refresh: picks up finished copies and encode progress
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(5)
$timer.add_Tick({ Update-Lists })
$timer.Start()

Update-Lists
$null = $window.ShowDialog()
$timer.Stop()
