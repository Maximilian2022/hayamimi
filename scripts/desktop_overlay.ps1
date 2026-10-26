<#
.SYNOPSIS
    早耳 (hayamimi) - デスクトップ透過オーバーレイ字幕ウィンドウ
.DESCRIPTION
    画面最前面に字幕（リアルタイム音声認識・複数言語翻訳）を表示します。
    ドラッグ移動、自由リサイズ、クリックスルー（マウス透過）、背景透過切替、設定永続化、タスクトレイ対応。
#>

[CmdletBinding()]
param(
    [string]$ServerUrl = "http://127.0.0.1:8833",
    [switch]$Demo
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms

# Win32 API Helper
$win32Code = @"
using System;
using System.Runtime.InteropServices;

public class OverlayWin32 {
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int GWL_EXSTYLE = -20;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
    private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    public static long GetWindowLong(IntPtr hWnd, int nIndex) {
        if (IntPtr.Size == 8) {
            return (long)GetWindowLongPtr64(hWnd, nIndex);
        } else {
            return (long)GetWindowLong32(hWnd, nIndex);
        }
    }

    public static void SetClickThrough(IntPtr hWnd, bool enable) {
        long current = GetWindowLong(hWnd, GWL_EXSTYLE);
        if (enable) {
            current |= WS_EX_TRANSPARENT;
        } else {
            current &= ~WS_EX_TRANSPARENT;
        }
        if (IntPtr.Size == 8) {
            SetWindowLongPtr64(hWnd, GWL_EXSTYLE, (IntPtr)current);
        } else {
            SetWindowLong32(hWnd, GWL_EXSTYLE, (int)current);
        }
    }
}
"@
if (-not ([System.Management.Automation.PSTypeName]'OverlayWin32').Type) {
    Add-Type -TypeDefinition $win32Code
}

# 設定ファイルパス
$configDir = Join-Path $PSScriptRoot "..\config"
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}
$configFile = Join-Path $configDir "desktop_overlay.json"

# 設定の読み込み
$savedConfig = @{
    Left = $null
    Top = $null
    Width = 1100
    Height = 280
    FontSize = 30
    TransparentBg = $false
}
if (Test-Path $configFile) {
    try {
        $json = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.Width) { $savedConfig.Width = [double]$json.Width }
        if ($json.Height) { $savedConfig.Height = [double]$json.Height }
        if ($null -ne $json.Left) { $savedConfig.Left = [double]$json.Left }
        if ($null -ne $json.Top) { $savedConfig.Top = [double]$json.Top }
        if ($json.FontSize) { $savedConfig.FontSize = [double]$json.FontSize }
        if ($null -ne $json.TransparentBg) { $savedConfig.TransparentBg = [bool]$json.TransparentBg }
    } catch {}
}

