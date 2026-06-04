# -*- coding: utf-8 -*-
<#
Purpose:
  Show a native next-step question window for Codex Desktop and write the
  user's choice to a structured JSON file.

Input:
  Optional -Mode interactive|test-submit|test-empty|test-attach

Output:
  last_choice.json
  next_step.log
#>

[CmdletBinding()]
param(
    [ValidateSet("interactive", "test-submit", "test-empty", "test-attach")]
    [string]$Mode = "interactive",

    [int]$AutoDelayMs = 650,

    [string]$OptionsJson = "",

    [string]$Message = "请选择要继续处理的事项，或在自定义任务中明确结束本次对话",

    [string]$DialogName = "",

    [string]$DialogId = "",

    [string]$PromptFile = "",

    [string]$TestAttachmentPath = "",

    [string]$FontPath = $env:CODEX_NEXT_STEP_FONT_PATH,

    [string]$FontFamilyName = $env:CODEX_NEXT_STEP_FONT_FAMILY,

    [switch]$KeepChoiceHistory,

    [switch]$NoRelaunch
)

$ErrorActionPreference = "Stop"

$ScriptPath = $PSCommandPath
$ToolDir = Split-Path -Parent $ScriptPath
$LastChoicePath = Join-Path $ToolDir "last_choice.json"
$JsonPath = $LastChoicePath
$LogPath = Join-Path $ToolDir "next_step.log"
$TestPath = Join-Path $ToolDir "self_test_result.json"
$PreviewPath = Join-Path $ToolDir "ui_preview.png"
$PromptDir = Join-Path $ToolDir "prompts"
$ChoiceDir = Join-Path $ToolDir "choices"
$AttachmentDir = Join-Path $ToolDir "attachments"
$InteractiveWaitPolicy = "interactive_waits_until_user_submits_no_script_timeout"
$RequiredOuterTimeoutMs = 86400000
$PreferredFontPath = $FontPath
$PreferredFontFamilyName = $FontFamilyName
$OpenAnimationDurationMs = 320
$ExitAnimationDurationMs = 220

