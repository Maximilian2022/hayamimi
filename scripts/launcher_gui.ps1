$version = "GUI v1.0.4"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- コンソール & Windows Terminal の完全非表示化 (SW_HIDE) ---
try {
    $win32Def = @"
using System;
using System.Runtime.InteropServices;
public class LauncherConsoleHelper {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    Add-Type -TypeDefinition $win32Def -ErrorAction SilentlyContinue

    $cWnd = [LauncherConsoleHelper]::GetConsoleWindow()
    if ($cWnd -ne [IntPtr]::Zero) {
        [LauncherConsoleHelper]::ShowWindow($cWnd, 0)
    }

    $curPid = $PID
    for ($i = 0; $i -lt 5; $i++) {
        $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId = $curPid" -ErrorAction SilentlyContinue).ParentProcessId
        if (-not $parentPid) { break }
        $parentProc = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
        if ($parentProc) {
            if ($parentProc.ProcessName -match "WindowsTerminal|wt|cmd|conhost") {
                if ($parentProc.MainWindowHandle -ne [IntPtr]::Zero) {
                    [LauncherConsoleHelper]::ShowWindow($parentProc.MainWindowHandle, 0)
                }
            }
        }
        $curPid = $parentPid
    }
} catch {}

<#
.SYNOPSIS
    hayamimi (早耳) - WSL Containers (WSL3) ランチャー GUI
.DESCRIPTION
    WPFを用いたモダンなダークUIランチャー。
    WSL Containers (wslc) を制御して hayamimi コンテナを起動・停止し、
    コンテナログ同期、起動完了後のブラウザ自動表示を行います。
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

# --- WPF ハードウェアアクセラレーション起因の Win32 メッセージクォータ溢れ (エラー 1816) を完全防止 ---
[System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# 1. パスの動的解決 (他環境での実行に対応)
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir -and $MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $ScriptDir) {
    $ScriptDir = (Get-Location).Path
}
$ProjectRoot = Split-Path -Parent $ScriptDir

# logs フォルダの自動作成
$LogsDir = Join-Path $ProjectRoot "logs"
if (-not (Test-Path $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}
$LogFile = Join-Path $LogsDir "launcher.log"
$ContainerLogFile = Join-Path $LogsDir "container.log"

# 過去のバグで発生した二重ネストフォルダ (scripts/scripts, docs/docs 等) の自動修復
try {
    $nestedCandidateDirs = @("scripts", "docs", "tests", "demo", "mobile", "nginx", ".github")
    foreach ($cand in $nestedCandidateDirs) {
        $pDir = Join-Path $ProjectRoot $cand
        $nDir = Join-Path $pDir $cand
        if ((Test-Path $pDir) -and (Test-Path $nDir) -and (Get-Item $nDir).PSIsContainer) {
            $childItems = Get-ChildItem -Path $nDir
            foreach ($ci in $childItems) {
                $targetCiPath = Join-Path $pDir $ci.Name
                if (-not (Test-Path $targetCiPath)) {
                    Move-Item -Path $ci.FullName -Destination $targetCiPath -Force
                }
            }
            Remove-Item -Path $nDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

$ContainerName = "hayamimi_app"
$ImageName = "hayamimi:latest"
$MicUrl = "http://localhost:8833/mic"
$ObsUrl = "http://localhost:8833/"
$DashboardUrl = "http://localhost:8833/dashboard"

# ランチャー用ロギング関数 (単一メッセージ)
function Write-AppLog {
    param([string]$Message, [string]$Level = "INFO")
    $now = Get-Date
    $timestamp = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $timeOnly = $now.ToString("HH:mm:ss")
    $logLine = "[$timestamp] [$Level] $Message"

    try {
        [System.IO.File]::AppendAllText($LogFile, "$logLine`r`n", [System.Text.Encoding]::UTF8)
    } catch {}

    if ($logTextBox -and $logScrollViewer) {
        $logTextBox.AppendText("[$timeOnly] $Message`r`n")
        $logScrollViewer.ScrollToEnd()
    }
}

# ランチャー用ロギング関数 (複数行バッチ・メッセージキュー溢れ防止)
function Write-AppLogBatch {
    param([System.Collections.IEnumerable]$Messages, [string]$Level = "INFO")
    if (-not $Messages) { return }
    $now = Get-Date
    $timestamp = $now.ToString("yyyy-MM-dd HH:mm:ss")
    $timeOnly = $now.ToString("HH:mm:ss")

    $fileSb = [System.Text.StringBuilder]::new()
    $guiSb = [System.Text.StringBuilder]::new()
    $count = 0

    foreach ($msg in $Messages) {
        if (-not $msg) { continue }
        [void]$fileSb.AppendLine("[$timestamp] [$Level] $msg")
        [void]$guiSb.AppendLine("[$timeOnly] $msg")
        $count++
    }
    if ($count -eq 0) { return }

    try {
        [System.IO.File]::AppendAllText($LogFile, $fileSb.ToString(), [System.Text.Encoding]::UTF8)
    } catch {}

    if ($logTextBox -and $logScrollViewer) {
        $logTextBox.AppendText($guiSb.ToString())
        $logScrollViewer.ScrollToEnd()
    }
}

$script:LastContainerLogLineCount = 0

# WSL Containers (wslc.exe) パス解決関数 (PATH未登録環境や Program Files 直下も自動検出)
function Get-WslcCommand {
    try {
        $cmd = Get-Command "wslc" -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        $whereCmd = where.exe wslc 2>$null
        if ($whereCmd) { return ($whereCmd -split "`r?`n")[0].Trim() }
    } catch {}

    $knownPaths = @(
        "C:\Program Files\WSL\wslc.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\wslc.exe",
        "C:\Windows\System32\wslc.exe"
    )
    foreach ($p in $knownPaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$script:WslcCmd = Get-WslcCommand

# コンテナログ更新関数 (logs/container.log に同期出力し、GUIにも新着行を反映)
function Update-ContainerLogFile {
    param([bool]$EchoToGui = $true)
    if (-not $script:WslcCmd) { return }
    try {
        $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfo.FileName = $script:WslcCmd
        $pinfo.Arguments = "logs $ContainerName"
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $rawLogs = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit(1500) | Out-Null

        if ($rawLogs) {
            $lines = $rawLogs -split "[\r\n]+"
            $validLines = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $lines) {
                $lStr = "$line"
                if ($lStr.Trim() -and $lStr -notmatch "Error: No such container" -and $lStr -notmatch "failed to find container" -and $lStr -notmatch "Error response from daemon") {
                    $validLines.Add($lStr.Trim())
                }
            }
            if ($validLines.Count -gt 0) {
                $text = ($validLines -join "`r`n") + "`r`n"
                [System.IO.File]::WriteAllText($ContainerLogFile, $text, [System.Text.Encoding]::UTF8)

                if ($EchoToGui -and $logTextBox) {
                    if ($validLines.Count -gt $script:LastContainerLogLineCount) {
                        for ($i = $script:LastContainerLogLineCount; $i -lt $validLines.Count; $i++) {
                            $item = $validLines[$i]
                            if ($item.Trim()) {
                                Write-AppLog "[コンテナ] $item" "CONTAINER"
                            }
                        }
                        $script:LastContainerLogLineCount = $validLines.Count
                    }
                }
            }
        }
    } catch {}
}

# XAML 定義
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="hayamimi - WSL3 ランチャー (GUI v1.0.2)"
        Height="610" Width="660"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanMinimize"
        Background="#0E1117"
        Foreground="#ECE5D8">
    <Window.Resources>
        <FontFamily x:Key="MainFont">Yu Gothic UI, Segoe UI, Meiryo UI, sans-serif</FontFamily>
        <FontFamily x:Key="MonoFont">Consolas, 'Cascadia Code', monospace</FontFamily>
        
        <Style TargetType="Button">
            <Setter Property="FontFamily" Value="{StaticResource MainFont}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="16,10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="8"
                                Padding="{TemplateBinding Padding}"
                                SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.88"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Opacity" Value="0.75"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Opacity" Value="0.35"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- ヘッダー -->
        <Border Grid.Row="0" Margin="0,0,0,14" Padding="0,0,0,10" BorderBrush="#252A36" BorderThickness="0,0,0,1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Vertical">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="hayamimi" FontSize="26" FontWeight="Bold" Foreground="#ECE5D8" FontFamily="{StaticResource MainFont}"/>
                        <TextBlock Text=" (早耳)" FontSize="22" FontWeight="Bold" Foreground="#E04F2F" FontFamily="{StaticResource MainFont}" Margin="6,2,0,0"/>
                    </StackPanel>
                    <TextBlock Text="WSL Containers (WSL 3.0) リアルタイム音声認識 &amp; 多言語同時翻訳" 
                               FontSize="12" Foreground="#8C93A0" Margin="2,4,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="#242C3D" CornerRadius="12" Padding="10,4" Margin="0,0,8,0" BorderBrush="#3A465D" BorderThickness="1">
                        <TextBlock x:Name="VersionBadge" Text="GUI v1.0.4" FontSize="11" Foreground="#F6AD55" FontWeight="Bold" FontFamily="{StaticResource MonoFont}"/>
                    </Border>
                    <Border Background="#1A202C" CornerRadius="12" Padding="10,4">
                        <TextBlock x:Name="RuntimeBadge" Text="WSL3 Native" FontSize="11" Foreground="#4FD1C5" FontWeight="SemiBold"/>
                    </Border>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ステータスカード -->
        <Border Grid.Row="1" Background="#161B26" CornerRadius="10" Padding="16,12" Margin="0,0,0,12" BorderBrush="#262D3D" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    
                    <Ellipse x:Name="StatusLed" Grid.Column="0" Width="14" Height="14" Fill="#718096" Margin="0,0,12,0" VerticalAlignment="Center"/>
                    
                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                        <TextBlock Text="コンテナ状態" FontSize="11" Foreground="#718096"/>
                        <TextBlock x:Name="StatusText" Text="停止中" FontSize="15" FontWeight="Bold" Foreground="#ECE5D8" Margin="0,2,0,0"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Background="#1F2636" CornerRadius="6" Padding="8,4" Margin="4,0">
                            <TextBlock Text="HTTP: 8833" FontSize="11" Foreground="#A0AEC0" FontFamily="{StaticResource MonoFont}"/>
                        </Border>
                        <Border Background="#1F2636" CornerRadius="6" Padding="8,4">
                            <TextBlock Text="WS: 8766" FontSize="11" Foreground="#A0AEC0" FontFamily="{StaticResource MonoFont}"/>
                        </Border>
                    </StackPanel>
                </Grid>

                <!-- WSL Containers / 仮想化 (Hypervisor) 診断・アシストバナー -->
                <Border x:Name="WslcAlertBanner" Grid.Row="1" Margin="0,8,0,0" Padding="10,8" Background="#2A1B18" BorderBrush="#E74C3C" BorderThickness="1" CornerRadius="6" Visibility="Collapsed">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" VerticalAlignment="Center">
                            <TextBlock x:Name="WslcAlertTitle" Text="⚠ WSL 3.0 / 仮想化基盤が無効です" FontSize="12" FontWeight="Bold" Foreground="#FF7A6B"/>
                            <TextBlock x:Name="WslcAlertDesc" Text="hayamimi の実行に必要な仮想化機能と WSL 3.0 を自動セットアップできます。" FontSize="11" Foreground="#CBD5E0" Margin="0,2,0,0" TextWrapping="Wrap"/>
                        </StackPanel>
                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="8,0,0,0">
                            <Button x:Name="BtnBiosGuide" Content="📖 BIOS 設定ガイド" Background="#3A465D" Foreground="#ECE5D8" FontSize="11" FontWeight="SemiBold" Padding="10,6" Margin="0,0,6,0" Visibility="Collapsed"/>
                            <Button x:Name="BtnUpdateWsl" Content="📥 仮想化 &amp; WSL3 自動設定" Background="#2ECC71" Foreground="#0E1117" FontSize="11" FontWeight="Bold" Padding="12,6"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <Border Grid.Row="2" Margin="0,8,0,0" Padding="8,6" Background="#11151F" CornerRadius="6">
                    <TextBlock Text="🌐 リアルタイム翻訳 (英語・中国語・台湾語・香港語など) は Webのマイク画面 (/mic) で自由に設定可能です。" 
                               FontSize="11" Foreground="#8C93A0"/>
                </Border>
            </Grid>
        </Border>

        <!-- 操作ボタンエリア -->
        <Grid Grid.Row="2" Margin="0,0,0,12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="8"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="14"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- 起動ボタン -->
            <Button x:Name="BtnStart" Grid.Row="0" Grid.Column="0" Background="#2ECC71" Foreground="#0E1117" Height="46">
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="▶" FontSize="15" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="コンテナ起動 &amp; Webを開く" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
                </StackPanel>
            </Button>

            <!-- 終了ボタン -->
            <Button x:Name="BtnStop" Grid.Row="0" Grid.Column="2" Background="#E74C3C" Foreground="#FFFFFF" Height="46" IsEnabled="False">
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="■" FontSize="14" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="コンテナ終了 &amp; 閉じる" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
                </StackPanel>
            </Button>

            <!-- アップデート・リビルドエリア -->
            <Grid Grid.Row="2" Grid.ColumnSpan="3">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="8"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="※ GitHubの最新コード取得とコンテナ更新を行えます。" FontSize="11" Foreground="#718096" VerticalAlignment="Center"/>
                <Button x:Name="BtnUpdateApp" Grid.Column="1" Background="#1A202C" Foreground="#4FD1C5" Height="28" Padding="10,4" FontSize="11" ToolTip="GitHubから最新のソースコードを取得します">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="📥" FontSize="11" Margin="0,0,5,0" VerticalAlignment="Center"/>
                        <TextBlock Text="本体を最新版に更新" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </StackPanel>
                </Button>
                <Button x:Name="BtnRebuild" Grid.Column="3" Background="#1A202C" Foreground="#A0AEC0" Height="28" Padding="10,4" FontSize="11" ToolTip="最新のソースコードをコンテナイメージに再反映します">
                    <StackPanel Orientation="Horizontal">
                        <TextBlock Text="🔄" FontSize="11" Margin="0,0,5,0" VerticalAlignment="Center"/>
                        <TextBlock Text="コンテナをリビルド" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
                    </StackPanel>
                </Button>
            </Grid>
        </Grid>

        <!-- クイックリンクエリア -->
        <Border Grid.Row="3" Background="#141822" CornerRadius="8" Padding="12,8" Margin="0,0,0,12" BorderBrush="#202634" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Web画面:" FontSize="12" Foreground="#718096" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Button x:Name="BtnOpenMic" Background="Transparent" Foreground="#63B3ED" Padding="8,4" FontSize="12" Margin="0,0,8,0">
                        <TextBlock Text="🎤 マイク入力 (/mic)" TextDecorations="Underline"/>
                    </Button>
                    <Button x:Name="BtnOpenObs" Background="Transparent" Foreground="#63B3ED" Padding="8,4" FontSize="12" Margin="0,0,8,0">
                        <TextBlock Text="📺 OBS字幕 (/)" TextDecorations="Underline"/>
                    </Button>
                    <Button x:Name="BtnOpenDashboard" Background="Transparent" Foreground="#63B3ED" Padding="8,4" FontSize="12">
                        <TextBlock Text="📊 ダッシュボード (/dashboard)" TextDecorations="Underline"/>
                    </Button>
                </StackPanel>
            </Grid>
        </Border>

        <!-- ログコンソール -->
        <Border Grid.Row="4" Background="#090B0E" CornerRadius="8" BorderBrush="#1C222E" BorderThickness="1">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Background="#11151C" Padding="10,6" CornerRadius="8,8,0,0" BorderBrush="#1C222E" BorderThickness="0,0,0,1">
                    <Grid>
                        <TextBlock Text="実行ログ (logs/launcher.log &amp; logs/container.log)" FontSize="11" Foreground="#718096" FontFamily="{StaticResource MonoFont}" VerticalAlignment="Center"/>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button x:Name="BtnOpenContainerLog" Background="Transparent" Foreground="#63B3ED" Padding="4,0" Margin="0,0,6,0" FontSize="11">
                                <TextBlock Text="📄 container.log"/>
                            </Button>
                            <Button x:Name="BtnOpenLauncherLog" Background="Transparent" Foreground="#63B3ED" Padding="4,0" Margin="0,0,6,0" FontSize="11">
                                <TextBlock Text="📄 launcher.log"/>
                            </Button>
                            <Button x:Name="BtnOpenLogsDir" Background="Transparent" Foreground="#63B3ED" Padding="4,0" Margin="0,0,6,0" FontSize="11">
                                <TextBlock Text="📁 logsフォルダ"/>
                            </Button>
                            <Button x:Name="BtnClearLog" Background="Transparent" Foreground="#718096" Padding="4,0" FontSize="11">
                                <TextBlock Text="クリア"/>
                            </Button>
                        </StackPanel>
                    </Grid>
                </Border>
                <ScrollViewer Grid.Row="1" x:Name="LogScrollViewer" VerticalScrollBarVisibility="Auto" Margin="8">
                    <TextBox x:Name="LogTextBox"
                             Background="Transparent"
                             Foreground="#A0AEC0"
                             BorderThickness="0"
                             IsReadOnly="True"
                             TextWrapping="Wrap"
                             FontFamily="{StaticResource MonoFont}"
                             FontSize="11"
                             CaretBrush="Transparent"/>
                </ScrollViewer>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# --- WPF UIスレッド未処理例外の安全捕捉 (プロセスクラッシュ完全防止) ---
$window.Dispatcher.Add_UnhandledExceptionFilter({
    param($sender, $e)
    try {
        $e.RequestCatch = $true
    } catch {}
})
$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    try {
        Write-AppLog "UIエラーが発生しましたが回復しました: $($e.Exception.Message)" "ERROR"
        $e.Handled = $true
    } catch {}
})

# コントロール取得
$statusLed = $window.FindName("StatusLed")
$statusText = $window.FindName("StatusText")
$runtimeBadge = $window.FindName("RuntimeBadge")
$versionBadge = $window.FindName("VersionBadge")
if ($versionBadge) {
    $versionBadge.Text = $version
}
$window.Title = "hayamimi - WSL3 ランチャー ($version)"
$btnStart = $window.FindName("BtnStart")
$btnStop = $window.FindName("BtnStop")
$btnUpdateApp = $window.FindName("BtnUpdateApp")
$btnRebuild = $window.FindName("BtnRebuild")
$btnOpenMic = $window.FindName("BtnOpenMic")
$btnOpenObs = $window.FindName("BtnOpenObs")
$btnOpenDashboard = $window.FindName("BtnOpenDashboard")
$logTextBox = $window.FindName("LogTextBox")
$logScrollViewer = $window.FindName("LogScrollViewer")
$btnClearLog = $window.FindName("BtnClearLog")
$btnOpenContainerLog = $window.FindName("BtnOpenContainerLog")
$btnOpenLauncherLog = $window.FindName("BtnOpenLauncherLog")
$btnOpenLogsDir = $window.FindName("BtnOpenLogsDir")
$wslcAlertBanner = $window.FindName("WslcAlertBanner")
$wslcAlertTitle = $window.FindName("WslcAlertTitle")
$wslcAlertDesc = $window.FindName("WslcAlertDesc")
$btnUpdateWsl = $window.FindName("BtnUpdateWsl")
$btnBiosGuide = $window.FindName("BtnBiosGuide")

# ランタイムバッジ
$psVer = $PSVersionTable.PSVersion.Major
if ($psVer -ge 7) {
    $runtimeBadge.Text = "PowerShell 7 (pwsh)"
} else {
    $runtimeBadge.Text = "PowerShell 5.1"
}

# ブラシ定義
$brushGray   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#718096")
$brushGreen  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2ECC71")
$brushOrange = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F39C12")
$brushRed    = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E74C3C")

function Set-UIState {
    param([string]$State, [System.Windows.Media.Brush]$Brush, [bool]$CanStart, [bool]$CanStop)
    $statusText.Text = $State
    $statusLed.Fill = $Brush
    $btnStart.IsEnabled = $CanStart
    $btnStop.IsEnabled = $CanStop
}

# 安全な確認ダイアログ表示関数 (Ownerウィンドウ明示 & 例外フォールバック)
function Show-AppConfirm {
    param(
        [string]$Message,
        [string]$Title = "確認 - hayamimi",
        [System.Windows.MessageBoxButton]$Buttons = [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Question
    )
    try {
        if ($window -and $window.IsVisible) {
            return [System.Windows.MessageBox]::Show($window, $Message, $Title, $Buttons, $Icon)
        } else {
            return [System.Windows.MessageBox]::Show($Message, $Title, $Buttons, $Icon)
        }
    } catch {
        Write-AppLog "確認ダイアログの表示をスキップし、処理を続行します: $_" "WARN"
        return [System.Windows.MessageBoxResult]::Yes
    }
}

# 仮想化・Hypervisor 状態のインテリジェント診断
function Get-VirtualizationDiagnostic {
    $diag = [PSCustomObject]@{
        HypervisorPresent = $false
        FirmwareVirtualization = $null
        CpuName = ""
        CpuVendor = "Unknown"
        IsReady = $false
        Reason = ""
    }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.HypervisorPresent) {
            $diag.HypervisorPresent = $true
            $diag.IsReady = $true
            return $diag
        }
    } catch {}

    try {
        $proc = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            $diag.CpuName = "$($proc.Name)".Trim()
            $diag.FirmwareVirtualization = $proc.VirtualizationFirmwareEnabled
            if ($proc.Manufacturer -match "Intel" -or $proc.Name -match "Intel") {
                $diag.CpuVendor = "Intel"
            } elseif ($proc.Manufacturer -match "AMD" -or $proc.Name -match "AMD|Ryzen") {
                $diag.CpuVendor = "AMD"
            }
        }
    } catch {}

    if ($diag.FirmwareVirtualization -eq $false) {
        $diag.Reason = "BiosDisabled"
    } else {
        $diag.Reason = "WindowsFeatureDisabled"
    }

    return $diag
}

# BIOS / UEFI 仮想化有効化ガイドのポップアップ表示
function Show-BiosVirtualizationGuide {
    param([object]$Diag)
    $cpuVendor = if ($Diag -and $Diag.CpuVendor) { $Diag.CpuVendor } else { "Intel" }
    
    $settingName = if ($cpuVendor -eq "AMD") {
        "「SVM Mode」または「AMD-V / SVM」"
    } else {
        "「Intel Virtualization Technology (VT-x)」または「Intel (VMX)」"
    }

    $cpuDesc = if ($Diag -and $Diag.CpuName) { $Diag.CpuName } else { "お使いの CPU" }

    $guideMsg = "【CPU ハードウェア仮想化が無効です】`r`n`r`n" +
               "hayamimi (WSL Containers) を実行するには、PC の BIOS/UEFI 設定で仮想化支援機能を有効化（Enabled）にする必要があります。`r`n`r`n" +
               "■ 検出された CPU: $cpuDesc`r`n" +
               "■ 設定対象の項目名: $settingName`r`n`r`n" +
               "【有効化の手順】`r`n" +
               "1. PC を再起動し、起動直後にメーカーロゴが表示されたら [F2]、[F12]、または [Delete] キーを連打して BIOS/UEFI 画面を開きます。`r`n" +
               "2. 詳細設定 (Advanced / CPU Configuration / Overclocking) メニューを探します。`r`n" +
               "3. $settingName を見つけ、「有効 (Enabled)」に変更します。`r`n" +
               "4. [F10] キーを押して設定を保存し、PC を通常通り再起動してください。`r`n`r`n" +
               "※ BIOS 設定完了後、この警告は自動的に解消されます。"

    Show-AppConfirm -Message $guideMsg -Title "BIOS/UEFI 仮想化設定ガイド - hayamimi" -Buttons ([System.Windows.MessageBoxButton]::OK) -Icon ([System.Windows.MessageBoxImage]::Information) | Out-Null
}

# WSL3 & 仮想化アラートバナーの状態更新関数
function Update-WslcBannerState {
    $script:WslcCmd = Get-WslcCommand
    $script:VirtDiag = Get-VirtualizationDiagnostic

    if ($script:WslcCmd -and $script:VirtDiag.IsReady) {
        if ($wslcAlertBanner) { $wslcAlertBanner.Visibility = "Collapsed" }
        return $true
    }

    if ($wslcAlertBanner) {
        $wslcAlertBanner.Visibility = "Visible"
        if (-not $script:VirtDiag.IsReady -and $script:VirtDiag.Reason -eq "BiosDisabled") {
            if ($wslcAlertTitle) { $wslcAlertTitle.Text = "⚠ CPUの仮想化支援 (BIOS: VT-x / AMD-V) が無効です" }
            if ($wslcAlertDesc) { $wslcAlertDesc.Text = "BIOS/UEFI で $($script:VirtDiag.CpuVendor) 仮想化設定を有効化してください。未設定のままではコンテナを起動できません。" }
            if ($btnBiosGuide) { $btnBiosGuide.Visibility = "Visible" }
            if ($btnUpdateWsl) { $btnUpdateWsl.Content = "📥 仮想化 & WSL3 を自動設定" }
        } elseif (-not $script:VirtDiag.IsReady -and $script:VirtDiag.Reason -eq "WindowsFeatureDisabled") {
            if ($wslcAlertTitle) { $wslcAlertTitle.Text = "⚠ Windows の仮想化基盤 (VirtualMachinePlatform) が無効です" }
            if ($wslcAlertDesc) { $wslcAlertDesc.Text = "WSL Containers の実行には Windows の仮想マシンプラットフォームが必要です。ワンクリックで自動有効化できます。" }
            if ($btnBiosGuide) { $btnBiosGuide.Visibility = "Collapsed" }
            if ($btnUpdateWsl) { $btnUpdateWsl.Content = "📥 仮想化基盤 & WSL3 を有効化" }
        } else {
            if ($wslcAlertTitle) { $wslcAlertTitle.Text = "⚠ WSL 3.0 (WSL Containers) がインストールされていません" }
            if ($wslcAlertDesc) { $wslcAlertDesc.Text = "hayamimi の実行に必要な WSL 3.0 をワンクリックで自動インストールできます。" }
            if ($btnBiosGuide) { $btnBiosGuide.Visibility = "Collapsed" }
            if ($btnUpdateWsl) { $btnUpdateWsl.Content = "📥 WSL3 を自動インストール" }
        }
    }
    return $false
}

# ファイル共有モード (ReadWrite) での安全なログ行読み取り関数 (ロック競合ゼロ)
function Read-FileSharedLines {
    param([string]$FilePath)
    $lines = @()
    if (-not (Test-Path $FilePath)) { return $lines }
    try {
        $fs = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
        $content = $sr.ReadToEnd()
        $sr.Close()
        $fs.Close()
        if ($content) {
            $lines = $content -split "`r?`n"
        }
    } catch {}
    return $lines
}

# コンテナ稼働確認関数 (wslc inspect優先 & wslc list多言語フォールバック)
function Test-ContainerRunning {
    param([string]$TargetName = $ContainerName)
    if (-not $script:WslcCmd) { return $false }
    try {
        # 1. wslc inspect による高精度な生存判定 (JSON の "Running": true を直接判定)
        $pinfoInspect = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfoInspect.FileName = $script:WslcCmd
        $pinfoInspect.Arguments = "inspect $TargetName"
        $pinfoInspect.RedirectStandardOutput = $true
        $pinfoInspect.RedirectStandardError = $true
        $pinfoInspect.UseShellExecute = $false
        $pinfoInspect.CreateNoWindow = $true
        $procInspect = [System.Diagnostics.Process]::Start($pinfoInspect)
        $inspectOut = $procInspect.StandardOutput.ReadToEnd()
        $procInspect.WaitForExit(1500) | Out-Null

        if ($inspectOut) {
            if ($inspectOut -match '"Running"\s*:\s*true' -or $inspectOut -match '"Status"\s*:\s*"running"') {
                return $true
            }
        }

        # 2. wslc list によるフォールバック判定 (多言語・状態柔軟マッチング)
        $pinfoList = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfoList.FileName = $script:WslcCmd
        $pinfoList.Arguments = "list"
        $pinfoList.RedirectStandardOutput = $true
        $pinfoList.RedirectStandardError = $true
        $pinfoList.UseShellExecute = $false
        $pinfoList.CreateNoWindow = $true
        $procList = [System.Diagnostics.Process]::Start($pinfoList)
        $listOut = $procList.StandardOutput.ReadToEnd()
        $procList.WaitForExit(1500) | Out-Null

        if ($listOut) {
            $lines = $listOut -split "[\r\n]+"
            foreach ($line in $lines) {
                if ($line -match "\b$TargetName\b" -and ($line -match "running|Up|実行中|作成済み|created")) {
                    return $true
                }
            }
        }
    } catch {}
    return $false
}

# コンテナイメージ存在確認関数
function Test-HayamimiImageExists {
    if (-not $script:WslcCmd) { return $false }
    try {
        $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfo.FileName = $script:WslcCmd
        $pinfo.Arguments = "images"
        $pinfo.RedirectStandardOutput = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $raw = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        return ($raw -match "hayamimi")
    } catch {
        return $false
    }
}

# WSL 3.0 (WSL Containers) 自動インストール関数
function Invoke-InstallWslContainers {
    try {
        Write-AppLog "WSL 3.0 / WSL Containers の自動セットアップを開始します..."
        $installScript = @'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "  hayamimi - WSL 3.0 / WSL Containers 自動セットアップ" -ForegroundColor Cyan
Write-Host "===================================================" -ForegroundColor Cyan
Write-Host ""

# 0. Windows 仮想化基盤 (VirtualMachinePlatform) & Hypervisor の有効化
$script:RebootNeeded = $false
Write-Host "[ステップ 1/5] Windows 仮想化機能 (VirtualMachinePlatform) を有効化しています..." -ForegroundColor Yellow
try {
    Write-Host "実行中: DISM (VirtualMachinePlatform & Subsystem-Linux)..."
    $pDism1 = Start-Process dism.exe -ArgumentList "/online /enable-feature /featurename:VirtualMachinePlatform /all /norestart" -Wait -PassThru -NoNewWindow
    $pDism2 = Start-Process dism.exe -ArgumentList "/online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart" -Wait -PassThru -NoNewWindow
    Start-Process bcdedit.exe -ArgumentList "/set hypervisorlaunchtype auto" -Wait -NoNewWindow

    if ($pDism1.ExitCode -eq 3010 -or $pDism2.ExitCode -eq 3010) {
        $script:RebootNeeded = $true
    }
} catch {
    Write-Host "DISM 機能有効化スキップ: $_" -ForegroundColor DarkGray
}

# 1. WSL 自体の存在確認
$hasWsl = (where.exe wsl 2>$null)
if (-not $hasWsl) {
    Write-Host ""
    Write-Host "[ステップ 2/5] Windows Subsystem for Linux (WSL) 基盤を新規インストールしています..." -ForegroundColor Yellow
    Write-Host "実行中: wsl.exe --install --no-distribution"
    wsl.exe --install --no-distribution
} else {
    Write-Host ""
    Write-Host "[ステップ 2/5] WSL 基盤は検出されました。" -ForegroundColor Green
}

# 2. WSL を最新版に更新
Write-Host ""
Write-Host "[ステップ 3/5] WSL パッケージを最新版に更新しています..." -ForegroundColor Yellow
Write-Host "実行中: wsl.exe --update"
wsl.exe --update

# 3. プレリリース (WSL 3.0 / wslc) パッケージの適用チェック
$hasWslc = (where.exe wslc 2>$null)
if (-not $hasWslc -and -not (Test-Path "C:\Program Files\WSL\wslc.exe")) {
    Write-Host ""
    Write-Host "[ステップ 4/5] WSL 3.0 (wslc) プレリリース版パッケージを取得しています..." -ForegroundColor Yellow
    Write-Host "実行中: wsl.exe --update --pre-release"
    wsl.exe --update --pre-release
}

# 4. フォールバック: GitHub 公式リリースからの直接インストール (Store 制限等の環境向け)
$hasWslc = (where.exe wslc 2>$null)
if (-not $hasWslc -and -not (Test-Path "C:\Program Files\WSL\wslc.exe")) {
    Write-Host ""
    Write-Host "[ステップ 5/5] GitHub から最新の WSL x64 インストーラーを直接取得しています..." -ForegroundColor Yellow
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $apiUrl = "https://api.github.com/repos/microsoft/WSL/releases"
        $headers = @{ "User-Agent" = "hayamimi-installer" }
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15
        
        $targetAsset = $null
        foreach ($rel in $releases) {
            $msiAsset = $rel.assets | Where-Object { $_.name -match "wsl.*x64.*\.msi" } | Select-Object -First 1
            if ($msiAsset) {
                $targetAsset = $msiAsset
                break
            }
        }

        if ($targetAsset) {
            $tempMsi = [System.IO.Path]::Combine($env:TEMP, $targetAsset.name)
            Write-Host "ダウンロード中: $($targetAsset.browser_download_url)"
            Invoke-WebRequest -Uri $targetAsset.browser_download_url -OutFile $tempMsi
            Write-Host "MSI パッケージをインストール中..."
            Start-Process msiexec.exe -ArgumentList "/i `"$tempMsi`" /quiet /norestart" -Wait
        }
    } catch {
        Write-Host "GitHub からの直接取得エラー: $_" -ForegroundColor Red
    }
}

# 5. PATH 環境変数の確認と登録
$wslDir = "C:\Program Files\WSL"
if (Test-Path (Join-Path $wslDir "wslc.exe")) {
    try {
        $curSysPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($curSysPath -notlike "*$wslDir*") {
            [Environment]::SetEnvironmentVariable("Path", "$curSysPath;$wslDir", "Machine")
            Write-Host "環境変数 PATH に '$wslDir' を追加しました。" -ForegroundColor Green
        }
    } catch {}
}

Write-Host ""
Write-Host "===================================================" -ForegroundColor Green
Write-Host "  WSL 3.0 & 仮想化基盤のセットアップが完了しました！" -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
if ($script:RebootNeeded) {
    Write-Host "【重要】仮想マシンプラットフォームを新規に有効化したため、" -ForegroundColor Yellow
    Write-Host "        仮想化機能の完全適用には PC の再起動が必要です。" -ForegroundColor Yellow
} else {
    Write-Host "※ 新規に WSL を有効化した場合は、PC の再起動が必要になる場合があります。" -ForegroundColor Cyan
}
Write-Host "このウィンドウを閉じると、ランチャーで自動認識されます。"
Write-Host ""
Read-Host "Enterキーを押して終了してください..."
'@

        $scriptBlockFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "install_wsl3.ps1")
        [System.IO.File]::WriteAllText($scriptBlockFile, $installScript, [System.Text.Encoding]::UTF8)

        $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptBlockFile`"" -PassThru
        $proc.WaitForExit()
        Remove-Item -Path $scriptBlockFile -Force -ErrorAction SilentlyContinue

        # システム環境変数 PATH のリロード (現在のプロセス)
        try {
            $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            $env:Path = "$machinePath;$userPath;C:\Program Files\WSL"
        } catch {}

        # 再検出
        $script:WslcCmd = Get-WslcCommand
        if ($script:WslcCmd) {
            Write-AppLog "✔ WSL 3.0 (WSL Containers) が正常にインストール・検出されました: $script:WslcCmd"
            if ($wslcAlertBanner) { $wslcAlertBanner.Visibility = "Collapsed" }
            $runtimeBadge.Text = "WSL3 Native"
            $runtimeBadge.Foreground = $brushGreen
            Set-UIState "停止中" $brushGray $true $false
            return $true
        } else {
            Write-AppLog "WSL更新後も wslc.exe が見つかりませんでした。PC再起動後に再度お試しください。" "WARN"
            return $false
        }
    } catch {
        Write-AppLog "管理者権限プロンプトの起動がキャンセルされたか失敗しました: $_" "WARN"
        return $false
    }
}

# コンテナ起動処理本体
function Start-HayamimiContainer {
    try {
        Set-UIState "起動中..." $brushOrange $false $false
        Write-AppLog "hayamimi コンテナの起動処理を開始します..."

        # container.log の初期化
        $script:LastContainerLogLineCount = 0
        $initHeader = "# === hayamimi コンテナ起動: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`r`n"
        try {
            [System.IO.File]::WriteAllText($ContainerLogFile, $initHeader, [System.Text.Encoding]::UTF8)
        } catch {}

        # 既存コンテナの安全な停止・削除
        try {
            $pinfoStop = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfoStop.FileName = $script:WslcCmd
            $pinfoStop.Arguments = "stop $ContainerName"
            $pinfoStop.UseShellExecute = $false
            $pinfoStop.CreateNoWindow = $true
            $procStop = [System.Diagnostics.Process]::Start($pinfoStop)
            $procStop.WaitForExit()

            $pinfoRm = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfoRm.FileName = $script:WslcCmd
            $pinfoRm.Arguments = "remove $ContainerName"
            $pinfoRm.UseShellExecute = $false
            $pinfoRm.CreateNoWindow = $true
            $procRm = [System.Diagnostics.Process]::Start($pinfoRm)
            $procRm.WaitForExit()
        } catch {}

        # models および config ディレクトリ作成 (モデルと設定の永続化)
        $modelsDir = Join-Path $ProjectRoot "models"
        if (-not (Test-Path $modelsDir)) {
            New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
            Write-AppLog "models ディレクトリを作成しました: $modelsDir"
        }
        $configDir = Join-Path $ProjectRoot "config"
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            Write-AppLog "config ディレクトリを作成しました: $configDir"
        }

        # コンテナ起動 (wslc run -d)
        Write-AppLog "wslc run を実行中 (ポート 8833, 8766)..."
        $volumeModels = "${modelsDir}:/app/models"
        $volumeConfig = "${configDir}:/app/config"

        $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfo.FileName = $script:WslcCmd
        $pinfo.Arguments = "run -d --name $ContainerName -p 8833:8833 -p 8766:8766 -v `"$volumeModels`" -v `"$volumeConfig`" $ImageName --translate en"
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        if ($proc.ExitCode -ne 0) {
            Write-AppLog "エラー: コンテナの起動に失敗しました (ExitCode: $($proc.ExitCode))" "ERROR"
            if ($stdout) { Write-AppLog "標準出力: $stdout" "ERROR" }
            if ($stderr) { Write-AppLog "標準エラー: $stderr" "ERROR" }
            Update-ContainerLogFile -EchoToGui $true
            Set-UIState "起動失敗" $brushRed $true $false

            # イメージ未検出エラーなら自動ビルドを促す
            if ($stderr -match "IMAGE_NOT_FOUND|pull access denied") {
                $askBuild = Show-AppConfirm -Message "コンテナイメージ ($ImageName) が見つかりませんでした。`r`n`r`n今すぐローカルでイメージをビルドしますか？" -Title "コンテナイメージの構築 - hayamimi"
                if ($askBuild -eq [System.Windows.MessageBoxResult]::Yes) {
                    Invoke-BuildContainerImage -Force $false -AutoStart $true | Out-Null
                }
            }
            return
        }

        $containerId = $stdout.Trim()
        Write-AppLog "コンテナプロセスが開始されました (ID: $containerId)"
        Write-AppLog "※ 初回起動時はモデルのダウンロード (約1.7GB) のため、起動完了まで数分かかります。" "INFO"
        Write-AppLog "※ 進行状況は下のログおよび logs/container.log に随時表示されます。" "INFO"
        Write-AppLog "サーバー初期化とポート8833の待機を確認しています..." "INFO"

        # 起動直後のコンテナ状態を診断ログ出力
        try {
            $pinfoDiag = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfoDiag.FileName = $script:WslcCmd
            $pinfoDiag.Arguments = "inspect $ContainerName"
            $pinfoDiag.RedirectStandardOutput = $true
            $pinfoDiag.UseShellExecute = $false
            $pinfoDiag.CreateNoWindow = $true
            $procDiag = [System.Diagnostics.Process]::Start($pinfoDiag)
            $diagRaw = $procDiag.StandardOutput.ReadToEnd()
            $procDiag.WaitForExit(1000) | Out-Null
            if ($diagRaw -match '"Status"\s*:\s*"([^"]+)"') {
                Write-AppLog "コンテナ初期ステータス: $($Matches[1])" "INFO"
            }
        } catch {}

        Update-ContainerLogFile -EchoToGui $true
        $script:HealthCheckAttempts = 0
        $script:ContainerDeadCount = 0
        $healthTimer.Start()

    } catch {
        Write-AppLog "起動処理中に例外が発生しました: $($_.Exception.ToString())" "ERROR"
        Set-UIState "エラー" $brushRed $true $false
    }
}

# ビルド状態変数
$script:BuildLogFile = Join-Path $LogsDir "build.log"
$script:LastBuildLogLineCount = 0
$script:ProcBuild = $null
$script:BuildAutoStart = $false

# コンテナイメージのビルド / リビルド関数 (ファイルリダイレクト & タイマー駆動方式)
function Invoke-BuildContainerImage {
    param(
        [bool]$Force = $false,
        [bool]$AutoStart = $false
    )

    if (-not $script:WslcCmd) {
        Write-AppLog "WSL Containers (wslc.exe) が利用できません。先に WSL 3.0 をセットアップしてください。" "ERROR"
        return $false
    }

    if (Test-ContainerRunning) {
        Write-AppLog "ビルドのため、稼働中のコンテナを停止・削除します..."
        try {
            $pinfoStop = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfoStop.FileName = $script:WslcCmd
            $pinfoStop.Arguments = "stop $ContainerName"
            $pinfoStop.UseShellExecute = $false
            $pinfoStop.CreateNoWindow = $true
            $procStop = [System.Diagnostics.Process]::Start($pinfoStop)
            $procStop.WaitForExit()

            $pinfoRm = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfoRm.FileName = $script:WslcCmd
            $pinfoRm.Arguments = "remove $ContainerName"
            $pinfoRm.UseShellExecute = $false
            $pinfoRm.CreateNoWindow = $true
            $procRm = [System.Diagnostics.Process]::Start($pinfoRm)
            $procRm.WaitForExit()
        } catch {}
    }

    Set-UIState "イメージ構築中..." $brushOrange $false $false
    if ($btnRebuild) { $btnRebuild.IsEnabled = $false }

    $actionName = if ($Force) { "リビルド (再構築)" } else { "初回ビルド" }
    Write-AppLog "=========================================="
    Write-AppLog "コンテナイメージの $actionName を開始します..." "INFO"
    Write-AppLog "ビルドディレクトリ: $ProjectRoot" "INFO"
    Write-AppLog "実行: wslc build -t $ImageName ." "INFO"
    Write-AppLog "※ 環境により数分かかります。完了までそのままお待ちください..." "INFO"

    $script:BuildAutoStart = $AutoStart
    $script:LastBuildLogLineCount = 0

    try {
        if (Test-Path $script:BuildLogFile) {
            Remove-Item -Path $script:BuildLogFile -Force -ErrorAction SilentlyContinue
        }
        [System.IO.File]::WriteAllText($script:BuildLogFile, "# hayamimi build log`r`n", [System.Text.Encoding]::UTF8)

        $pinfoBuild = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfoBuild.FileName = "cmd.exe"
        $pinfoBuild.Arguments = "/s /c `"`"$script:WslcCmd`" build -t $ImageName . > `"$script:BuildLogFile`" 2>&1`""
        $pinfoBuild.WorkingDirectory = $ProjectRoot
        $pinfoBuild.UseShellExecute = $false
        $pinfoBuild.CreateNoWindow = $true

        $script:ProcBuild = [System.Diagnostics.Process]::Start($pinfoBuild)
        $buildTimer.Start()
        return $true
    } catch {
        if ($btnRebuild) { $btnRebuild.IsEnabled = $true }
        Write-AppLog "ビルドプロセスの起動に失敗しました: $_" "ERROR"
        Set-UIState "エラー" $brushRed $true $false
        return $false
    }
}

# 本体の最新コード取得（アップデート）関数
function Invoke-UpdateAppCode {
    try {
        $confirm = Show-AppConfirm -Message "GitHub (Maximilian2022/hayamimi) から最新のソースコードを取得（アップデート）しますか？`r`n`r`n※ 取得完了後、コンテナのリビルドを実施することで最新機能が反映されます。" -Title "本体のアップデート - hayamimi"
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

        Write-AppLog "=========================================="
        Write-AppLog "本体の最新コード取得（アップデート）を開始します..." "INFO"
        Set-UIState "更新取得中..." $brushOrange $false $false
        if ($btnUpdateApp) { $btnUpdateApp.IsEnabled = $false }
        if ($btnRebuild) { $btnRebuild.IsEnabled = $false }

        $updateSuccess = $false
        $hasGit = $false

        # 1. git の存在確認
        try {
            $gitCmd = where.exe git 2>$null
            if ($gitCmd -and (Test-Path (Join-Path $ProjectRoot ".git"))) {
                $hasGit = $true
            }
        } catch {}

        if ($hasGit) {
            Write-AppLog "Git リポジトリを検出しました。git pull を実行中..." "INFO"
            $pinfoGit = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfoGit.FileName = "git.exe"
            $pinfoGit.Arguments = "pull origin main"
            $pinfoGit.WorkingDirectory = $ProjectRoot
            $pinfoGit.RedirectStandardOutput = $true
            $pinfoGit.RedirectStandardError = $true
            $pinfoGit.UseShellExecute = $false
            $pinfoGit.CreateNoWindow = $true

            $procGit = [System.Diagnostics.Process]::Start($pinfoGit)
            $gitStdout = $procGit.StandardOutput.ReadToEnd()
            $gitStderr = $procGit.StandardError.ReadToEnd()
            $procGit.WaitForExit()

            if ($gitStdout) {
                $gLines = ($gitStdout -split "`r?`n") | Where-Object { $_.Trim() }
                if ($gLines) {
                    Write-AppLogBatch -Messages ($gLines | ForEach-Object { "[Git] $_" }) -Level "INFO"
                }
            }
            if ($procGit.ExitCode -eq 0) {
                Write-AppLog "✔ Git による最新コードの取得が正常に完了しました！" "INFO"
                $updateSuccess = $true
            } else {
                if ($gitStderr) {
                    $eLines = ($gitStderr -split "`r?`n") | Where-Object { $_.Trim() }
                    if ($eLines) {
                        Write-AppLogBatch -Messages ($eLines | ForEach-Object { "[Git エラー] $_" }) -Level "WARN"
                    }
                }
                Write-AppLog "Git pull に失敗したため、GitHub からの直接ダウンロードに切り替えます..." "WARN"
            }
        }

        # 2. Git がない、または git pull 失敗時は GitHub ZIP 直接取得
        if (-not $updateSuccess) {
            Write-AppLog "GitHub API から最新ソースコードアーカイブを取得中..." "INFO"
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $zipUrl = "https://github.com/Maximilian2022/hayamimi/archive/refs/heads/main.zip"
            $tempZip = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "hayamimi-latest.zip")
            $tempExtract = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "hayamimi-extract-" + [System.Guid]::NewGuid().ToString("N"))

            Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 30
            Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

            # 展開フォルダ内のファイルをプロジェクトルートに安全上書き (models/ や logs/ や .git は保持)
            $innerDir = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
            if ($innerDir) {
                $srcItems = Get-ChildItem -Path $innerDir.FullName
                foreach ($item in $srcItems) {
                    if ($item.Name -in @(".git", "models", "logs", "scratch")) { continue }
                    $destPath = Join-Path $ProjectRoot $item.Name
                    if ($item.PSIsContainer) {
                        if (-not (Test-Path $destPath)) {
                            New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                        }
                        Copy-Item -Path (Join-Path $item.FullName "*") -Destination $destPath -Recurse -Force
                    } else {
                        Copy-Item -Path $item.FullName -Destination $destPath -Force
                    }
                }

                # 過去の二重ネストフォルダの自己修復
                $cleanCandidateDirs = @("scripts", "docs", "tests", "demo", "mobile", "nginx", ".github")
                foreach ($cand in $cleanCandidateDirs) {
                    $pDir = Join-Path $ProjectRoot $cand
                    $nDir = Join-Path $pDir $cand
                    if ((Test-Path $pDir) -and (Test-Path $nDir) -and (Get-Item $nDir).PSIsContainer) {
                        $cItems = Get-ChildItem -Path $nDir
                        foreach ($ci in $cItems) {
                            $targetCi = Join-Path $pDir $ci.Name
                            if (-not (Test-Path $targetCi)) {
                                Move-Item -Path $ci.FullName -Destination $targetCi -Force
                            }
                        }
                        Remove-Item -Path $nDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }

                Write-AppLog "✔ GitHub アーカイブからの最新コード反映が完了しました！" "INFO"
                $updateSuccess = $true
            }

            # クリーンアップ
            Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ($btnUpdateApp) { $btnUpdateApp.IsEnabled = $true }
        if ($btnRebuild) { $btnRebuild.IsEnabled = $true }
        Set-UIState "停止中" $brushGray $true $false

        if ($updateSuccess) {
            $askRestart = Show-AppConfirm -Message "最新のソースコードを取得しました！`r`n`r`nランチャーGUIを最新版で再起動しますか？`r`n(※ 再起動後、必要に応じて「🔄 コンテナをリビルド」を行ってください)" -Title "本体更新の完了 - hayamimi"
            if ($askRestart -eq [System.Windows.MessageBoxResult]::Yes) {
                Write-AppLog "ランチャーを再起動して最新コードを適用します..." "INFO"
                $startVbs = Join-Path $ProjectRoot "start.vbs"
                $startBat = Join-Path $ProjectRoot "start.bat"
                try {
                    if (Test-Path $startVbs) {
                        Start-Process "wscript.exe" -ArgumentList "`"$startVbs`""
                    } elseif (Test-Path $startBat) {
                        Start-Process "cmd.exe" -ArgumentList "/c `"$startBat`""
                    } else {
                        Start-Process "pwsh.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDir\launcher_gui.ps1`""
                    }
                } catch {
                    Start-Process "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptDir\launcher_gui.ps1`""
                }
                $window.Close()
                return
            } else {
                $askRebuild = Show-AppConfirm -Message "更新をコンテナに反映するため、今すぐリビルドを実行しますか？`r`n(※ ランチャーGUI自体の変更を反映するには、後ほどランチャーを手動で再起動してください)" -Title "コンテナの更新反映 - hayamimi"
                if ($askRebuild -eq [System.Windows.MessageBoxResult]::Yes) {
                    Invoke-BuildContainerImage -Force $true -AutoStart $false | Out-Null
                }
            }
        }
    } catch {
        Write-AppLog "本体アップデート処理中にエラーが発生しました: $_" "ERROR"
        Set-UIState "エラー" $brushRed $true $false
        if ($btnUpdateApp) { $btnUpdateApp.IsEnabled = $true }
        if ($btnRebuild) { $btnRebuild.IsEnabled = $true }
    }
}

# ビルド監視用タイマー (安全なイベント駆動方式 & バッチログ出力)
$buildTimer = [System.Windows.Threading.DispatcherTimer]::new()
$buildTimer.Interval = [TimeSpan]::FromMilliseconds(500)

$buildTimer.Add_Tick({
    try {
        # 1. ビルドログの読み込みとGUIリアルタイム反映 (ロック共有で安全読み取り & バッチ出力)
        if (Test-Path $script:BuildLogFile) {
            $lines = Read-FileSharedLines -FilePath $script:BuildLogFile
            if ($lines.Length -gt $script:LastBuildLogLineCount) {
                $batch = [System.Collections.Generic.List[string]]::new()
                for ($i = $script:LastBuildLogLineCount; $i -lt $lines.Length; $i++) {
                    $line = $lines[$i]
                    if ($line.Trim() -and $line -notmatch "^# hayamimi build log") {
                        $batch.Add("[ビルド] $line")
                    }
                }
                $script:LastBuildLogLineCount = $lines.Length
                if ($batch.Count -gt 0) {
                    Write-AppLogBatch -Messages $batch -Level "INFO"
                }
            }
        }

        # 2. プロセス終了チェック
        if ($script:ProcBuild -and $script:ProcBuild.HasExited) {
            $buildTimer.Stop()

            # 最後のログを読み切る
            Start-Sleep -Milliseconds 200
            if (Test-Path $script:BuildLogFile) {
                $lines = Read-FileSharedLines -FilePath $script:BuildLogFile
                if ($lines.Length -gt $script:LastBuildLogLineCount) {
                    $batch = [System.Collections.Generic.List[string]]::new()
                    for ($i = $script:LastBuildLogLineCount; $i -lt $lines.Length; $i++) {
                        $line = $lines[$i]
                        if ($line.Trim() -and $line -notmatch "^# hayamimi build log") {
                            $batch.Add("[ビルド] $line")
                        }
                    }
                    $script:LastBuildLogLineCount = $lines.Length
                    if ($batch.Count -gt 0) {
                        Write-AppLogBatch -Messages $batch -Level "INFO"
                    }
                }
            }

            $exitCode = $script:ProcBuild.ExitCode
            if ($btnRebuild) { $btnRebuild.IsEnabled = $true }

            if ($exitCode -eq 0) {
                Write-AppLog "✔ コンテナイメージ ($ImageName) の構築が正常に完了しました！" "INFO"
                Write-AppLog "=========================================="
                Set-UIState "停止中" $brushGray $true $false
                if ($script:BuildAutoStart) {
                    Write-AppLog "コンテナの起動処理へ自動移行します..."
                    Start-HayamimiContainer
                }
            } else {
                Write-AppLog "コンテナイメージのビルドに失敗しました (ExitCode: $exitCode)" "ERROR"
                Set-UIState "ビルド失敗" $brushRed $true $false
            }
        }
    } catch {
        $buildTimer.Stop()
        Write-AppLog "ビルド監視中に例外が発生しました: $_" "ERROR"
        Set-UIState "エラー" $brushRed $true $false
        if ($btnRebuild) { $btnRebuild.IsEnabled = $true }
    }
})

# ヘルスチェックタイマー (最大10分待機・初期化猶予付きコンテナ異常終了検知)
$script:HealthCheckAttempts = 0
$script:ContainerDeadCount = 0
$healthTimer = [System.Windows.Threading.DispatcherTimer]::new()
$healthTimer.Interval = [TimeSpan]::FromMilliseconds(500)

$healthTimer.Add_Tick({
    $script:HealthCheckAttempts++

    # 1. コンテナ生存チェック & コンテナログ同期 (毎秒)
    if ($script:HealthCheckAttempts % 2 -eq 0) {
        Update-ContainerLogFile -EchoToGui $true

        $isRunning = Test-ContainerRunning
        if ($isRunning) {
            $script:ContainerDeadCount = 0
        } else {
            # 起動直後の最初の15秒間 (attempts <= 30) は状態遷移・起動ラグ猶予のため加算しない
            if ($script:HealthCheckAttempts -gt 30) {
                $script:ContainerDeadCount++
            }
        }

        # 連続 5 回 (約 5 秒間連続) で非生存が確認された場合のみ異常終了と判定
        if ($script:ContainerDeadCount -ge 5) {
            $healthTimer.Stop()
            Update-ContainerLogFile -EchoToGui $true
            Set-UIState "コンテナ異常停止" $brushRed $true $false
            Write-AppLog "==========================================" "ERROR"
            Write-AppLog "エラー: コンテナ ($ContainerName) が異常終了しました。" "ERROR"

            # 1. コンテナの終了状態 (ExitCode / State) を取得
            try {
                $pinfoInsp = [System.Diagnostics.ProcessStartInfo]::new()
                $pinfoInsp.FileName = $script:WslcCmd
                $pinfoInsp.Arguments = "inspect $ContainerName"
                $pinfoInsp.RedirectStandardOutput = $true
                $pinfoInsp.UseShellExecute = $false
                $pinfoInsp.CreateNoWindow = $true
                $procInsp = [System.Diagnostics.Process]::Start($pinfoInsp)
                $inspRaw = $procInsp.StandardOutput.ReadToEnd()
                $procInsp.WaitForExit(2000) | Out-Null
                if ($inspRaw) {
                    if ($inspRaw -match '"ExitCode"\s*:\s*(\d+)') {
                        Write-AppLog "コンテナ終了コード (ExitCode): $($Matches[1])" "ERROR"
                    }
                    if ($inspRaw -match '"OOMKilled"\s*:\s*(true|false)') {
                        Write-AppLog "メモリ不足強制停止 (OOMKilled): $($Matches[1])" "ERROR"
                    }
                }
            } catch {}

            # 2. コンテナの標準エラー・標準出力ログを取得して表示
            try {
                $pinfoFinal = [System.Diagnostics.ProcessStartInfo]::new()
                $pinfoFinal.FileName = $script:WslcCmd
                $pinfoFinal.Arguments = "logs $ContainerName"
                $pinfoFinal.RedirectStandardOutput = $true
                $pinfoFinal.RedirectStandardError = $true
                $pinfoFinal.UseShellExecute = $false
                $pinfoFinal.CreateNoWindow = $true
                $procFinal = [System.Diagnostics.Process]::Start($pinfoFinal)
                $finalRaw = $procFinal.StandardOutput.ReadToEnd()
                $finalErr = $procFinal.StandardError.ReadToEnd()
                $procFinal.WaitForExit(2000) | Out-Null
                
                $combinedLogs = ($finalRaw + "`r`n" + $finalErr).Trim()
                if ($combinedLogs) {
                    $tailLines = ($combinedLogs -split "[\r\n]+" | Where-Object { $_.Trim() } | Select-Object -Last 25) -join "`r`n"
                    if ($tailLines) {
                        Write-AppLog "【コンテナ終了時の最終出力ログ】:`r`n$tailLines" "ERROR"
                    }
                }
            } catch {}
            Write-AppLog "詳細ログは logs/container.log および logs/launcher.log をご確認ください。" "ERROR"
            Write-AppLog "==========================================" "ERROR"
            return
        }
    }

    # 2. 定期的なステータス表示更新 (10秒ごと)
    if ($script:HealthCheckAttempts % 20 -eq 0) {
        $elapsedSec = [int]($script:HealthCheckAttempts / 2)
        Set-UIState "準備中 (${elapsedSec}s)..." $brushOrange $false $true
        if ($elapsedSec % 30 -eq 0) {
            Write-AppLog "サーバー初期化中 (${elapsedSec}秒経過)... モデルDLおよびロード完了までそのままお待ちください。" "INFO"
        }
    }

    # 3. HTTP 応答確認 (ポート8833)
    $ready = $false
    try {
        $req = [System.Net.HttpWebRequest]::Create($MicUrl)
        $req.Timeout = 400
        $req.Method = "GET"
        $resp = $req.GetResponse()
        if ($resp.StatusCode -eq [System.Net.HttpStatusCode]::OK) {
            $ready = $true
        }
        $resp.Close()
    } catch {}

    if ($ready) {
        $healthTimer.Stop()
        Update-ContainerLogFile -EchoToGui $true
        Set-UIState "稼働中 (8833 / 8766)" $brushGreen $false $true
        Write-AppLog "✔ サーバー起動完了！ブラウザを開きます: $MicUrl" "INFO"
        try {
            Start-Process $MicUrl
        } catch {
            Write-AppLog "ブラウザ起動エラー: $_" "WARN"
        }
    } elseif ($script:HealthCheckAttempts -ge 1200) {
        # 10分 (1200 * 0.5s = 600s) 経過でタイムアウト
        $healthTimer.Stop()
        Update-ContainerLogFile -EchoToGui $true
        Set-UIState "待機タイムアウト" $brushRed $true $true
        Write-AppLog "サーバーの応答待機がタイムアウトしました (10分経過)。logs/container.log をご確認ください。" "ERROR"
    }
})

# 起動ボタン処理
$btnStart.Add_Click({
    try {
        # 1. 仮想化基盤 (Hypervisor / BIOS VT-x) チェック
        $diag = Get-VirtualizationDiagnostic
        if (-not $diag.IsReady) {
            Update-WslcBannerState | Out-Null
            if ($diag.Reason -eq "BiosDisabled") {
                Show-BiosVirtualizationGuide -Diag $diag
                return
            } else {
                $askVmp = Show-AppConfirm -Message "Windows の仮想化基盤 (VirtualMachinePlatform) が無効、またはPCの再起動待ちです。`r`n`r`n今すぐ全自動で仮想化基盤と WSL 3.0 を有効化しますか？`r`n(管理者権限の設定画面が開きます)" -Title "仮想化基盤の有効化 - hayamimi"
                if ($askVmp -eq [System.Windows.MessageBoxResult]::Yes) {
                    Invoke-InstallWslContainers | Out-Null
                }
                return
            }
        }

        # 2. WSL Containers (wslc.exe) 存在確認
        $script:WslcCmd = Get-WslcCommand
        if (-not $script:WslcCmd) {
            Update-WslcBannerState | Out-Null
            Set-UIState "WSL3 未検出" $brushOrange $true $false
            Write-AppLog "【案内】WSL 3.0 / WSL Containers (wslc.exe) が未インストールです。" "WARN"

            $msgRes = Show-AppConfirm -Message "hayamimi を動かすには WSL 3.0 (WSL Containers) が必要です。`r`n`r`n今すぐ自動でインストールを開始しますか？" -Title "WSL 3.0 の自動インストール - hayamimi"
            if ($msgRes -eq [System.Windows.MessageBoxResult]::Yes) {
                $installed = Invoke-InstallWslContainers
                if (-not $installed) { return }
            } else {
                return
            }
        }

        # 2. コンテナイメージの存在確認 (未ビルド環境の場合は全自動ビルドして起動)
        if (-not (Test-HayamimiImageExists)) {
            Write-AppLog "【初回検知】hayamimi コンテナイメージが未構築です。自動ビルドを開始します..." "INFO"
            Invoke-BuildContainerImage -Force $false -AutoStart $true | Out-Null
            return
        }

        # 3. 通常起動
        Start-HayamimiContainer

    } catch {
        Write-AppLog "起動ボタン処理エラー: $_" "ERROR"
        Set-UIState "エラー" $brushRed $true $false
    }
})

# 本体アップデートボタン処理 (GitHubからの最新コード取得)
if ($btnUpdateApp) {
    $btnUpdateApp.Add_Click({
        Invoke-UpdateAppCode
    })
}

# リビルドボタン処理 (ソースコード更新時の再構築・完全例外保護)
if ($btnRebuild) {
    $btnRebuild.Add_Click({
        try {
            $confirm = Show-AppConfirm -Message "最新のソースコードをコンテナイメージに反映（リビルド）しますか？`r`n`r`n※ 実行には数分かかる場合があります。" -Title "コンテナのリビルド - hayamimi"
            if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
                Invoke-BuildContainerImage -Force $true -AutoStart $false | Out-Null
            }
        } catch {
            Write-AppLog "リビルド処理中にエラーが発生しました: $_" "ERROR"
            Set-UIState "エラー" $brushRed $true $false
            if ($btnRebuild) { $btnRebuild.IsEnabled = $true }
        }
    })
}

# 終了ボタン処理
$btnStop.Add_Click({
    try {
        $healthTimer.Stop()
        Set-UIState "停止処理中..." $brushOrange $false $false
        Write-AppLog "hayamimi コンテナを停止しています..."

        # 停止前に最新コンテナログを保存
        Update-ContainerLogFile

        if ($script:WslcCmd) {
            $pinfoStop = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfoStop.FileName = $script:WslcCmd
            $pinfoStop.Arguments = "stop $ContainerName"
            $pinfoStop.UseShellExecute = $false
            $pinfoStop.CreateNoWindow = $true
            $procStop = [System.Diagnostics.Process]::Start($pinfoStop)
            $procStop.WaitForExit()

            $pinfoRm = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfoRm.FileName = $script:WslcCmd
            $pinfoRm.Arguments = "remove $ContainerName"
            $pinfoRm.UseShellExecute = $false
            $pinfoRm.CreateNoWindow = $true
            $procRm = [System.Diagnostics.Process]::Start($pinfoRm)
            $procRm.WaitForExit()
        }
        Write-AppLog "コンテナを正常に終了・クリーンアップしました。ランチャーを閉じます。"

        $window.Close()
    } catch {
        Write-AppLog "停止処理中にエラーが発生しました: $_" "ERROR"
        $window.Close()
    }
})

# BIOS 設定ガイドボタンの処理
if ($btnBiosGuide) {
    $btnBiosGuide.Add_Click({
        try {
            Show-BiosVirtualizationGuide -Diag (Get-VirtualizationDiagnostic)
        } catch {
            Write-AppLog "BIOS ガイド表示エラー: $_" "ERROR"
        }
    })
}

# WSL & 仮想化 自動セットアップボタンの処理
if ($btnUpdateWsl) {
    $btnUpdateWsl.Add_Click({
        try {
            Invoke-InstallWslContainers | Out-Null
            Update-WslcBannerState | Out-Null
        } catch {
            Write-AppLog "WSL/仮想化セットアップ処理エラー: $_" "ERROR"
        }
    })
}

# クイックリンク
$btnOpenMic.Add_Click({ Start-Process $MicUrl })
$btnOpenObs.Add_Click({ Start-Process $ObsUrl })
$btnOpenDashboard.Add_Click({ Start-Process $DashboardUrl })
$btnClearLog.Add_Click({ $logTextBox.Clear() })

$btnOpenContainerLog.Add_Click({
    if (Test-Path $ContainerLogFile) {
        Start-Process $ContainerLogFile
    } else {
        Write-AppLog "container.log はまだ生成されていません。" "WARN"
    }
})
$btnOpenLauncherLog.Add_Click({
    if (Test-Path $LogFile) {
        Start-Process $LogFile
    }
})
$btnOpenLogsDir.Add_Click({
    if (Test-Path $LogsDir) {
        Start-Process "explorer.exe" $LogsDir
    }
})

# ウィンドウクローズ処理
$script:IsClosing = $false
$window.Add_Closing({
    param($sender, $e)
    if ($script:IsClosing) { return }

    if ($buildTimer -and $buildTimer.IsEnabled) {
        $buildTimer.Stop()
    }
    if ($script:ProcBuild -and -not $script:ProcBuild.HasExited) {
        try { $script:ProcBuild.Kill() } catch {}
    }

    if (Test-ContainerRunning) {
        $script:IsClosing = $true
        Write-AppLog "ウィンドウが閉じられたため、コンテナを停止して終了します..."
        Update-ContainerLogFile -EchoToGui $false
        if ($script:WslcCmd) {
            try {
                $pinfoStop = [System.Diagnostics.ProcessStartInfo]::new()
                $pinfoStop.FileName = $script:WslcCmd
                $pinfoStop.Arguments = "stop $ContainerName"
                $pinfoStop.UseShellExecute = $false
                $pinfoStop.CreateNoWindow = $true
                $procStop = [System.Diagnostics.Process]::Start($pinfoStop)
                $procStop.WaitForExit()

                $pinfoRm = [System.Diagnostics.ProcessStartInfo]::new()
                $pinfoRm.FileName = $script:WslcCmd
                $pinfoRm.Arguments = "remove $ContainerName"
                $pinfoRm.UseShellExecute = $false
                $pinfoRm.CreateNoWindow = $true
                $procRm = [System.Diagnostics.Process]::Start($pinfoRm)
                $procRm.WaitForExit()
            } catch {}
        }
    }
})

# 定期ポーリングタイマー (コンテナログも同期)
$pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$pollTimer.Interval = [TimeSpan]::FromSeconds(3)
$pollTimer.Add_Tick({
    if (-not $healthTimer.IsEnabled -and -not $script:IsClosing) {
        $isRunning = Test-ContainerRunning
        if ($isRunning) {
            Update-ContainerLogFile -EchoToGui $true
            if ($statusText.Text -notmatch "稼働中") {
                Set-UIState "稼働中 (8833 / 8766)" $brushGreen $false $true
            }
        } elseif (-not $isRunning -and $statusText.Text -match "稼働中") {
            Set-UIState "停止中" $brushGray $true $false
        }
    }
})

# logs/container.log の事前初期化
if (-not (Test-Path $ContainerLogFile)) {
    try {
        [System.IO.File]::WriteAllText($ContainerLogFile, "# hayamimi コンテナログ`r`n# コンテナ起動時に自動記録されます。`r`n", [System.Text.Encoding]::UTF8)
    } catch {}
}

# 初期化処理
Write-AppLog "=========================================="
Write-AppLog "hayamimi ランチャー $version を起動しました ($($runtimeBadge.Text))."
Write-AppLog "ランチャーログ: $LogFile"
Write-AppLog "コンテナログ:   $ContainerLogFile"
Write-AppLog "WSL Containers (WSL3) および仮想化環境を確認中..."

$isEnvReady = Update-WslcBannerState

if ($isEnvReady) {
    Write-AppLog "✔ WSL Containers 検出: $script:WslcCmd"
    Write-AppLog "✔ Hypervisor 仮想化基盤: 正常稼働中"
    
    if (Test-ContainerRunning) {
        Write-AppLog "既存の hayamimi コンテナが稼働中です。"
        Update-ContainerLogFile -EchoToGui $true
        Set-UIState "稼働中 (8833 / 8766)" $brushGreen $false $true
    } else {
        Write-AppLog "「コンテナ起動 & Webを開く」ボタンを押してください。"
        Set-UIState "停止中" $brushGray $true $false
    }
} else {
    $diag = Get-VirtualizationDiagnostic
    if (-not $diag.IsReady) {
        if ($diag.Reason -eq "BiosDisabled") {
            Write-AppLog "【警告】CPU ハードウェア仮想化 ($($diag.CpuVendor): VT-x / AMD-V) が BIOS で無効です。" "WARN"
            Write-AppLog "【案内】hayamimi を動かすには BIOS/UEFI で仮想化を有効にする必要があります。" "WARN"
            Write-AppLog "【解決方法】「📖 BIOS 設定ガイド」ボタンから有効化手順をご確認ください。" "WARN"
            Set-UIState "BIOS 仮想化無効" $brushOrange $true $false
        } else {
            Write-AppLog "【警告】Windows 仮想化機能 (VirtualMachinePlatform) が無効、または再起動待ちです。" "WARN"
            Write-AppLog "【解決方法】「📥 仮想化基盤 & WSL3 自動設定」ボタンを押してください。" "WARN"
            Set-UIState "仮想化基盤無効" $brushOrange $true $false
        }
    } elseif (-not $script:WslcCmd) {
        Write-AppLog "【警告】WSL 3.0 / WSL Containers (wslc.exe) が検出されませんでした。" "WARN"
        Write-AppLog "【解決方法】「📥 仮想化 & WSL3 自動設定」ボタンから全自動セットアップを実行できます。" "WARN"
        Set-UIState "WSL3 未検出" $brushOrange $true $false
    }

    # 画面描画完了時に自動でガイドまたはインストール確認ダイアログを表示
    $window.Add_ContentRendered({
        $curDiag = Get-VirtualizationDiagnostic
        if (-not $curDiag.IsReady -and $curDiag.Reason -eq "BiosDisabled") {
            Show-BiosVirtualizationGuide -Diag $curDiag
        } elseif (-not $script:WslcCmd -or -not $curDiag.IsReady) {
            $ask = Show-AppConfirm -Message "hayamimi の実行に必要な仮想化機能または WSL 3.0 がセットアップされていません。`r`n`r`n今すぐ全自動で仮想化基盤と WSL 3.0 のセットアップを開始しますか？`r`n(管理者権限のインストール画面が開きます)" -Title "環境セットアップ - hayamimi"
            if ($ask -eq [System.Windows.MessageBoxResult]::Yes) {
                Invoke-InstallWslContainers | Out-Null
                Update-WslcBannerState | Out-Null
            }
        }
    })
}

$pollTimer.Start()

# ウィンドウ表示
$window.ShowDialog() | Out-Null

$pollTimer.Stop()
$healthTimer.Stop()
