Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.CurrentDirectory = scriptDir

' PowerShell 7 (pwsh) が存在するかチェック、なければ Windows PowerShell (powershell)
psCmd = "powershell"
If fso.FileExists("C:\Program Files\PowerShell\7\pwsh.exe") Then
    psCmd = """C:\Program Files\PowerShell\7\pwsh.exe"""
ElseIf fso.FileExists("C:\Program Files (x86)\PowerShell\7\pwsh.exe") Then
    psCmd = """C:\Program Files (x86)\PowerShell\7\pwsh.exe"""
Else
    Dim pathEnv, paths, p
    pathEnv = WshShell.ExpandEnvironmentStrings("%PATH%")
    paths = Split(pathEnv, ";")
    For Each p In paths
        If p <> "" And fso.FolderExists(p) Then
            If fso.FileExists(fso.BuildPath(p, "pwsh.exe")) Then
                psCmd = "pwsh"
                Exit For
            End If
        End If
    Next
End If

' launcher_gui.ps1 のパス確認 (二重ネスト時もフォールバック検出)
targetScript = scriptDir & "\scripts\launcher_gui.ps1"
If Not fso.FileExists(targetScript) Then
    If fso.FileExists(scriptDir & "\scripts\scripts\launcher_gui.ps1") Then
        targetScript = scriptDir & "\scripts\scripts\launcher_gui.ps1"
    Else
        MsgBox "ランチャーの起動スクリプトが見つかりませんでした:" & vbCrLf & _
               scriptDir & "\scripts\launcher_gui.ps1" & vbCrLf & vbCrLf & _
               "フォルダ階層またはファイルの存在を確認してください。", _
               vbCritical, "hayamimi 起動エラー"
        WScript.Quit 1
    End If
End If

cmdLine = psCmd & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & targetScript & """"

On Error Resume Next
WshShell.Run cmdLine, 0, False
If Err.Number <> 0 Then
    MsgBox "ランチャーの起動に失敗しました (エラーコード: " & Err.Number & "):" & vbCrLf & _
           Err.Description & vbCrLf & vbCrLf & _
           "コマンドライン: " & cmdLine, _
           vbCritical, "hayamimi 起動エラー"
    WScript.Quit Err.Number
End If