function Get-IsoTimestamp {
    return [DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:sszzz")
}

function Write-NextStepLog {
    param([hashtable]$Entry)
    $Entry["logged_at"] = Get-IsoTimestamp
    $line = $Entry | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Read-ChoiceJson {
    if (-not (Test-Path -LiteralPath $JsonPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-NextStepLog @{
            event = "read_last_choice_failed"
            error = $_.Exception.Message
        }
        return $null
    }
}

function Write-ChoiceJson {
    param(
        [string[]]$Selected,
        [string]$CustomAnswer,
        [string[]]$OfferedOptions,
        [string[]]$Attachments
    )

    $selectedArray = @()
    if ($null -ne $Selected) {
        $selectedArray = @($Selected | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $payload = [ordered]@{
        status = "submitted"
        selected = [object[]]$selectedArray
        custom_answer = $CustomAnswer
        offered_options = [object[]]@($OfferedOptions)
        attachments = [object[]]@($Attachments)
        dialog_name = $DialogName
        dialog_id = $DialogId
        choice_path = $JsonPath
        submitted_at = Get-IsoTimestamp
    }

    $json = $payload | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $JsonPath -Value $json -Encoding UTF8
    Set-Content -LiteralPath $LastChoicePath -Value $json -Encoding UTF8
    Write-NextStepLog @{
        event = "choice_saved"
        status = "submitted"
        selected_count = @($Selected).Count
        has_custom_answer = (-not [string]::IsNullOrWhiteSpace($CustomAnswer))
        custom_answer_length = $CustomAnswer.Length
        offered_options_count = @($OfferedOptions).Count
        attachment_count = @($Attachments).Count
        choice_path = $JsonPath
    }

    return $payload
}

function New-SafeId {
    param([string]$Raw)
    $value = $Raw
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = "next-step"
    }
    $value = $value -replace "[^0-9A-Za-z\u4e00-\u9fa5_-]+", "-"
    $value = $value.Trim("-")
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = "next-step"
    }
    return $value
}

function Get-OptionLabels {
    param([string]$RawOptionsJson)

    $defaults = @(
        "检查当前状态",
        "继续完善文本",
        "处理图表或补充材料",
        "运行代码或数据核查"
    )

    if ([string]::IsNullOrWhiteSpace($RawOptionsJson)) {
        return $defaults
    }

    try {
        $parsed = $RawOptionsJson | ConvertFrom-Json
        $labels = @()
        foreach ($item in @($parsed)) {
            if ($item -is [string]) {
                $label = $item.Trim()
            }
            else {
                $label = [string]$item.label
                $label = $label.Trim()
            }
            if (-not [string]::IsNullOrWhiteSpace($label)) {
                $labels += $label
            }
        }

        $labels = @($labels | Select-Object -First 4)
        if ($labels.Count -lt 1) {
            return $defaults
        }
        return $labels
    }
    catch {
        Write-NextStepLog @{
            event = "parse_options_failed"
            error = $_.Exception.Message
            raw_options = $RawOptionsJson
        }
        return $defaults
    }
}

function Write-SelfTestResult {
    param([hashtable]$Result)
    $Result["tested_at"] = Get-IsoTimestamp
    $json = $Result | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $TestPath -Value $json -Encoding UTF8
    Write-NextStepLog @{
        event = "self_test"
        mode = $Mode
        result = $Result
    }
}

function Save-WindowPreview {
    param(
        [System.Windows.Window]$Window,
        [string]$Path
    )

    $Window.UpdateLayout()
    $width = [int][Math]::Ceiling($Window.ActualWidth)
    $height = [int][Math]::Ceiling($Window.ActualHeight)
    if ($width -lt 1 -or $height -lt 1) {
        return $false
    }

    $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        $width,
        $height,
        96,
        96,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($Window)

    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create)
    try {
        $encoder.Save($stream)
    }
    finally {
        $stream.Dispose()
    }

    return $true
}

function Invoke-ChildProcessIfNeeded {
    if ($NoRelaunch) {
        return
    }

    $safeDialogId = New-SafeId -Raw $DialogId
    if ($safeDialogId -eq "next-step") {
        $safeDialogId = New-SafeId -Raw $DialogName
    }
    $runId = "{0}-{1}-{2}" -f $safeDialogId, [DateTimeOffset]::Now.ToString("yyyyMMddHHmmssfff"), $PID
    $promptPathForRun = Join-Path $PromptDir "$runId.json"
    $choicePathForRun = Join-Path $ChoiceDir "$runId.json"

    $promptPayload = [ordered]@{
        options_json = $OptionsJson
        message = $Message
        dialog_name = $DialogName
        dialog_id = $runId
        choice_path = $choicePathForRun
        created_at = Get-IsoTimestamp
    }
    $promptPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $promptPathForRun -Encoding UTF8

    $windowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
        $windowsPowerShell = "powershell.exe"
    }

    $args = @(
        "-NoProfile",
        "-STA",
        "-ExecutionPolicy", "Bypass",
        "-File", $ScriptPath,
        "-Mode", $Mode,
        "-AutoDelayMs", $AutoDelayMs,
        "-PromptFile", $promptPathForRun,
        "-NoRelaunch"
    )
    if (-not [string]::IsNullOrWhiteSpace($TestAttachmentPath)) {
        $args = @(
            "-NoProfile",
            "-STA",
            "-ExecutionPolicy", "Bypass",
            "-File", $ScriptPath,
            "-Mode", $Mode,
            "-AutoDelayMs", $AutoDelayMs,
            "-TestAttachmentPath", $TestAttachmentPath,
            "-PromptFile", $promptPathForRun,
            "-NoRelaunch"
        )
    }
    if ($KeepChoiceHistory) {
        $args += "-KeepChoiceHistory"
    }

    $startedAt = Get-Date
    Write-NextStepLog @{
        event = "child_wait_started"
        mode = $Mode
        dialog_id = $runId
        choice_path = $choicePathForRun
        wait_policy = $InteractiveWaitPolicy
        required_outer_timeout_ms = $RequiredOuterTimeoutMs
    }
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $args -WindowStyle Hidden -PassThru
    $process.WaitForExit()
    $elapsedMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

    Write-NextStepLog @{
        event = "child_finished"
        mode = $Mode
        exit_code = $process.ExitCode
        elapsed_ms = $elapsedMs
        dialog_id = $runId
        choice_path = $choicePathForRun
    }

    $choiceOutput = $null
    if (Test-Path -LiteralPath $choicePathForRun) {
        $choiceOutput = Get-Content -LiteralPath $choicePathForRun -Raw -Encoding UTF8
    }
    elseif (Test-Path -LiteralPath $LastChoicePath) {
        $choiceOutput = Get-Content -LiteralPath $LastChoicePath -Raw -Encoding UTF8
    }

    if (-not [string]::IsNullOrWhiteSpace($choiceOutput)) {
        if (-not $KeepChoiceHistory -and (Test-Path -LiteralPath $choicePathForRun)) {
            try {
                $choiceObject = $choiceOutput | ConvertFrom-Json
                $choiceObject | Add-Member -NotePropertyName "choice_path" -NotePropertyValue $LastChoicePath -Force
                $choiceOutput = $choiceObject | ConvertTo-Json -Depth 8
                Set-Content -LiteralPath $LastChoicePath -Value $choiceOutput -Encoding UTF8
                Remove-Item -LiteralPath $choicePathForRun -Force
                Write-NextStepLog @{
                    event = "choice_history_discarded"
                    mode = $Mode
                    dialog_id = $runId
                    retained_path = $LastChoicePath
                }
            }
            catch {
                Write-NextStepLog @{
                    event = "choice_history_discard_failed"
                    mode = $Mode
                    dialog_id = $runId
                    choice_path = $choicePathForRun
                    error = $_.Exception.Message
                }
            }
        }

        $choiceOutput
    }

    exit $process.ExitCode
}

New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
New-Item -ItemType Directory -Force -Path $PromptDir | Out-Null
New-Item -ItemType Directory -Force -Path $ChoiceDir | Out-Null
New-Item -ItemType Directory -Force -Path $AttachmentDir | Out-Null
if (-not $env:SystemRoot) { $env:SystemRoot = "C:\Windows" }
if (-not $env:WINDIR) { $env:WINDIR = $env:SystemRoot }

Invoke-ChildProcessIfNeeded

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

if (-not ("Win32WindowTools" -as [type])) {
    Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32WindowTools
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int maxCount);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public static string[] GetVisibleWindowsForProcess(int pid)
    {
        var results = new List<string>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint windowPid;
            GetWindowThreadProcessId(hWnd, out windowPid);
            if (windowPid == pid && IsWindowVisible(hWnd))
            {
                int length = GetWindowTextLength(hWnd);
                var builder = new StringBuilder(length + 1);
                GetWindowText(hWnd, builder, builder.Capacity);
                var classBuilder = new StringBuilder(256);
                GetClassName(hWnd, classBuilder, classBuilder.Capacity);
                RECT rect;
                GetWindowRect(hWnd, out rect);
                int width = rect.Right - rect.Left;
                int height = rect.Bottom - rect.Top;
                results.Add(
                    hWnd.ToInt64().ToString() + "|" +
                    builder.ToString() + "|" +
                    classBuilder.ToString() + "|" +
                    width.ToString() + "x" + height.ToString()
                );
            }
            return true;
        }, IntPtr.Zero);
        return results.ToArray();
    }

    public static string[] GetVisibleWindowsByTitlePrefix(string prefix)
    {
        var results = new List<string>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            if (IsWindowVisible(hWnd))
            {
                int length = GetWindowTextLength(hWnd);
                var builder = new StringBuilder(length + 1);
                GetWindowText(hWnd, builder, builder.Capacity);
                string title = builder.ToString();
                if (!String.IsNullOrWhiteSpace(title) && title.StartsWith(prefix, StringComparison.Ordinal))
                {
                    var classBuilder = new StringBuilder(256);
                    GetClassName(hWnd, classBuilder, classBuilder.Capacity);
                    RECT rect;
                    GetWindowRect(hWnd, out rect);
                    int width = rect.Right - rect.Left;
                    int height = rect.Bottom - rect.Top;
                    results.Add(
                        hWnd.ToInt64().ToString() + "|" +
                        title + "|" +
                        classBuilder.ToString() + "|" +
                        width.ToString() + "x" + height.ToString()
                    );
                }
            }
            return true;
        }, IntPtr.Zero);
        return results.ToArray();
    }
}
"@
}

