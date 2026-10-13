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
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="#1A202C" CornerRadius="12" Padding="10,4" VerticalAlignment="Center">
                        <TextBlock x:Name="WslcBadge" Text="環境チェック中..." FontSize="11" Foreground="#4FD1C5" FontWeight="SemiBold"/>
                    </Border>
                    <Button x:Name="BtnInstallWsl" Content="📥 WSL3 を自動インストール" Background="#2ECC71" Foreground="#0E1117" FontSize="11" FontWeight="Bold" Padding="10,4" Margin="8,0,0,0" Visibility="Collapsed"/>
                </StackPanel>
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
$btnInstallWsl = $window.FindName("BtnInstallWsl")
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
function Get-SetupWslcCommand {
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

# 仮想化・Hypervisor 診断関数 (セットアップ用)
function Get-SetupVirtualizationDiagnostic {
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

# BIOS 設定ガイドの表示 (セットアップ用)
function Show-SetupBiosGuide {
    param([object]$Diag)
    $cpuVendor = if ($Diag -and $Diag.CpuVendor) { $Diag.CpuVendor } else { "Intel" }
    $settingName = if ($cpuVendor -eq "AMD") { "「SVM Mode」または「AMD-V / SVM」" } else { "「Intel Virtualization Technology (VT-x)」または「Intel (VMX)」" }
    $cpuDesc = if ($Diag -and $Diag.CpuName) { $Diag.CpuName } else { "お使いの CPU" }

    $msg = "【CPU ハードウェア仮想化が無効です】`r`n`r`n" +
           "hayamimi (WSL Containers) を実行するには、PC の BIOS/UEFI 設定で仮想化支援機能を有効化（Enabled）にする必要があります。`r`n`r`n" +
           "■ 検出された CPU: $cpuDesc`r`n" +
           "■ 設定対象の項目名: $settingName`r`n`r`n" +
           "【有効化の手順】`r`n" +
           "1. PC を再起動し、起動直後にメーカーロゴが表示されたら [F2]、[F12]、または [Delete] キーを連打して BIOS/UEFI 画面を開きます。`r`n" +
           "2. 詳細設定 (Advanced / CPU Configuration) メニューを探します。`r`n" +
           "3. $settingName を見つけ、「有効 (Enabled)」に変更します。`r`n" +
           "4. [F10] キーを押して設定を保存し、PC を通常通り再起動してください。"

    [System.Windows.MessageBox]::Show($msg, "BIOS/UEFI 仮想化設定ガイド - hayamimi", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
}

# WSL 3.0 & 仮想化基盤 自動セットアップ関数
function Invoke-SetupInstallWslContainers {
    try {
        Write-SetupLog "WSL 3.0 / 仮想化基盤の自動セットアップを開始します..."
        $installScript = @'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "===================================================" -ForegroundColor Cyan
Write-Host "  hayamimi - WSL 3.0 & 仮想化基盤 自動セットアップ" -ForegroundColor Cyan
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
Write-Host "  WSL 3.0 & 仮想化基盤のセットアップが完了しました！" -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
if ($script:RebootNeeded) {
    Write-Host "【重要】仮想マシンプラットフォームを新規に有効化したため、" -ForegroundColor Yellow
    Write-Host "        仮想化機能の完全適用には PC の再起動が必要です。" -ForegroundColor Yellow
} else {
    Write-Host "※ 新規に WSL を有効化した場合は、PC の再起動が必要になる場合があります。" -ForegroundColor Cyan
}
Write-Host "このウィンドウを閉じると、セットアップウィザードで自動認識されます。"
Write-Host ""
Read-Host "Enterキーを押して終了してください..."
'@

        $scriptBlockFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "install_wsl3_setup.ps1")
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

        # 再検出 & 状態更新
        Update-SetupRequirementsState | Out-Null
        return ($script:wslcCmd -ne $null)
    } catch {
        Write-SetupLog "管理者権限プロンプトの起動がキャンセルされたか失敗しました: $_"
        return $false
    }
}

# セットアップ要件状態の判定とUI更新関数
function Update-SetupRequirementsState {
    $script:wslcCmd = Get-SetupWslcCommand
    $script:setupDiag = Get-SetupVirtualizationDiagnostic

    if ($script:wslcCmd -and $script:setupDiag.IsReady) {
        $wslcBadge.Text = "✔ WSL Containers & 仮想化 検出済み"
        $wslcBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2ECC71")
        if ($btnInstallWsl) { $btnInstallWsl.Visibility = [System.Windows.Visibility]::Collapsed }
        Write-SetupLog "✔ WSL Containers (wslc.exe) & Hypervisor 仮想化基盤が正常に検出されました。"
        return $true
    }

    if (-not $script:setupDiag.IsReady -and $script:setupDiag.Reason -eq "BiosDisabled") {
        $wslcBadge.Text = "⚠ BIOS 仮想化 (VT-x/AMD-V) 無効"
        $wslcBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E74C3C")
        if ($btnInstallWsl) {
            $btnInstallWsl.Content = "📖 BIOS 設定手順を確認"
            $btnInstallWsl.Visibility = [System.Windows.Visibility]::Visible
        }
        Write-SetupLog "【警告】CPU ハードウェア仮想化 ($($script:setupDiag.CpuVendor): VT-x / AMD-V) が BIOS で無効です。"
        Write-SetupLog "【案内】BIOS/UEFI 設定で仮想化支援機能を有効化してください。"
    } elseif (-not $script:setupDiag.IsReady) {
        $wslcBadge.Text = "⚠ 仮想マシンプラットフォーム無効"
        $wslcBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F39C12")
        if ($btnInstallWsl) {
            $btnInstallWsl.Content = "📥 仮想化基盤 & WSL3 を自動設定"
            $btnInstallWsl.Visibility = [System.Windows.Visibility]::Visible
        }
        Write-SetupLog "【警告】Windows 仮想化機能 (VirtualMachinePlatform) が無効、または再起動待ちです。"
    } else {
        $wslcBadge.Text = "⚠ WSL Containers 未検出"
        $wslcBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#F39C12")
        if ($btnInstallWsl) {
            $btnInstallWsl.Content = "📥 WSL3 を自動インストール"
            $btnInstallWsl.Visibility = [System.Windows.Visibility]::Visible
        }
        Write-SetupLog "注意: WSL Containers (wslc.exe) が見つかりません。"
    }
    return $false
}

Update-SetupRequirementsState | Out-Null

if ($btnInstallWsl) {
    $btnInstallWsl.Add_Click({
        $curDiag = Get-SetupVirtualizationDiagnostic
        if (-not $curDiag.IsReady -and $curDiag.Reason -eq "BiosDisabled") {
            Show-SetupBiosGuide -Diag $curDiag
        } else {
            Invoke-SetupInstallWslContainers | Out-Null
        }
    })
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
                            New-Item -ItemType Directory -Path $destModels -Force | Out-Null
                            Copy-Item -Path (Join-Path $item.FullName "*") -Destination $destModels -Recurse -Force
                        }
                        continue
                    }
                    if ($item.Name -eq "logs") { continue }

                    $destPath = Join-Path $script:targetDir $item.Name
                    if ($item.PSIsContainer) {
                        if (-not (Test-Path $destPath)) {
                            New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                        }
                        Copy-Item -Path (Join-Path $item.FullName "*") -Destination $destPath -Recurse -Force
                    } else {
                        Copy-Item -Path $item.FullName -Destination $destPath -Force
                    }
                    Write-SetupLog "配置: $($item.Name)"
                }

                # 過去のバグで発生した二重ネスト (scripts/scripts 等) の自動検出・自己修復
                $possibleNestedDirs = @("scripts", "docs", "tests", "demo", "mobile", "nginx", ".github")
                foreach ($dirName in $possibleNestedDirs) {
                    $parentDir = Join-Path $script:targetDir $dirName
                    $nestedDir = Join-Path $parentDir $dirName
                    if ((Test-Path $parentDir) -and (Test-Path $nestedDir) -and (Get-Item $nestedDir).PSIsContainer) {
                        Write-SetupLog "二重ネストフォルダを検出・自動修復中: $nestedDir"
                        $nestedChildren = Get-ChildItem -Path $nestedDir
                        foreach ($nc in $nestedChildren) {
                            $targetNcPath = Join-Path $parentDir $nc.Name
                            if (-not (Test-Path $targetNcPath)) {
                                Move-Item -Path $nc.FullName -Destination $targetNcPath -Force
                            }
                        }
                        Remove-Item -Path $nestedDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
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
    # もし WSL 3.0 (WSL Containers) が未検出の場合、自動インストールを提案
    if (-not $script:wslcCmd) {
        $ask = [System.Windows.MessageBox]::Show(
            "hayamimi の実行には WSL 3.0 (WSL Containers) が必要です。`r`n`r`n今すぐ全自動で WSL 3.0 をインストールしますか？`r`n(管理者権限のインストール画面が開きます)",
            "WSL 3.0 の自動インストール - hayamimi",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($ask -eq [System.Windows.MessageBoxResult]::Yes) {
            Invoke-SetupInstallWslContainers | Out-Null
        }
    }

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

    # 起動前に WSL3 の存在を最終確認
    if (-not $script:wslcCmd) {
        $script:wslcCmd = Get-SetupWslcCommand
    }
    if (-not $script:wslcCmd) {
        $ask = [System.Windows.MessageBox]::Show(
            "hayamimi の実行に必要な WSL 3.0 が未インストールです。`r`n今すぐ自動インストールしますか？",
            "WSL 3.0 未検出 - hayamimi",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($ask -eq [System.Windows.MessageBoxResult]::Yes) {
            $installed = Invoke-SetupInstallWslContainers
            if (-not $installed) { return }
        } else {
            return
        }
    }

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
