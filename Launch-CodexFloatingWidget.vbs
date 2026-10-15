Option Explicit

Dim shell, fso, scriptFolder, powershellPath, widgetPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptFolder = fso.GetParentFolderName(WScript.ScriptFullName)
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
widgetPath = fso.BuildPath(scriptFolder, "CodexFloatingWidget.ps1")
command = """" & powershellPath & """ -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & widgetPath & """"

shell.Run command, 0, False