if (-not [string]::IsNullOrWhiteSpace($PromptFile) -and (Test-Path -LiteralPath $PromptFile)) {
    try {
        $promptConfig = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($promptConfig.PSObject.Properties.Name -contains "options_json") {
            $OptionsJson = [string]$promptConfig.options_json
        }
        if ($promptConfig.PSObject.Properties.Name -contains "message" -and -not [string]::IsNullOrWhiteSpace([string]$promptConfig.message)) {
            $Message = [string]$promptConfig.message
        }
        if ($promptConfig.PSObject.Properties.Name -contains "dialog_name") {
            $DialogName = [string]$promptConfig.dialog_name
        }
        if ($promptConfig.PSObject.Properties.Name -contains "dialog_id") {
            $DialogId = [string]$promptConfig.dialog_id
        }
        if ($promptConfig.PSObject.Properties.Name -contains "choice_path" -and -not [string]::IsNullOrWhiteSpace([string]$promptConfig.choice_path)) {
            $script:JsonPath = [string]$promptConfig.choice_path
        }
    }
    catch {
        Write-NextStepLog @{
            event = "read_prompt_file_failed"
            prompt_file = $PromptFile
            error = $_.Exception.Message
        }
    }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="下一步选项"
        Width="520"
        Height="570"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="True"
        Topmost="True"
        FontFamily="Segoe UI Variable Text, Segoe UI"
        FontSize="14">
    <Window.Resources>
        <Style x:Key="OptionCheckBoxStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Foreground" Value="#1D1D1F"/>
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="Margin" Value="0,8,0,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type CheckBox}">
                        <Border x:Name="Row"
                                Background="#FFFFFF"
                                BorderBrush="#E5E5EA"
                                BorderThickness="1"
                                CornerRadius="14"
                                Padding="15,13">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="22"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Border x:Name="Box"
                                        Width="18"
                                        Height="18"
                                        CornerRadius="5"
                                        Background="#FFFFFF"
                                        BorderBrush="#C7C7CC"
                                        BorderThickness="1"
                                        VerticalAlignment="Center">
                                    <Path x:Name="CheckMark"
                                          Data="M 4 9 L 7.5 12.5 L 14.5 5.5"
                                          Stroke="#FFFFFF"
                                          StrokeThickness="2"
                                          StrokeStartLineCap="Round"
                                          StrokeEndLineCap="Round"
                                          Visibility="Collapsed"/>
                                </Border>
                                <ContentPresenter Grid.Column="1"
                                                  Margin="10,0,0,0"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Row" Property="Background" Value="#F7F8FA"/>
                                <Setter TargetName="Row" Property="BorderBrush" Value="#D1D1D6"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Row" Property="Background" Value="#F2F7FF"/>
                                <Setter TargetName="Row" Property="BorderBrush" Value="#007AFF"/>
                                <Setter TargetName="Box" Property="Background" Value="#007AFF"/>
                                <Setter TargetName="Box" Property="BorderBrush" Value="#007AFF"/>
                                <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Border Background="#F5F5F7"
            BorderBrush="#D8D8DC"
            BorderThickness="1"
            CornerRadius="22"
            Padding="0">
        <Border.Effect>
            <DropShadowEffect Color="#1D1D1F" Opacity="0.16" BlurRadius="28" ShadowDepth="4"/>
        </Border.Effect>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Border x:Name="DragHeader" Grid.Row="0" Padding="26,22,26,12" Background="#F5F5F7" CornerRadius="22,22,0,0">
                <StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                        <Ellipse Width="11" Height="11" Fill="#FF5F57" Margin="0,0,8,0"/>
                        <Ellipse Width="11" Height="11" Fill="#FFBD2E" Margin="0,0,8,0"/>
                        <Ellipse Width="11" Height="11" Fill="#28C840"/>
                    </StackPanel>
                    <TextBlock x:Name="TitleText"
                               Text="下一步选项"
                               Foreground="#1D1D1F"
                               FontSize="23"
                               FontWeight="SemiBold"/>
                    <TextBlock x:Name="MessageText"
                               Text="请选择要继续处理的事项，或在自定义任务中明确结束本次对话"
                               Margin="0,9,0,0"
                               Foreground="#6E6E73"
                               FontSize="15"
                               TextWrapping="Wrap"/>
                </StackPanel>
            </Border>

            <StackPanel Grid.Row="1" Margin="26,2,26,0">
                <CheckBox x:Name="CheckStatus" Content="检查当前状态" Style="{StaticResource OptionCheckBoxStyle}"/>
                <CheckBox x:Name="ImproveText" Content="继续完善文本" Style="{StaticResource OptionCheckBoxStyle}"/>
                <CheckBox x:Name="HandleFigures" Content="处理图表或补充材料" Style="{StaticResource OptionCheckBoxStyle}"/>
                <CheckBox x:Name="RunChecks" Content="运行代码或数据核查" Style="{StaticResource OptionCheckBoxStyle}"/>

                <Border Margin="0,18,0,0"
                        Background="#FFFFFF"
                        BorderBrush="#E5E5EA"
                        BorderThickness="1"
                        CornerRadius="16">
                    <Grid>
                        <TextBox x:Name="CustomInput"
                         Height="94"
                                 TextWrapping="Wrap"
                                 AcceptsReturn="True"
                                 BorderThickness="0"
                                 Background="Transparent"
                                 Foreground="#1D1D1F"
                                 Padding="14,12,14,12"
                                 VerticalScrollBarVisibility="Auto"/>
                        <TextBlock x:Name="Placeholder"
                                   Text="输入其他下一步任务，支持 Ctrl+V 粘贴图片"
                                   Foreground="#8A939D"
                                   Margin="15,12,0,0"
                                   IsHitTestVisible="False"/>
                    </Grid>
                </Border>
                <TextBlock x:Name="AttachmentStatus"
                           Text="可将图片拖入窗口，或在输入框中 Ctrl+V 粘贴截图"
                           Margin="2,8,0,0"
                           Foreground="#6E6E73"
                           FontSize="12"/>
            </StackPanel>

            <Border Grid.Row="2" Padding="26,16,26,24" Background="#F5F5F7" CornerRadius="0,0,22,22">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <Button x:Name="ContinueButton"
                            Grid.Column="1"
                            Content="继续"
                            Width="96"
                            Height="38"
                            Background="#007AFF"
                            BorderBrush="#007AFF"
                            Foreground="#FFFFFF"
                            Padding="16,0"
                            Cursor="Hand"
                            FontWeight="SemiBold"/>
                </Grid>
            </Border>
        </Grid>
    </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$script:UiFontApplied = $false
$script:UiFontSource = $window.FontFamily.Source

if (-not [string]::IsNullOrWhiteSpace($PreferredFontPath) -and -not [string]::IsNullOrWhiteSpace($PreferredFontFamilyName) -and (Test-Path -LiteralPath $PreferredFontPath)) {
    try {
        $fontUri = ([System.Uri]$PreferredFontPath).AbsoluteUri
        $fontFamily = New-Object Windows.Media.FontFamily "$fontUri#$PreferredFontFamilyName"
        $window.FontFamily = $fontFamily
        $script:UiFontApplied = $true
        $script:UiFontSource = $fontFamily.Source
    }
    catch {
        Write-NextStepLog @{
            event = "font_apply_failed"
            font_path = $PreferredFontPath
            font_family = $PreferredFontFamilyName
            error = $_.Exception.Message
        }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($PreferredFontPath)) {
    Write-NextStepLog @{
        event = "font_file_missing"
        font_path = $PreferredFontPath
    }
}

$DragHeader = $window.FindName("DragHeader")
$CheckStatus = $window.FindName("CheckStatus")
$ImproveText = $window.FindName("ImproveText")
$HandleFigures = $window.FindName("HandleFigures")
$RunChecks = $window.FindName("RunChecks")
$CustomInput = $window.FindName("CustomInput")
$Placeholder = $window.FindName("Placeholder")
$AttachmentStatus = $window.FindName("AttachmentStatus")
$ContinueButton = $window.FindName("ContinueButton")
$MessageText = $window.FindName("MessageText")
$TitleText = $window.FindName("TitleText")

$displayTitle = "下一步选项"
if (-not [string]::IsNullOrWhiteSpace($DialogName)) {
    $displayTitle = "下一步选项（$DialogName）"
}
$window.Title = $displayTitle
$TitleText.Text = $displayTitle

$existingNextStepWindows = @([Win32WindowTools]::GetVisibleWindowsByTitlePrefix("下一步选项"))
$offsetIndex = $existingNextStepWindows.Count
$script:ExistingNextStepWindowCount = $offsetIndex
$workArea = [System.Windows.SystemParameters]::WorkArea
$baseLeft = $workArea.Left + (($workArea.Width - $window.Width) / 2)
$baseTop = $workArea.Top + (($workArea.Height - $window.Height) / 2)
$offset = [Math]::Min(($offsetIndex % 6) * 38, 190)
$window.WindowStartupLocation = "Manual"
$window.Left = [Math]::Min([Math]::Max($baseLeft + $offset, $workArea.Left + 12), $workArea.Right - $window.Width - 12)
$window.Top = [Math]::Min([Math]::Max($baseTop + $offset, $workArea.Top + 12), $workArea.Bottom - $window.Height - 12)
$targetTop = $window.Top
$window.Top = $targetTop + 18
$window.Opacity = 0
$window.Add_SourceInitialized({
    $duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds($OpenAnimationDurationMs))
    $ease = New-Object Windows.Media.Animation.CubicEase
    $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut

    $opacityAnimation = New-Object Windows.Media.Animation.DoubleAnimation
    $opacityAnimation.From = 0
    $opacityAnimation.To = 1
    $opacityAnimation.Duration = $duration
    $opacityAnimation.EasingFunction = $ease
    $window.BeginAnimation([Windows.UIElement]::OpacityProperty, $opacityAnimation)

    $topAnimation = New-Object Windows.Media.Animation.DoubleAnimation
    $topAnimation.From = $targetTop + 18
    $topAnimation.To = $targetTop
    $topAnimation.Duration = $duration
    $topAnimation.EasingFunction = $ease
    $window.BeginAnimation([Windows.Window]::TopProperty, $topAnimation)
})

$optionLabels = @(Get-OptionLabels -RawOptionsJson $OptionsJson)
$optionControls = @($CheckStatus, $ImproveText, $HandleFigures, $RunChecks)
for ($idx = 0; $idx -lt $optionControls.Count; $idx++) {
    if ($idx -lt $optionLabels.Count) {
        $optionControls[$idx].Content = $optionLabels[$idx]
        $optionControls[$idx].Visibility = "Visible"
        $optionControls[$idx].IsChecked = $false
    }
    else {
        $optionControls[$idx].Content = ""
        $optionControls[$idx].Visibility = "Collapsed"
        $optionControls[$idx].IsChecked = $false
    }
}
$MessageText.Text = $Message
$CustomInput.Text = ""
$script:ChoiceSaved = $false
$script:ExitAnimationStarted = $false
$script:Attachments = New-Object System.Collections.Generic.List[string]

function Update-Placeholder {
    if ([string]::IsNullOrWhiteSpace($CustomInput.Text)) {
        $Placeholder.Visibility = "Visible"
    }
    else {
        $Placeholder.Visibility = "Collapsed"
    }
}

function Update-AttachmentStatus {
    if ($script:Attachments.Count -gt 0) {
        $AttachmentStatus.Text = "已添加 $($script:Attachments.Count) 个图片附件"
        $AttachmentStatus.Foreground = "#007AFF"
    }
    else {
        $AttachmentStatus.Text = "可将图片拖入窗口，或在输入框中 Ctrl+V 粘贴截图"
        $AttachmentStatus.Foreground = "#6E6E73"
    }
}

function Add-AttachmentPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $allowed = @(".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".tif", ".tiff")
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($allowed -notcontains $extension) {
        return $false
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not $script:Attachments.Contains($resolved)) {
        $script:Attachments.Add($resolved) | Out-Null
    }
    Update-AttachmentStatus
    return $true
}

function Save-ClipboardImage {
    if (-not [System.Windows.Clipboard]::ContainsImage()) {
        return $false
    }

    $image = [System.Windows.Clipboard]::GetImage()
    if ($null -eq $image) {
        return $false
    }

    $safeDialog = New-SafeId -Raw $DialogName
    $fileName = "{0}-{1}.png" -f $safeDialog, [DateTimeOffset]::Now.ToString("yyyyMMddHHmmssfff")
    $targetPath = Join-Path $AttachmentDir $fileName
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($image))
    $stream = [System.IO.File]::Open($targetPath, [System.IO.FileMode]::Create)
    try {
        $encoder.Save($stream)
    }
    finally {
        $stream.Dispose()
    }

    Add-AttachmentPath -Path $targetPath | Out-Null
    return $true
}