# XAML UI
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="早耳 デスクトップ字幕オーバーレイ"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        ShowInTaskbar="True"
        Width="$($savedConfig.Width)" Height="$($savedConfig.Height)"
        MinWidth="450" MinHeight="140">
    <Window.Resources>
        <Style x:Key="ControlBtn" TargetType="Button">
            <Setter Property="Background" Value="#E01E293B"/>
            <Setter Property="Foreground" Value="#F8FAFC"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="9,4"/>
            <Setter Property="Margin" Value="3,0"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#475569"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#F0334155"/>
                    <Setter Property="BorderBrush" Value="#38BDF8"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <!-- メインカード（フロスト半透明パネル） -->
    <Border Name="CardBorder"
            Background="#E60F172A"
            CornerRadius="14"
            BorderBrush="#38BDF8" BorderThickness="2"
            Margin="8">
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="22" ShadowDepth="4" Opacity="0.85"/>
        </Border.Effect>

        <Grid Name="MainGrid">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- 上部コントロールバー -->
            <Border Name="ControlBar" Grid.Row="0"
                    Background="#901E293B" CornerRadius="12,12,0,0"
                    Padding="12,7" HorizontalAlignment="Stretch">
                <DockPanel LastChildFill="False">
                    <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" VerticalAlignment="Center">
                        <TextBlock Text="💬 早耳 字幕" Foreground="#38BDF8" FontWeight="Bold" FontSize="12.5" VerticalAlignment="Center" Margin="4,0,10,0"/>
                        <TextBlock Text="⠿ ドラッグ移動" Foreground="#94A3B8" FontSize="11" VerticalAlignment="Center" Margin="0,0,10,0" Cursor="SizeAll" Name="DragHandle"/>
                    </StackPanel>

                    <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" VerticalAlignment="Center">
                        <Button Name="BtnToggleBg" Style="{StaticResource ControlBtn}" Content="🎨 背景: 半透明"/>
                        <Button Name="BtnClickThrough" Style="{StaticResource ControlBtn}" Content="📌 クリック透過: OFF"/>
                        <Button Name="BtnFontSmaller" Style="{StaticResource ControlBtn}" Content="A-"/>
                        <Button Name="BtnFontBigger" Style="{StaticResource ControlBtn}" Content="A+"/>
                        <Button Name="BtnWebSettings" Style="{StaticResource ControlBtn}" Content="⚙ 設定"/>
                        <Button Name="BtnClose" Style="{StaticResource ControlBtn}" Content="✕ 閉じる"/>
                    </StackPanel>
                </DockPanel>
            </Border>

            <!-- 字幕表示エリア -->
            <Grid Grid.Row="1" Margin="20,8,20,14" VerticalAlignment="Center">
                <StackPanel Name="SubtitleContainer" VerticalAlignment="Center" HorizontalAlignment="Stretch">
                    <!-- 確定字幕 -->
                    <TextBlock Name="FinalText" Text=""
                               TextAlignment="Center" TextWrapping="Wrap"
                               Foreground="#FFFFFF" FontSize="$($savedConfig.FontSize)" FontWeight="Bold"
                               FontFamily="Zen Kaku Gothic New, Meiryo, Yu Gothic UI, sans-serif"
                               LineHeight="38">
                        <TextBlock.Effect>
                            <DropShadowEffect Color="#000000" BlurRadius="8" ShadowDepth="0" Opacity="1.0"/>
                        </TextBlock.Effect>
                    </TextBlock>

                    <!-- 発話中（仮）字幕 -->
                    <TextBlock Name="PartialText" Text=""
                               TextAlignment="Center" TextWrapping="Wrap"
                               Foreground="#E2E8F0" FontSize="22" FontStyle="Italic"
                               FontFamily="Zen Kaku Gothic New, Meiryo, Yu Gothic UI, sans-serif"
                               Opacity="0.85" Margin="0,4,0,0">
                        <TextBlock.Effect>
                            <DropShadowEffect Color="#000000" BlurRadius="6" ShadowDepth="0" Opacity="0.95"/>
                        </TextBlock.Effect>
                    </TextBlock>

                    <!-- 翻訳字幕エリア（複数言語） -->
                    <TextBlock Name="TransText" Text=""
                               TextAlignment="Center" TextWrapping="Wrap"
                               Foreground="#38BDF8" FontSize="20" FontWeight="SemiBold"
                               FontFamily="Zen Kaku Gothic New, Meiryo, Yu Gothic UI, sans-serif"
                               LineHeight="28" Margin="0,6,0,0">
                        <TextBlock.Effect>
                            <DropShadowEffect Color="#000000" BlurRadius="6" ShadowDepth="0" Opacity="1.0"/>
                        </TextBlock.Effect>
                    </TextBlock>
                </StackPanel>

                <!-- 接続待機ガイド -->
                <TextBlock Name="ConnectingNotice" Text="早耳サーバーに接続中... (アプリを起動してください)"
                           Foreground="#94A3B8" FontSize="13" FontStyle="Italic"
                           HorizontalAlignment="Center" VerticalAlignment="Center"
                           Visibility="Collapsed"/>

                <!-- 右下リサイズグリップ (ドラッグでサイズ変更) -->
                <Canvas HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="16" Height="16" Margin="0,0,-12,-8">
                    <Path Data="M 12,0 L 16,0 L 16,16 L 0,16 L 0,12 L 12,12 Z M 6,6 L 10,6 L 10,10 L 6,10 Z"
                          Fill="#64748B" Cursor="SizeNWSE" Name="ResizeGrip"/>
                </Canvas>
            </Grid>
        </Grid>
    </Border>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# コントロール取得
