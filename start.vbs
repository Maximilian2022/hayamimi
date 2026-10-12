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

cmdLine = psCmd & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\scripts\launcher_gui.ps1"""
WshShell.Run cmdLine, 0, False