function Get-SelectedLabels {
    $selected = New-Object System.Collections.Generic.List[string]
    for ($idx = 0; $idx -lt $optionControls.Count; $idx++) {
        if ($optionControls[$idx].Visibility -eq "Visible" -and $optionControls[$idx].IsChecked) {
            $selected.Add([string]$optionControls[$idx].Content)
        }
    }
    return $selected.ToArray()
}

function Save-And-Close {
    if ($script:ExitAnimationStarted) {
        return
    }

    Write-ChoiceJson -Selected (Get-SelectedLabels) -CustomAnswer ($CustomInput.Text.Trim()) -OfferedOptions $optionLabels -Attachments $script:Attachments.ToArray() | Out-Null

    $script:ChoiceSaved = $true
    $script:ExitAnimationStarted = $true
    $ContinueButton.IsEnabled = $false
    $CustomInput.IsEnabled = $false
    foreach ($control in $optionControls) {
        $control.IsEnabled = $false
    }

    Write-NextStepLog @{
        event = "exit_animation_started"
        mode = $Mode
        duration_ms = $ExitAnimationDurationMs
        dialog_id = $DialogId
        choice_path = $JsonPath
    }

    $duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds($ExitAnimationDurationMs))
    $ease = New-Object Windows.Media.Animation.CubicEase
    $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseIn

    $opacityAnimation = New-Object Windows.Media.Animation.DoubleAnimation
    $opacityAnimation.From = $window.Opacity
    $opacityAnimation.To = 0
    $opacityAnimation.Duration = $duration
    $opacityAnimation.EasingFunction = $ease
    $opacityAnimation.Add_Completed({
        $window.Close()
    })

    $topAnimation = New-Object Windows.Media.Animation.DoubleAnimation
    $topAnimation.From = $window.Top
    $topAnimation.To = $window.Top - 14
    $topAnimation.Duration = $duration
    $topAnimation.EasingFunction = $ease

    $window.BeginAnimation([Windows.UIElement]::OpacityProperty, $opacityAnimation)
    $window.BeginAnimation([Windows.Window]::TopProperty, $topAnimation)
}