$mainGrid = $window.FindName("MainGrid")
$cardBorder = $window.FindName("CardBorder")
$controlBar = $window.FindName("ControlBar")
$dragHandle = $window.FindName("DragHandle")
$btnToggleBg = $window.FindName("BtnToggleBg")
$btnClickThrough = $window.FindName("BtnClickThrough")
$btnFontSmaller = $window.FindName("BtnFontSmaller")
$btnFontBigger = $window.FindName("BtnFontBigger")
$btnWebSettings = $window.FindName("BtnWebSettings")
$btnClose = $window.FindName("BtnClose")
$resizeGrip = $window.FindName("ResizeGrip")
$connectingNotice = $window.FindName("ConnectingNotice")

$finalText = $window.FindName("FinalText")
$partialText = $window.FindName("PartialText")
$transText = $window.FindName("TransText")

# 位置復元または中央配置
$primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
if ($null -ne $savedConfig.Left -and $null -ne $savedConfig.Top) {
    $window.Left = $savedConfig.Left
    $window.Top = $savedConfig.Top
} else {
    $window.Left = $primaryScreen.WorkingArea.X + ($primaryScreen.WorkingArea.Width - $window.Width) / 2
    $window.Top = $primaryScreen.WorkingArea.Y + ($primaryScreen.WorkingArea.Height - $window.Height) / 2
}

# ドラッグ移動
$dragAction = {
    param($eventSender, $e)
    if ($e.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        $window.DragMove()
    }
}
$mainGrid.Add_MouseLeftButtonDown($dragAction)
$dragHandle.Add_MouseLeftButtonDown($dragAction)
$cardBorder.Add_MouseLeftButtonDown($dragAction)

# 右下リサイズグリップのドラッグ処理
$script:isResizing = $false
$script:resizeStartPoint = [System.Windows.Point]::new(0, 0)
$script:resizeStartSize = [System.Windows.Size]::new(0, 0)

$resizeGrip.Add_MouseLeftButtonDown({
    param($eventSender, $e)
    $script:isResizing = $true
    $script:resizeStartPoint = [System.Windows.Forms.Cursor]::Position
    $script:resizeStartSize = [System.Windows.Size]::new($window.Width, $window.Height)
    $resizeGrip.CaptureMouse() | Out-Null
    $e.Handled = $true
})

$resizeGrip.Add_MouseMove({
    param($eventSender, $e)
    if ($script:isResizing) {
        $curPos = [System.Windows.Forms.Cursor]::Position
        $deltaX = $curPos.X - $script:resizeStartPoint.X
        $deltaY = $curPos.Y - $script:resizeStartPoint.Y
        $newW = [Math]::Max($window.MinWidth, $script:resizeStartSize.Width + $deltaX)
        $newH = [Math]::Max($window.MinHeight, $script:resizeStartSize.Height + $deltaY)
        $window.Width = $newW
        $window.Height = $newH
    }
})

$resizeGrip.Add_MouseLeftButtonUp({
    param($eventSender, $e)
    if ($script:isResizing) {
        $script:isResizing = $false
        $resizeGrip.ReleaseMouseCapture()
    }
})

# 背景スタイル切替
$script:isTransparentBg = $savedConfig.TransparentBg
$applyBgStyle = {
    param([bool]$transparent)
    $script:isTransparentBg = $transparent
    if ($transparent) {
        $cardBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#01000000")
        $cardBorder.BorderThickness = New-Object System.Windows.Thickness(0)
        $controlBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#400F172A")
        $btnToggleBg.Content = "🎨 背景: 完全透明"
    } else {
        $cardBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E60F172A")
        $cardBorder.BorderThickness = New-Object System.Windows.Thickness(2)
        $controlBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#901E293B")
        $btnToggleBg.Content = "🎨 背景: 半透明"
    }
}
&$applyBgStyle $script:isTransparentBg

