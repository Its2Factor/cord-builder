Option Explicit

Dim shell, fileSystem, scriptDirectory, appScript, command, exitCode
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
appScript = fileSystem.BuildPath(scriptDirectory, "VencordEquicordBuilder.ps1")
shell.CurrentDirectory = scriptDirectory

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & appScript & Chr(34)
If WScript.Arguments.Named.Exists("SelfTest") Then
    command = command & " -SelfTest"
End If
exitCode = shell.Run(command, 0, True)

If exitCode <> 0 Then
    MsgBox "Cord Builder exited with error code " & exitCode & ".", vbExclamation, "Cord Builder"
End If

WScript.Quit exitCode