Update-Placeholder
Update-AttachmentStatus

$DragHeader.Add_MouseLeftButtonDown({
    try {
        $window.DragMove()
    }
    catch {
        Write-NextStepLog @{
            event = "drag_failed"
            error = $_.Exception.Message
        }
    }
})

$CustomInput.Add_TextChanged({ Update-Placeholder })
$window.AllowDrop = $true
$CustomInput.AllowDrop = $true
$dropHandler = {
    if ($_.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $files = @($_.Data.GetData([System.Windows.DataFormats]::FileDrop))
        $added = 0
        foreach ($file in $files) {
            if (Add-AttachmentPath -Path $file) {
                $added++
            }
        }
        if ($added -gt 0) {
            $_.Handled = $true
        }
    }
}
$window.Add_Drop($dropHandler)
$CustomInput.Add_Drop($dropHandler)
$ContinueButton.Add_Click({ Save-And-Close })
$window.Add_PreviewKeyDown({
    if ($_.Key -eq "V" -and ($_.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        if (Save-ClipboardImage) {
            $_.Handled = $true
            return
        }
    }
    if ($_.Key -eq "Return" -and -not ($_.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Shift)) {
        $_.Handled = $true
        Save-And-Close
    }
})
$window.Add_KeyDown({
    if ($_.Key -eq "Escape") {
        Save-And-Close
    }
})
$window.Add_Closing({
    if (-not $script:ChoiceSaved) {
        Write-ChoiceJson -Selected @() -CustomAnswer "" -OfferedOptions $optionLabels -Attachments $script:Attachments.ToArray() | Out-Null
        $script:ChoiceSaved = $true
    }
})

if ($Mode -ne "interactive") {
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($AutoDelayMs)
    $timer.Add_Tick({
        $timer.Stop()

        $visibleWindows = @([Win32WindowTools]::GetVisibleWindowsForProcess($PID))
        $helperWindows = @($visibleWindows | Where-Object { $_ -match "\|(SoPY_Status|MSCTFIME UI|IME)\|" })
        $appWindows = @($visibleWindows | Where-Object { $helperWindows -notcontains $_ })
        $blankVisibleWindows = @($appWindows | Where-Object { $_ -match "^\d+\|\|.*\|[1-9]\d*x[1-9]\d*$" })

        $testResult = @{
            mode = $Mode
            window_visible = [bool]$window.IsVisible
            checkboxes_present = [bool]($CheckStatus -and $ImproveText -and $HandleFigures -and $RunChecks)
            custom_input_present = [bool]$CustomInput
            continue_button_present = [bool]$ContinueButton
            pause_button_present = $false
            offered_options = $optionLabels
            visible_window_count = $appWindows.Count
            visible_window_titles = $visibleWindows
            helper_window_count = $helperWindows.Count
            helper_window_titles = $helperWindows
            extra_blank_window_detected = [bool]($appWindows.Count -gt 1 -or $blankVisibleWindows.Count -gt 0)
            existing_next_step_window_count = $script:ExistingNextStepWindowCount
            window_left = [int]$window.Left
            window_top = [int]$window.Top
            font_applied = $script:UiFontApplied
            font_source = $script:UiFontSource
            open_animation_enabled = $true
            open_animation_duration_ms = $OpenAnimationDurationMs
            exit_animation_enabled = $true
            exit_animation_duration_ms = $ExitAnimationDurationMs
        }

        $testResult["preview_saved"] = Save-WindowPreview -Window $window -Path $PreviewPath
        $testResult["preview_path"] = $PreviewPath

        if ($Mode -eq "test-submit") {
            $CheckStatus.IsChecked = $true
            if ($optionLabels.Count -gt 1) {
                $ImproveText.IsChecked = $true
            }
            else {
                $ImproveText.IsChecked = $false
            }
            $HandleFigures.IsChecked = $false
            $RunChecks.IsChecked = $false
            $CustomInput.Text = "自动测试自定义任务"
            Update-Placeholder
            $testResult["checkbox_toggle_verified"] = [bool]($CheckStatus.IsChecked -and -not $HandleFigures.IsChecked -and -not $RunChecks.IsChecked)
            $testResult["custom_input_verified"] = ($CustomInput.Text -eq "自动测试自定义任务")
            $testResult["dynamic_options_verified"] = ($optionLabels.Count -ge 1 -and [string]$CheckStatus.Content -eq [string]$optionLabels[0])
            Write-SelfTestResult $testResult
            Save-And-Close
        }
        elseif ($Mode -eq "test-empty") {
            $CheckStatus.IsChecked = $false
            $ImproveText.IsChecked = $false
            $HandleFigures.IsChecked = $false
            $RunChecks.IsChecked = $false
            $CustomInput.Text = ""
            Update-Placeholder
            $testResult["checkbox_toggle_verified"] = $true
            $testResult["custom_input_verified"] = $true
            $testResult["attachment_verified"] = ($script:Attachments.Count -eq 0)
            Write-SelfTestResult $testResult
            Save-And-Close
        }
        elseif ($Mode -eq "test-attach") {
            $attachPath = $TestAttachmentPath
            if ([string]::IsNullOrWhiteSpace($attachPath)) {
                $attachPath = $PreviewPath
            }
            $addedAttachment = Add-AttachmentPath -Path $attachPath
            $CustomInput.Text = "自动测试图片附件"
            Update-Placeholder
            $testResult["checkbox_toggle_verified"] = $true
            $testResult["custom_input_verified"] = ($CustomInput.Text -eq "自动测试图片附件")
            $testResult["attachment_verified"] = [bool]($addedAttachment -and $script:Attachments.Count -gt 0)
            Write-SelfTestResult $testResult
            Save-And-Close
        }
    })
    $timer.Start()
}

Write-NextStepLog @{
    event = "window_opened"
    mode = $Mode
    process_id = $PID
    wait_policy = $InteractiveWaitPolicy
    required_outer_timeout_ms = $RequiredOuterTimeoutMs
    font_applied = $script:UiFontApplied
    font_source = $script:UiFontSource
    open_animation_duration_ms = $OpenAnimationDurationMs
    exit_animation_duration_ms = $ExitAnimationDurationMs
}

[void]$window.ShowDialog()


















