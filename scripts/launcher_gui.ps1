[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

<#
.SYNOPSIS
    hayamimi (早耳) - WSL Containers (WSL3) ランチャー GUI
.DESCRIPTION
    WPFを用いたモダンなダークUIランチャー。
    WSL Containers (wslc) を制御して hayamimi コンテナを起動・停止し、
    複数言語リアルタイム翻訳の設定、コンテナログ同期、起動完了後のブラウザ自動表示を行います。
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

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

# ランチャー用ロギング関数
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

$script:LastContainerLogLineCount = 0

# コンテナログ更新関数 (logs/container.log に同期出力し、GUIにも新着行を反映)
function Update-ContainerLogFile {
    param([bool]$EchoToGui = $true)
    try {
        $cLogs = wslc logs $ContainerName 2>&1
        if ($cLogs) {
            $validLines = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $cLogs) {
                $lStr = "$line"
                if ($lStr -notmatch "Error: No such container" -and $lStr -notmatch "failed to find container" -and $lStr -notmatch "Error response from daemon") {
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
        Height="670" Width="660"
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

        <Style TargetType="CheckBox">
            <Setter Property="FontFamily" Value="{StaticResource MainFont}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
    </Window.Resources>

    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
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
        </Border>

        <!-- リアルタイム翻訳設定カード (複数選択可能) -->
        <Border Grid.Row="2" Background="#161B26" CornerRadius="10" Padding="16,12" Margin="0,0,0,12" BorderBrush="#262D3D" BorderThickness="1">
            <StackPanel Orientation="Vertical">
                <Grid Margin="0,0,0,8">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="🌐 リアルタイム翻訳 (複数言語同時出力)" FontSize="13" FontWeight="Bold" Foreground="#ECE5D8"/>
                        <TextBlock Text=" ※未チェック時は文字起こしのみ" FontSize="11" Foreground="#718096" Margin="6,2,0,0"/>
                    </StackPanel>
                </Grid>
                <WrapPanel Orientation="Horizontal">
                    <CheckBox x:Name="ChkEn" Content="英語 (en)" IsChecked="True" Foreground="#ECE5D8" Margin="0,0,12,6"/>
                    <CheckBox x:Name="ChkZh" Content="中国語・簡体字 (zh)" IsChecked="False" Foreground="#ECE5D8" Margin="0,0,12,6"/>
                    <CheckBox x:Name="ChkZhTw" Content="台湾語・繁体字 (zh-tw)" IsChecked="False" Foreground="#ECE5D8" Margin="0,0,12,6"/>
                    <CheckBox x:Name="ChkZhHk" Content="香港語・繁体字 (zh-hk)" IsChecked="False" Foreground="#ECE5D8" Margin="0,0,12,6"/>
                    <CheckBox x:Name="ChkKo" Content="韓国語 (ko)" IsChecked="False" Foreground="#ECE5D8" Margin="0,0,12,6"/>
                    <CheckBox x:Name="ChkEs" Content="スペイン語 (es)" IsChecked="False" Foreground="#ECE5D8" Margin="0,0,12,6"/>
                    <CheckBox x:Name="ChkFr" Content="フランス語 (fr)" IsChecked="False" Foreground="#ECE5D8" Margin="0,0,12,6"/>
                    <CheckBox x:Name="ChkDe" Content="ドイツ語 (de)" IsChecked="False" Foreground="#ECE5D8" Margin="0,0,12,6"/>
                </WrapPanel>
            </StackPanel>
        </Border>

        <!-- 操作ボタンエリア -->
        <Grid Grid.Row="3" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="14"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- 起動ボタン -->
            <Button x:Name="BtnStart" Grid.Column="0" Background="#2ECC71" Foreground="#0E1117" Height="46">
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="▶" FontSize="15" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="コンテナ起動 &amp; Webを開く" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
                </StackPanel>
            </Button>

            <!-- 終了ボタン -->
            <Button x:Name="BtnStop" Grid.Column="2" Background="#E74C3C" Foreground="#FFFFFF" Height="46" IsEnabled="False">
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="■" FontSize="14" Margin="0,0,8,0" VerticalAlignment="Center"/>
                    <TextBlock Text="コンテナ終了 &amp; 閉じる" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
                </StackPanel>
            </Button>
        </Grid>

        <!-- クイックリンクエリア -->
        <Border Grid.Row="4" Background="#141822" CornerRadius="8" Padding="12,8" Margin="0,0,0,12" BorderBrush="#202634" BorderThickness="1">
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
        <Border Grid.Row="5" Background="#090B0E" CornerRadius="8" BorderBrush="#1C222E" BorderThickness="1">
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

# コントロール取得
$statusLed = $window.FindName("StatusLed")
$statusText = $window.FindName("StatusText")
$runtimeBadge = $window.FindName("RuntimeBadge")
$btnStart = $window.FindName("BtnStart")
$btnStop = $window.FindName("BtnStop")
$btnOpenMic = $window.FindName("BtnOpenMic")
$btnOpenObs = $window.FindName("BtnOpenObs")
$btnOpenDashboard = $window.FindName("BtnOpenDashboard")
$logTextBox = $window.FindName("LogTextBox")
$logScrollViewer = $window.FindName("LogScrollViewer")
$btnClearLog = $window.FindName("BtnClearLog")
$btnOpenContainerLog = $window.FindName("BtnOpenContainerLog")
$btnOpenLauncherLog = $window.FindName("BtnOpenLauncherLog")
$btnOpenLogsDir = $window.FindName("BtnOpenLogsDir")

$chkEn = $window.FindName("ChkEn")
$chkZh = $window.FindName("ChkZh")
$chkZhTw = $window.FindName("ChkZhTw")
$chkZhHk = $window.FindName("ChkZhHk")
$chkKo = $window.FindName("ChkKo")
$chkEs = $window.FindName("ChkEs")
$chkFr = $window.FindName("ChkFr")
$chkDe = $window.FindName("ChkDe")

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
    
    $chkEn.IsEnabled = $CanStart
    $chkZh.IsEnabled = $CanStart
    $chkZhTw.IsEnabled = $CanStart
    $chkZhHk.IsEnabled = $CanStart
    $chkKo.IsEnabled = $CanStart
    $chkEs.IsEnabled = $CanStart
    $chkFr.IsEnabled = $CanStart
    $chkDe.IsEnabled = $CanStart
}

function Test-ContainerRunning {
    try {
        $output = wslc list 2>&1
        foreach ($line in $output) {
            if ($line -match "^[a-f0-9]+\s+$ContainerName\s+.*running") {
                return $true
            }
        }
    } catch {}
    return $false
}

# ヘルスチェックタイマー
$script:HealthCheckAttempts = 0
$healthTimer = [System.Windows.Threading.DispatcherTimer]::new()
$healthTimer.Interval = [TimeSpan]::FromMilliseconds(500)

$healthTimer.Add_Tick({
    $script:HealthCheckAttempts++
    
    # コンテナログを logs/container.log に随時反映 (毎秒同期 & GUI表示)
    if ($script:HealthCheckAttempts % 2 -eq 0) {
        Update-ContainerLogFile -EchoToGui $true
    }

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
        Write-AppLog "サーバー起動完了！ブラウザを開きます: $MicUrl"
        try {
            Start-Process $MicUrl
        } catch {
            Write-AppLog "ブラウザ起動エラー: $_" "WARN"
        }
    } elseif ($script:HealthCheckAttempts -ge 60) {
        $healthTimer.Stop()
        Update-ContainerLogFile -EchoToGui $true
        Set-UIState "稼働中 (確認中)" $brushGreen $false $true
        Write-AppLog "応答待機がタイムアウトしましたが、コンテナは動作中です。ブラウザを開きます。" "WARN"
        try {
            Start-Process $MicUrl
        } catch {}
    }
})

# 起動ボタン処理
$btnStart.Add_Click({
    try {
        Set-UIState "起動中..." $brushOrange $false $false
        Write-AppLog "hayamimi コンテナの起動処理を開始します..."

        # container.log の初期化
        $script:LastContainerLogLineCount = 0
        $initHeader = "# === hayamimi コンテナ起動: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===`r`n"
        try {
            [System.IO.File]::WriteAllText($ContainerLogFile, $initHeader, [System.Text.Encoding]::UTF8)
        } catch {}

        # 翻訳言語引数の組み立て
        $selectedLangs = [System.Collections.Generic.List[string]]::new()
        if ($chkEn.IsChecked) { $selectedLangs.Add("en") }
        if ($chkZh.IsChecked) { $selectedLangs.Add("zh") }
        if ($chkZhTw.IsChecked) { $selectedLangs.Add("zh-tw") }
        if ($chkZhHk.IsChecked) { $selectedLangs.Add("zh-hk") }
        if ($chkKo.IsChecked) { $selectedLangs.Add("ko") }
        if ($chkEs.IsChecked) { $selectedLangs.Add("es") }
        if ($chkFr.IsChecked) { $selectedLangs.Add("fr") }
        if ($chkDe.IsChecked) { $selectedLangs.Add("de") }

        $extraArgs = ""
        if ($selectedLangs.Count -gt 0) {
            $langStr = ($selectedLangs -join ",")
            $extraArgs = "--translate $langStr"
            Write-AppLog "リアルタイム翻訳言語: $langStr"
        } else {
            Write-AppLog "リアルタイム翻訳: オフ (文字起こしのみ)"
        }

        # 既存コンテナの停止
        wslc stop $ContainerName 2>$null | Out-Null
        wslc remove $ContainerName 2>$null | Out-Null

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
        $pinfo.FileName = "wslc.exe"
        if ($extraArgs) {
            $pinfo.Arguments = "run -d --name $ContainerName -p 8833:8833 -p 8766:8766 -v `"$volumeArg`" $ImageName $extraArgs"
        } else {
            $pinfo.Arguments = "run -d --name $ContainerName -p 8833:8833 -p 8766:8766 -v `"$volumeArg`" $ImageName"
        }
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
            return
        }

        $containerId = $stdout.Trim()
        Write-AppLog "コンテナプロセスが開始されました (ID: $containerId)"
        Write-AppLog "サーバー初期化とポート8833の待機を確認しています..."
        Write-AppLog "※コンテナ出力ログは logs/container.log に記録されます。"

        Update-ContainerLogFile -EchoToGui $true
        $script:HealthCheckAttempts = 0
        $healthTimer.Start()

    } catch {
        Write-AppLog "起動処理中に例外が発生しました: $($_.Exception.ToString())" "ERROR"
        Set-UIState "エラー" $brushRed $true $false
    }
})

# 終了ボタン処理
$btnStop.Add_Click({
    try {
        $healthTimer.Stop()
        Set-UIState "停止処理中..." $brushOrange $false $false
        Write-AppLog "hayamimi コンテナを停止しています..."

        # 停止前に最新コンテナログを保存
        Update-ContainerLogFile

        wslc stop $ContainerName 2>&1 | Out-Null
        wslc remove $ContainerName 2>&1 | Out-Null
        Write-AppLog "コンテナを正常に終了・クリーンアップしました。ランチャーを閉じます。"

        $window.Close()
    } catch {
        Write-AppLog "停止処理中にエラーが発生しました: $_" "ERROR"
        $window.Close()
    }
})

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

    if (Test-ContainerRunning) {
        $script:IsClosing = $true
        Write-AppLog "ウィンドウが閉じられたため、コンテナを停止して終了します..."
        Update-ContainerLogFile -EchoToGui $false
        try {
            wslc stop $ContainerName 2>&1 | Out-Null
            wslc remove $ContainerName 2>&1 | Out-Null
        } catch {}
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

if (Test-ContainerRunning) {
    Write-AppLog "既存の hayamimi コンテナが稼働中です。"
    Update-ContainerLogFile -EchoToGui $true
    Set-UIState "稼働中 (8833 / 8766)" $brushGreen $false $true
} else {
    Write-AppLog "翻訳言語を選択し「コンテナ起動 & Webを開く」ボタンを押してください。"
    Set-UIState "停止中" $brushGray $true $false
}

$pollTimer.Start()

# ウィンドウ表示
$window.ShowDialog() | Out-Null

$pollTimer.Stop()
$healthTimer.Stop()