$btnToggleBg.Add_Click({
    &$applyBgStyle (-not $script:isTransparentBg)
})

# クリックスルー管理
$script:isClickThrough = $false
$script:hWnd = [IntPtr]::Zero

$updateClickThroughUI = {
    param([bool]$enabled)
    $script:isClickThrough = $enabled
    if ($script:hWnd -ne [IntPtr]::Zero) {
        [OverlayWin32]::SetClickThrough($script:hWnd, $enabled)
    }
    if ($enabled) {
        $btnClickThrough.Content = "📌 透過中 (タスクバーで解除)"
        $btnClickThrough.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CC059669")
        $controlBar.Visibility = [System.Windows.Visibility]::Collapsed
    } else {
        $btnClickThrough.Content = "📌 クリック透過: OFF"
        $btnClickThrough.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E01E293B")
        $controlBar.Visibility = [System.Windows.Visibility]::Visible
    }
    if ($script:trayItemToggle) {
        $script:trayItemToggle.Text = if ($enabled) { "クリック透過を解除 (OFF)" } else { "クリック透過を有効化 (ON)" }
    }
}

$btnClickThrough.Add_Click({
    &$updateClickThroughUI (-not $script:isClickThrough)
})

# フォントサイズ調整
$btnFontBigger.Add_Click({
    $finalText.FontSize = [Math]::Min($finalText.FontSize + 2, 56)
    $partialText.FontSize = [Math]::Min($partialText.FontSize + 2, 44)
    $transText.FontSize = [Math]::Min($transText.FontSize + 2, 40)
})

$btnFontSmaller.Add_Click({
    $finalText.FontSize = [Math]::Max($finalText.FontSize - 2, 14)
    $partialText.FontSize = [Math]::Max($partialText.FontSize - 2, 12)
    $transText.FontSize = [Math]::Max($transText.FontSize - 2, 10)
})

# 設定ボタン
$btnWebSettings.Add_Click({
    [System.Diagnostics.Process]::Start("$ServerUrl/settings") | Out-Null
})

# 閉じるボタン
$btnClose.Add_Click({
    $window.Close()
})

# タスクバートレイアイコン
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Text = "早耳 - デスクトップ字幕"
$iconStream = [System.Drawing.SystemIcons]::Application
$notifyIcon.Icon = $iconStream
$notifyIcon.Visible = $true

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:trayItemToggle = $contextMenu.Items.Add("クリック透過を有効化 (ON)")
$script:trayItemToggle.Add_Click({
    $window.Dispatcher.Invoke([Action]{
        &$updateClickThroughUI (-not $script:isClickThrough)
    })
})

$trayItemReset = $contextMenu.Items.Add("位置を画面中央にリセット")
$trayItemReset.Add_Click({
    $window.Dispatcher.Invoke([Action]{
        $s = [System.Windows.Forms.Screen]::PrimaryScreen
        $window.Left = $s.WorkingArea.X + ($s.WorkingArea.Width - $window.Width) / 2
        $window.Top = $s.WorkingArea.Y + ($s.WorkingArea.Height - $window.Height) / 2
    })
})

$contextMenu.Items.Add("-") | Out-Null
$trayItemSettings = $contextMenu.Items.Add("Web設定画面を開く")
$trayItemSettings.Add_Click({
    [System.Diagnostics.Process]::Start("$ServerUrl/settings") | Out-Null
})

$contextMenu.Items.Add("-") | Out-Null
$trayItemExit = $contextMenu.Items.Add("オーバーレイを終了")
$trayItemExit.Add_Click({
    $window.Dispatcher.Invoke([Action]{
        $window.Close()
    })
})

$notifyIcon.ContextMenuStrip = $contextMenu

# 設定の自動保存関数
$saveSettings = {
    $cfg = @{
        Left = $window.Left
        Top = $window.Top
        Width = $window.Width
        Height = $window.Height
        FontSize = $finalText.FontSize
        TransparentBg = $script:isTransparentBg
    }
    try {
        $cfg | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8
    } catch {}
}

# ウィンドウ破棄時に設定保存 & トレイアイコン解放
$window.Add_Closed({
    &$saveSettings
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($script:sseCancelToken) {
        $script:sseCancelToken.Cancel()
    }
})

