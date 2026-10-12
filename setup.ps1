[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- コンソール & Windows Terminal の完全非表示化 (SW_HIDE) ---
try {
    $win32Def = @"
using System;
using System.Runtime.InteropServices;
public class SetupConsoleHelper {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
    Add-Type -TypeDefinition $win32Def -ErrorAction SilentlyContinue

    $cWnd = [SetupConsoleHelper]::GetConsoleWindow()
    if ($cWnd -ne [IntPtr]::Zero) {
        [SetupConsoleHelper]::ShowWindow($cWnd, 0)
    }

    $curPid = $PID
    for ($i = 0; $i -lt 5; $i++) {
        $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId = $curPid" -ErrorAction SilentlyContinue).ParentProcessId
        if (-not $parentPid) { break }
        $parentProc = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
        if ($parentProc) {
            if ($parentProc.ProcessName -match "WindowsTerminal|wt|cmd|conhost") {
                if ($parentProc.MainWindowHandle -ne [IntPtr]::Zero) {
                    [SetupConsoleHelper]::ShowWindow($parentProc.MainWindowHandle, 0)
                }
            }
        }
        $curPid = $parentPid
    }
} catch {}

<#
.SYNOPSIS
    hayamimi (早耳) - モダンGUI インストーラー / セットアップスクリプト
.DESCRIPTION
    GitHubから最新の hayamimi を指定フォルダ（既定: マイドキュメント\hayamimi）にダウンロード・展開し、
    デスクトップショートカットの作成やWSL Containers環境の要件確認を行います。
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$RepoZipUrl = "https://github.com/Maximilian2022/hayamimi/archive/refs/heads/main.zip"
$DefaultInstallPath = [System.IO.Path]::Combine([System.Environment]::GetFolderPath("MyDocuments"), "hayamimi")

# XAML 定義
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="hayamimi セットアップ"
        Height="620" Width="660"
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
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,8"/>
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

        <Style TargetType="TextBox">
            <Setter Property="FontFamily" Value="{StaticResource MainFont}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Background" Value="#161B26"/>
            <Setter Property="Foreground" Value="#ECE5D8"/>
            <Setter Property="BorderBrush" Value="#2D3748"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
    </Window.Resources>

    <Grid Margin="22">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
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
                        <TextBlock Text=" (早耳) セットアップ" FontSize="22" FontWeight="Bold" Foreground="#E04F2F" FontFamily="{StaticResource MainFont}" Margin="6,2,0,0"/>
                    </StackPanel>
                    <TextBlock Text="WSL Containers (WSL3) リアルタイム音声認識 &amp; 翻訳システム" 
                               FontSize="12" Foreground="#8C93A0" Margin="2,4,0,0"/>
                </StackPanel>
                <Border Grid.Column="1" Background="#1A202C" CornerRadius="12" Padding="10,4" VerticalAlignment="Center">
                    <TextBlock x:Name="WslcBadge" Text="環境チェック中..." FontSize="11" Foreground="#4FD1C5" FontWeight="SemiBold"/>
                </Border>
            </Grid>
        </Border>

        <!-- 保存先選択カード -->
        <Border Grid.Row="1" Background="#161B26" CornerRadius="10" Padding="16,14" Margin="0,0,0,12" BorderBrush="#262D3D" BorderThickness="1">
            <StackPanel Orientation="Vertical">
                <TextBlock Text="📁 インストール先フォルダ (保存先)" FontSize="13" FontWeight="Bold" Foreground="#ECE5D8" Margin="0,0,0,8"/>
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="TxtInstallPath" Grid.Column="0"/>
                    <Button x:Name="BtnBrowse" Grid.Column="2" Content="参照..." Background="#2D3748" Foreground="#ECE5D8" Padding="16,8"/>
                </Grid>
                <TextBlock Text="※既定ではマイドキュメント配下の hayamimi フォルダに配置されます。" 
                           FontSize="11" Foreground="#718096" Margin="2,6,0,0"/>
            </StackPanel>
        </Border>

        <!-- オプションカード -->
        <Border Grid.Row="2" Background="#161B26" CornerRadius="10" Padding="16,12" Margin="0,0,0,12" BorderBrush="#262D3D" BorderThickness="1">
            <StackPanel Orientation="Vertical">
                <CheckBox x:Name="ChkShortcut" Content="デスクトップにショートカットを作成する" IsChecked="True" Foreground="#ECE5D8" FontSize="13" Cursor="Hand"/>
                <TextBlock Text="※デスクトップアイコンからワンクリックでモダンGUIランチャーを起動できます。" 
                           FontSize="11" Foreground="#718096" Margin="22,4,0,0"/>
            </StackPanel>
        </Border>

        <!-- 進行状況・プログレスカード -->
        <Border Grid.Row="3" Background="#141822" CornerRadius="8" Padding="14,10" Margin="0,0,0,12" BorderBrush="#202634" BorderThickness="1">
            <StackPanel Orientation="Vertical">
                <Grid Margin="0,0,0,6">
                    <TextBlock x:Name="TxtStatus" Text="準備完了。「インストール開始」をクリックしてください。" FontSize="12" Foreground="#A0AEC0"/>
                    <TextBlock x:Name="TxtPercent" Text="0%" HorizontalAlignment="Right" FontSize="12" Foreground="#4FD1C5" FontWeight="SemiBold"/>
                </Grid>
                <ProgressBar x:Name="PbInstall" Height="6" Minimum="0" Maximum="100" Value="0" Background="#1A202C" Foreground="#2ECC71" BorderThickness="0"/>
            </StackPanel>
        </Border>

        <!-- ログ出力コンソール -->
        <Border Grid.Row="4" Background="#090B0E" CornerRadius="8" BorderBrush="#1C222E" BorderThickness="1" Margin="0,0,0,14">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Background="#11151C" Padding="10,6" CornerRadius="8,8,0,0" BorderBrush="#1C222E" BorderThickness="0,0,0,1">
                    <TextBlock Text="セットアップログ" FontSize="11" Foreground="#718096" FontFamily="{StaticResource MonoFont}"/>
                </Border>
                <ScrollViewer Grid.Row="1" x:Name="LogScrollViewer" VerticalScrollBarVisibility="Auto" Margin="8">
                    <TextBox x:Name="TxtLog"
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

        <!-- アクションボタンエリア -->
        <Grid Grid.Row="5">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            
            <StackPanel Grid.Column="0" Orientation="Horizontal">
                <Button x:Name="BtnLaunch" Content="▶ hayamimi を起動する" Background="#2ECC71" Foreground="#0E1117" Height="42" Padding="20,8" Margin="0,0,10,0" Visibility="Collapsed"/>
                <Button x:Name="BtnInstall" Content="📥 インストール開始" Background="#2ECC71" Foreground="#0E1117" Height="42" Padding="24,8"/>
            </StackPanel>

            <Button x:Name="BtnClose" Grid.Column="1" Content="閉じる" Background="#2D3748" Foreground="#ECE5D8" Height="42" Padding="20,8"/>
        </Grid>
    </Grid>
</Window>
"@

$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# コントロール取得
$wslcBadge = $window.FindName("WslcBadge")
$txtInstallPath = $window.FindName("TxtInstallPath")
$btnBrowse = $window.FindName("BtnBrowse")
$chkShortcut = $window.FindName("ChkShortcut")
$txtStatus = $window.FindName("TxtStatus")
$txtPercent = $window.FindName("TxtPercent")
$pbInstall = $window.FindName("PbInstall")
$txtLog = $window.FindName("TxtLog")
$logScrollViewer = $window.FindName("LogScrollViewer")
$btnInstall = $window.FindName("BtnInstall")
$btnLaunch = $window.FindName("BtnLaunch")
$btnClose = $window.FindName("BtnClose")

$txtInstallPath.Text = $DefaultInstallPath

function Write-SetupLog {
    param([string]$Message)
    $now = (Get-Date).ToString("HH:mm:ss")
    $txtLog.AppendText("[$now] $Message`r`n")
    $logScrollViewer.ScrollToEnd()
}

# 1. WSL Containers (wslc) チェック
$hasWslc = $false
try {
    $wslcCheck = where.exe wslc 2>$null
    if ($wslcCheck) { $hasWslc = $true }
} catch {}

if ($hasWslc) {
    $wslcBadge.Text = "✔ WSL Containers 検出済み"
    $wslcBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2ECC71")
    Write-SetupLog "WSL Containers (wslc.exe) が正常に検出されました。"
} else {
    $wslcBadge.Text = "⚠ WSL Containers 未検出"
    $wslcBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F39C12")
    Write-SetupLog "注意: WSL Containers (wslc.exe) が見つかりません。"
    Write-SetupLog "インストール後に PowerShell で 'wsl --update' を実行してください。"
}

# フォルダ参照ボタン
$btnBrowse.Add_Click({
    $fbd = [System.Windows.Forms.FolderBrowserDialog]::new()
    $fbd.Description = "hayamimi のインストール先フォルダを選択してください"
    $fbd.SelectedPath = $txtInstallPath.Text
    if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtInstallPath.Text = $fbd.SelectedPath
    }
})

# スクリプトディレクトリの取得 (ローカルファイル検出用)
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir -and $MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $ScriptDir) {
    $ScriptDir = (Get-Location).Path
}

