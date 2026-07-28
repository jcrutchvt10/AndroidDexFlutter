' Console-free launcher → launch.ps1 → rewritedex-native\build\rewritedex-native.exe
Option Explicit
Dim sh, fso, root, script
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
script = root & "\launch.ps1"
If Not fso.FileExists(script) Then
  MsgBox "launch.ps1 was not found next to this launcher.", vbExclamation, "RewriteDEX"
  WScript.Quit 1
End If
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """", 0, False