# ハンドル取得
$window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $script:hWnd = $helper.Handle
    [OverlayWin32]::SetForegroundWindow($script:hWnd) | Out-Null
})

# デモモード判定
if ($Demo) {
    $finalText.Text = "早耳のデスクトップ透過字幕オーバーレイへようこそ！"
    $partialText.Text = "これは発話中にリアルタイム表示される仮テキストのプレビューです..."
    $transText.Text = "→ [en] Welcome to Hayamimi desktop transparent subtitle overlay!`n→ [zh] 欢迎使用早耳桌面透明字幕。"
} else {
    $connectingNotice.Visibility = [System.Windows.Visibility]::Visible

    $clearTimer = New-Object System.Windows.Threading.DispatcherTimer
    $clearTimer.Interval = [TimeSpan]::FromSeconds(6)
    $clearTimer.Add_Tick({
        $finalText.Text = ""
        $partialText.Text = ""
        $transText.Text = ""
        $clearTimer.Stop()
    })

    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $styleJson = $wc.DownloadString("$ServerUrl/overlay-style")
        $s = ConvertFrom-Json $styleJson
        if ($s.size) { $finalText.FontSize = [double]$s.size }
        if ($s.color) { $finalText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($s.color) }
        if ($s.font) { $finalText.FontFamily = New-Object System.Windows.Media.FontFamily($s.font) }
    } catch {}

    $script:sseCancelToken = New-Object System.Threading.CancellationTokenSource

    $script:transLines = New-Object System.Collections.Generic.List[string]

    $sseAction = [System.Threading.ThreadStart]{
        $token = $script:sseCancelToken.Token

        while (-not $token.IsCancellationRequested) {
            $resp = $null
            $stream = $null
            $sr = $null
            try {
                $req = [System.Net.HttpWebRequest]::Create("$ServerUrl/events")
                $req.Timeout = 10000
                $req.ReadWriteTimeout = 30000
                $req.Proxy = $null

                $resp = $req.GetResponse()
                $stream = $resp.GetResponseStream()
                $sr = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)

                $window.Dispatcher.Invoke([Action]{
                    $connectingNotice.Visibility = [System.Windows.Visibility]::Collapsed
                })

                while (-not $token.IsCancellationRequested -and -not $sr.EndOfStream) {
                    $line = $sr.ReadLine()
                    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(":")) { continue }
                    if ($line.StartsWith("data: ")) {
                        $jsonStr = $line.Substring(6).Trim()
                        try {
                            $ev = ConvertFrom-Json $jsonStr
                            $window.Dispatcher.Invoke([Action]{
                                $clearTimer.Stop()
                                if ($ev.type -eq "partial") {
                                    $partialText.Text = $ev.text
                                    $clearTimer.Start()
                                } elseif ($ev.type -eq "final") {
                                    $finalText.Text = $ev.text
                                    $partialText.Text = ""
                                    $script:transLines.Clear()
                                    $transText.Text = ""
                                    $clearTimer.Start()
                                } elseif ($ev.type -eq "translation") {
                                    $script:transLines.Add("→ [$($ev.lang)] $($ev.text)")
                                    $transText.Text = [string]::Join("`n", $script:transLines)
                                    $clearTimer.Start()
                                }
                            })
                        } catch {}
                    }
                }
            } catch {
                $window.Dispatcher.Invoke([Action]{
                    if ([string]::IsNullOrEmpty($finalText.Text) -and [string]::IsNullOrEmpty($partialText.Text)) {
                        $connectingNotice.Visibility = [System.Windows.Visibility]::Visible
                    }
                })
                [System.Threading.Thread]::Sleep(2000)
            } finally {
                if ($sr) { $sr.Dispose() }
                if ($stream) { $stream.Dispose() }
                if ($resp) { $resp.Dispose() }
            }
        }
    }

    $sseThread = New-Object System.Threading.Thread($sseAction)
    $sseThread.IsBackground = $true
    $sseThread.Start()
}

$window.ShowDialog() | Out-Null