# インストール実行用ステートマシンタイマー
$script:step = 0
$script:tempZipPath = ""
$script:tempExtractDir = ""
$script:targetDir = ""

$stepTimer = [System.Windows.Threading.DispatcherTimer]::new()
$stepTimer.Interval = [TimeSpan]::FromMilliseconds(50)

$stepTimer.Add_Tick({
    $stepTimer.Stop()

    switch ($script:step) {
        1 {
            # ステップ 1: 保存先ディレクトリ準備
            $script:targetDir = $txtInstallPath.Text.Trim()
            if (-not $script:targetDir) {
                Write-SetupLog "エラー: 保存先パスが空です。"
                $txtStatus.Text = "エラー: 保存先パスを指定してください。"
                $btnInstall.IsEnabled = $true
                return
            }

            Write-SetupLog "インストール先: $script:targetDir"
            try {
                if (-not (Test-Path $script:targetDir)) {
                    New-Item -ItemType Directory -Path $script:targetDir -Force | Out-Null
                    Write-SetupLog "フォルダを作成しました: $script:targetDir"
                }
            } catch {
                Write-SetupLog "フォルダ作成エラー: $_"
                $txtStatus.Text = "エラー: フォルダを作成できませんでした。"
                $btnInstall.IsEnabled = $true
                return
            }

            $pbInstall.Value = 15
            $txtPercent.Text = "15%"

            # ローカルにファイル群が存在するかチェック (高速インストール)
            $isLocalAvailable = (Test-Path (Join-Path $ScriptDir "start.bat")) -and (Test-Path (Join-Path $ScriptDir "scripts"))
            if ($isLocalAvailable -and ($ScriptDir -ne $script:targetDir)) {
                Write-SetupLog "ローカルの hayamimi パッケージを検出しました。"
                Write-SetupLog "ローカルからインストール先へ高速配置します..."
                $pbInstall.Value = 40
                $txtPercent.Text = "40%"
                $script:step = 3  # ファイル配置ステップへ直行
                $stepTimer.Start()
                return
            }

            # GitHub からダウンロード
            $txtStatus.Text = "GitHub から最新パッケージをダウンロード中..."
            Write-SetupLog "GitHub から ZIP アーカイブをダウンロードします..."
            Write-SetupLog "URL: $RepoZipUrl"

            $script:tempZipPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "hayamimi_main.zip")
            $script:tempExtractDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "hayamimi_extracted_" + [System.Guid]::NewGuid().ToString("N"))

            try {
                $wc = [System.Net.WebClient]::new()
                $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) hayamimi-installer")
                $wc.DownloadFile($RepoZipUrl, $script:tempZipPath)
                Write-SetupLog "ダウンロードが完了しました。"
                $pbInstall.Value = 45
                $txtPercent.Text = "45%"
            } catch {
                Write-SetupLog "ダウンロードエラー: $_"
                $txtStatus.Text = "エラー: ダウンロードに失敗しました。"
                $btnInstall.IsEnabled = $true
                return
            }

            $script:step = 2
            $stepTimer.Start()
        }

        2 {
            # ステップ 2: ZIP 展開
            $txtStatus.Text = "パッケージを展開しています..."
            Write-SetupLog "ZIP アーカイブを展開中..."
            try {
                if (Test-Path $script:tempExtractDir) { Remove-Item -Path $script:tempExtractDir -Recurse -Force | Out-Null }
                [System.IO.Compression.ZipFile]::ExtractToDirectory($script:tempZipPath, $script:tempExtractDir)
                Write-SetupLog "アーカイブの展開が完了しました。"
                $pbInstall.Value = 65
                $txtPercent.Text = "65%"
            } catch {
                Write-SetupLog "展開エラー: $_"
                $txtStatus.Text = "エラー: アーカイブの展開に失敗しました。"
                $btnInstall.IsEnabled = $true
                return
            }

            $script:step = 3
            $stepTimer.Start()
        }

        3 {
            # ステップ 3: インストール先へファイル配置
            $txtStatus.Text = "ファイルを配置しています..."
            Write-SetupLog "インストール先へファイルをコピーしています..."

            try {
                $sourceRoot = ""
                if ($script:tempExtractDir -and (Test-Path $script:tempExtractDir)) {
                    $subDirs = Get-ChildItem -Path $script:tempExtractDir -Directory
                    $sourceRoot = $script:tempExtractDir
                    if ($subDirs.Count -eq 1 -and (Test-Path (Join-Path $subDirs[0].FullName "start.bat"))) {
                        $sourceRoot = $subDirs[0].FullName
                    }
                } elseif (Test-Path (Join-Path $ScriptDir "start.bat")) {
                    $sourceRoot = $ScriptDir
                }

                if (-not $sourceRoot -or -not (Test-Path $sourceRoot)) {
                    throw "インストール元のファイルが見つかりません。"
                }

                $items = Get-ChildItem -Path $sourceRoot
                foreach ($item in $items) {
                    if ($item.Name -eq "models" -and ($sourceRoot -ne $script:targetDir)) {
                        # modelsフォルダが存在すればコピーまたは作成
                        $destModels = Join-Path $script:targetDir "models"
                        if (-not (Test-Path $destModels)) {
                            Copy-Item -Path $item.FullName -Destination $destModels -Recurse -Force
                        }
                        continue
                    }
                    if ($item.Name -eq "logs") { continue }

                    $destPath = Join-Path $script:targetDir $item.Name
                    Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
                    Write-SetupLog "配置: $($item.Name)"
                }

                # 必須ディレクトリの作成
                $modelsDir = Join-Path $script:targetDir "models"
                if (-not (Test-Path $modelsDir)) { New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null }
                $logsDir = Join-Path $script:targetDir "logs"
                if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

                $pbInstall.Value = 85
                $txtPercent.Text = "85%"
            } catch {
                Write-SetupLog "ファイル配置エラー: $_"
                $txtStatus.Text = "エラー: ファイルの配置に失敗しました。"
                $btnInstall.IsEnabled = $true
                return
            }

            $script:step = 4
            $stepTimer.Start()
        }

        4 {
            # ステップ 4: デスクトップショートカット作成
            if ($chkShortcut.IsChecked) {
                $txtStatus.Text = "デスクトップショートカットを作成しています..."
                try {
                    $desktopPath = [System.Environment]::GetFolderPath("Desktop")
                    $shortcutPath = Join-Path $desktopPath "hayamimi (早耳).lnk"
                    $targetVbs = Join-Path $script:targetDir "start.vbs"
                    $targetBat = Join-Path $script:targetDir "start.bat"

                    $wsh = New-Object -ComObject WScript.Shell
                    $shortcut = $wsh.CreateShortcut($shortcutPath)
                    
                    if (Test-Path $targetVbs) {
                        $shortcut.TargetPath = "wscript.exe"
                        $shortcut.Arguments = "`"$targetVbs`""
                    } else {
                        $shortcut.TargetPath = $targetBat
                    }
                    
                    $shortcut.WorkingDirectory = $script:targetDir
                    $shortcut.Description = "hayamimi (早耳) - リアルタイム音声認識 & 翻訳"
                    $shortcut.IconLocation = "%SystemRoot%\System32\shell32.dll, 168"
                    $shortcut.Save()

                    Write-SetupLog "デスクトップにショートカットを作成しました: $shortcutPath"
                } catch {
                    Write-SetupLog "ショートカット作成警告: $_"
                }
            }

            # テンポラリのクリーンアップ
            try {
                if ($script:tempZipPath -and (Test-Path $script:tempZipPath)) {
                    Remove-Item -Path $script:tempZipPath -Force | Out-Null
                }
                if ($script:tempExtractDir -and (Test-Path $script:tempExtractDir)) {
                    Remove-Item -Path $script:tempExtractDir -Recurse -Force | Out-Null
                }
            } catch {}

            $pbInstall.Value = 100
            $txtPercent.Text = "100%"
            $txtStatus.Text = "🎉 セットアップが正常に完了しました！"
            Write-SetupLog "=========================================="
            Write-SetupLog "hayamimi のセットアップが完了しました。"
            Write-SetupLog "保存先: $script:targetDir"
            if ($chkShortcut.IsChecked) {
                Write-SetupLog "デスクトップのショートカットまたは start.vbs / start.bat から起動できます。"
            }

            $btnInstall.Visibility = [System.Windows.Visibility]::Collapsed
            $btnLaunch.Visibility = [System.Windows.Visibility]::Visible
            $txtInstallPath.IsEnabled = $false
            $btnBrowse.IsEnabled = $false
            $chkShortcut.IsEnabled = $false
        }
    }
})

# インストールボタン
$btnInstall.Add_Click({
    $btnInstall.IsEnabled = $false
    $txtStatus.Text = "セットアップを開始しています..."
    Write-SetupLog "セットアップ処理を開始します..."
    $script:step = 1
    $stepTimer.Start()
})

# 起動ボタン
$btnLaunch.Add_Click({
    $targetDir = $txtInstallPath.Text.Trim()
    $vbsPath = Join-Path $targetDir "start.vbs"
    $batPath = Join-Path $targetDir "start.bat"

    try {
        if (Test-Path $vbsPath) {
            Start-Process "wscript.exe" "`"$vbsPath`""
        } elseif (Test-Path $batPath) {
            Start-Process $batPath
        }
        $window.Close()
    } catch {
        Write-SetupLog "起動エラー: $_"
    }
})

# 閉じるボタン
$btnClose.Add_Click({
    $window.Close()
})

Write-SetupLog "セットアップウィザードが起動しました。"
Write-SetupLog "保存先フォルダを確認して「インストール開始」をクリックしてください。"

# ウィンドウ表示
$window.ShowDialog() | Out-Null
