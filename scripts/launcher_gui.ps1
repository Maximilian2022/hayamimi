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
        $proc.WaitForExit()

        if ($rawLogs) {
            $lines = $rawLogs -split "`r?`n"
            $validLines = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $lines) {
                $lStr = "$line"
                if ($lStr.Trim() -and $lStr -notmatch "Error: No such container" -and $lStr -notmatch "failed to find container" -and $lStr -notmatch "Error response from daemon") {
                    $validLines.Add($lStr)
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
        Title="hayamimi - WSL3 ランチャー"
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
                <Border Grid.Column="1" Background="#1A202C" CornerRadius="12" Padding="10,4" VerticalAlignment="Center">
                    <TextBlock x:Name="RuntimeBadge" Text="WSL3 Native" FontSize="11" Foreground="#4FD1C5" FontWeight="SemiBold"/>
                </Border>
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

                <!-- WSL Containers 未検出時のアシストバナー -->
                <Border x:Name="WslcAlertBanner" Grid.Row="1" Margin="0,8,0,0" Padding="10,8" Background="#2A1B18" BorderBrush="#E74C3C" BorderThickness="1" CornerRadius="6" Visibility="Collapsed">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0" VerticalAlignment="Center">
                            <TextBlock Text="⚠ WSL 3.0 (WSL Containers) がインストールされていません" FontSize="12" FontWeight="Bold" Foreground="#FF7A6B"/>
                            <TextBlock Text="hayamimi の実行に必要な WSL 3.0 をワンクリックで自動インストールできます。" FontSize="11" Foreground="#CBD5E0" Margin="0,2,0,0"/>
                        </StackPanel>
                        <Button x:Name="BtnUpdateWsl" Grid.Column="1" Content="📥 WSL3 を自動インストール" Background="#2ECC71" Foreground="#0E1117" FontSize="11" FontWeight="Bold" Padding="12,6" VerticalAlignment="Center" Margin="8,0,0,0"/>
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
$btnUpdateWsl = $window.FindName("BtnUpdateWsl")

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

# コンテナ稼働確認関数
function Test-ContainerRunning {
    if (-not $script:WslcCmd) { return $false }
    try {
        $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfo.FileName = $script:WslcCmd
        $pinfo.Arguments = "list"
        $pinfo.RedirectStandardOutput = $true
        $pinfo.UseShellExecute = $false
        $pinfo.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $raw = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()

        if ($raw) {
            $lines = $raw -split "`r?`n"
            foreach ($line in $lines) {
                if ($line -match "^[a-f0-9]+\s+$ContainerName\s+.*running") {
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

# 1. WSL 自体の存在確認
$hasWsl = (where.exe wsl 2>$null)
if (-not $hasWsl) {
    Write-Host "[ステップ 1/4] Windows Subsystem for Linux (WSL) 基盤を新規インストールしています..." -ForegroundColor Yellow
    Write-Host "実行中: wsl.exe --install --no-distribution"
    wsl.exe --install --no-distribution
} else {
    Write-Host "[ステップ 1/4] WSL 基盤は検出されました。" -ForegroundColor Green
}

# 2. WSL を最新版に更新
Write-Host ""
Write-Host "[ステップ 2/4] WSL パッケージを最新版に更新しています..." -ForegroundColor Yellow
Write-Host "実行中: wsl.exe --update"
wsl.exe --update

# 3. プレリリース (WSL 3.0 / wslc) パッケージの適用チェック
$hasWslc = (where.exe wslc 2>$null)
if (-not $hasWslc -and -not (Test-Path "C:\Program Files\WSL\wslc.exe")) {
    Write-Host ""
    Write-Host "[ステップ 3/4] WSL 3.0 (wslc) プレリリース版パッケージを取得しています..." -ForegroundColor Yellow
    Write-Host "実行中: wsl.exe --update --pre-release"
    wsl.exe --update --pre-release
}

# 4. フォールバック: GitHub 公式リリースからの直接インストール (Store 制限等の環境向け)
$hasWslc = (where.exe wslc 2>$null)
if (-not $hasWslc -and -not (Test-Path "C:\Program Files\WSL\wslc.exe")) {
    Write-Host ""
    Write-Host "[ステップ 4/4] GitHub から最新の WSL x64 インストーラーを直接取得しています..." -ForegroundColor Yellow
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
Write-Host "  WSL 3.0 のセットアップが完了しました！" -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
Write-Host "※ 新規に WSL を有効化した場合は、PC の再起動が必要になる場合があります。" -ForegroundColor Cyan
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

        # models ディレクトリ作成
        $modelsDir = Join-Path $ProjectRoot "models"
        if (-not (Test-Path $modelsDir)) {
            New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
            Write-AppLog "models ディレクトリを作成しました: $modelsDir"
        }

        # コンテナ起動 (wslc run -d)
        Write-AppLog "wslc run を実行中 (ポート 8833, 8766)..."
        $volumeArg = "${modelsDir}:/app/models"

        $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfo.FileName = $script:WslcCmd
        $pinfo.Arguments = "run -d --name $ContainerName -p 8833:8833 -p 8766:8766 -v `"$volumeArg`" $ImageName --translate en"
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

        Update-ContainerLogFile -EchoToGui $true
        $script:HealthCheckAttempts = 0
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
                    Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
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
            $askRebuild = Show-AppConfirm -Message "最新のソースコードを取得しました！`r`n`r`n更新をコンテナに反映するため、今すぐリビルドを実行しますか？" -Title "コンテナの更新反映 - hayamimi"
            if ($askRebuild -eq [System.Windows.MessageBoxResult]::Yes) {
                Invoke-BuildContainerImage -Force $true -AutoStart $false | Out-Null
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

# ヘルスチェックタイマー (最大10分待機・コンテナ異常終了の早期検知)
$script:HealthCheckAttempts = 0
$healthTimer = [System.Windows.Threading.DispatcherTimer]::new()
$healthTimer.Interval = [TimeSpan]::FromMilliseconds(500)

$healthTimer.Add_Tick({
    $script:HealthCheckAttempts++

    # 1. コンテナ生存チェック & コンテナログ同期 (毎秒)
    if ($script:HealthCheckAttempts % 2 -eq 0) {
        Update-ContainerLogFile -EchoToGui $true

        if (-not (Test-ContainerRunning)) {
            $healthTimer.Stop()
            Update-ContainerLogFile -EchoToGui $true
            Set-UIState "コンテナ異常停止" $brushRed $true $false
            Write-AppLog "エラー: コンテナが異常終了しました。ログ (logs/container.log) をご確認ください。" "ERROR"
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
        # 1. WSL Containers (wslc.exe) 存在確認
        $script:WslcCmd = Get-WslcCommand
        if (-not $script:WslcCmd) {
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

# WSL 自動インストールボタンの処理
if ($btnUpdateWsl) {
    $btnUpdateWsl.Add_Click({
        try {
            Invoke-InstallWslContainers | Out-Null
        } catch {
            Write-AppLog "WSL更新処理エラー: $_" "ERROR"
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
Write-AppLog "hayamimi ランチャーを起動しました ($($runtimeBadge.Text))."
Write-AppLog "ランチャーログ: $LogFile"
Write-AppLog "コンテナログ:   $ContainerLogFile"
Write-AppLog "WSL Containers (WSL3) 環境を確認中..."

$script:WslcCmd = Get-WslcCommand
if ($script:WslcCmd) {
    Write-AppLog "✔ WSL Containers 検出: $script:WslcCmd"
    if ($wslcAlertBanner) { $wslcAlertBanner.Visibility = "Collapsed" }
    
    if (Test-ContainerRunning) {
        Write-AppLog "既存の hayamimi コンテナが稼働中です。"
        Update-ContainerLogFile -EchoToGui $true
        Set-UIState "稼働中 (8833 / 8766)" $brushGreen $false $true
    } else {
        Write-AppLog "「コンテナ起動 & Webを開く」ボタンを押してください。"
        Set-UIState "停止中" $brushGray $true $false
    }
} else {
    Write-AppLog "【警告】WSL 3.0 / WSL Containers (wslc.exe) が検出されませんでした。" "WARN"
    Write-AppLog "【案内】hayamimi の実行には WSL 3.0 (wslc) が必要です。" "WARN"
    Write-AppLog "【解決方法】「📥 WSL3 を自動インストール」ボタンから全自動セットアップを実行できます。" "WARN"
    if ($wslcAlertBanner) { $wslcAlertBanner.Visibility = "Visible" }
    Set-UIState "WSL3 未検出" $brushOrange $true $false

    # 画面描画完了時に自動でインストール確認ダイアログを表示
    $window.Add_ContentRendered({
        if (-not $script:WslcCmd) {
            $ask = Show-AppConfirm -Message "hayamimi の実行に必要な WSL 3.0 (WSL Containers) がインストールされていません。`r`n`r`n今すぐ全自動で WSL 3.0 をインストールしますか？`r`n(管理者権限のインストール画面が開きます)" -Title "WSL 3.0 の自動インストール - hayamimi"
            if ($ask -eq [System.Windows.MessageBoxResult]::Yes) {
                Invoke-InstallWslContainers | Out-Null
            }
        }
    })
}

$pollTimer.Start()

# ウィンドウ表示
$window.ShowDialog() | Out-Null

$pollTimer.Stop()
$healthTimer.Stop()
