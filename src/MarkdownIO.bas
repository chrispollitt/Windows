Attribute VB_Name = "MarkdownIO"
Option Explicit

' WordMarkdown - open and save Markdown (.md) files in Word, using Pandoc.
'
'   Open:  .md --pandoc--> temp .docx --> opened in Word (tied to the .md)
'   Save:  Word doc --> temp .docx --pandoc--> .md (previous .md kept in BAK)
'
' While a document is tied to an .md file (custom document property
' "MarkdownSource"), File > Save and Save As write Markdown instead of .docx.
' Support files live in %APPDATA%\WordMarkdown (reference.docx, filters\*.lua).

Private Const APP_KEY As String = "WordMarkdown"
Private Const PROP_SRC As String = "MarkdownSource"
Private Const BACKUPS_KEEP As Long = 3
Private Const DEF_READ As String = "gfm+footnotes+yaml_metadata_block+tex_math_dollars"
Private Const DEF_WRITE As String = "gfm+yaml_metadata_block"

Private Type OPENFILENAME
    lStructSize As Long
    hwndOwner As LongPtr
    hInstance As LongPtr
    lpstrFilter As LongPtr
    lpstrCustomFilter As LongPtr
    nMaxCustFilter As Long
    nFilterIndex As Long
    lpstrFile As LongPtr
    nMaxFile As Long
    lpstrFileTitle As LongPtr
    nMaxFileTitle As Long
    lpstrInitialDir As LongPtr
    lpstrTitle As LongPtr
    Flags As Long
    nFileOffset As Integer
    nFileExtension As Integer
    lpstrDefExt As LongPtr
    lCustData As LongPtr
    lpfnHook As LongPtr
    lpTemplateName As LongPtr
    pvReserved As LongPtr
    dwReserved As Long
    FlagsEx As Long
End Type

Private Declare PtrSafe Function GetSaveFileNameW Lib "comdlg32.dll" (ByRef ofn As OPENFILENAME) As Long
Private Declare PtrSafe Function CommDlgExtendedError Lib "comdlg32.dll" () As Long

Private gEvents As AppEvents
Private gRibbon As IRibbonUI
Private gLastLog As String
Private gBackedUp As Object

' ---------------------------------------------------------------------------
' Start-up and ribbon callbacks
' ---------------------------------------------------------------------------

Public Sub AutoExec()
    InitEvents
End Sub

Private Sub InitEvents()
    If gEvents Is Nothing Then
        Set gEvents = New AppEvents
        Set gEvents.App = Application
    End If
End Sub

Public Sub Ribbon_OnLoad(ribbon As IRibbonUI)
    Set gRibbon = ribbon
    InitEvents
End Sub

Public Sub Ribbon_Open(control As IRibbonControl)
    OpenMarkdown
End Sub

Public Sub Ribbon_Save(control As IRibbonControl)
    SaveMarkdown
End Sub

Public Sub Ribbon_SaveAs(control As IRibbonControl)
    SaveMarkdownAs
End Sub

Public Sub Ribbon_Export(control As IRibbonControl)
    ExportMarkdownCopy
End Sub

Public Sub Ribbon_SaveWord(control As IRibbonControl)
    SaveAsWord
End Sub

Public Sub Ribbon_Settings(control As IRibbonControl)
    ShowSettings
End Sub

' Called by the build script to prove that every module compiles.
Public Function SelfTest() As String
    InitEvents
    SelfTest = "OK; pandoc=" & FindPandoc(False)
End Function

' ---------------------------------------------------------------------------
' Commands
' ---------------------------------------------------------------------------

Public Sub OpenMarkdown()
    Dim mdPath As String
    mdPath = PickMarkdownFile()
    If Len(mdPath) = 0 Then Exit Sub
    OpenMarkdownFile mdPath
End Sub

Public Sub OpenMarkdownFile(ByVal mdPath As String)
    Dim work As String, docx As String, errText As String, args As String
    Dim doc As Document

    InitEvents
    PurgeOldWork
    work = NewWorkDir()
    docx = work & "\" & Fso().GetBaseName(mdPath) & ".docx"

    args = Q(mdPath) & " -f " & Opt("ReadFormat", DEF_READ) & " -t docx -o " & Q(docx) _
         & " --resource-path=." & RefArg() & FilterArg("md-to-word.lua")

    Application.StatusBar = "Converting " & Fso().GetFileName(mdPath) & " with Pandoc..."
    If Not RunPandoc(Fso().GetParentFolderName(mdPath), args, errText) Then
        Application.StatusBar = ""
        MsgBox "Pandoc could not convert the file:" & vbCrLf & vbCrLf & errText, _
               vbExclamation, "Open Markdown"
        Exit Sub
    End If

    Set doc = Documents.Open(FileName:=docx, AddToRecentFiles:=False)
    SetSource doc, mdPath
    doc.Saved = True
    ForgetBackup mdPath
    On Error Resume Next
    doc.ActiveWindow.Caption = Fso().GetFileName(mdPath)
    On Error GoTo 0
    Application.StatusBar = ""
    ShowWarnings
End Sub

' Write the active document to the .md it came from (or ask for one).
Public Sub SaveMarkdown()
    If Documents.Count = 0 Then Exit Sub
    SaveMarkdownDoc ActiveDocument, False, True
End Sub

' Choose a new .md file; the document becomes tied to it.
Public Sub SaveMarkdownAs()
    If Documents.Count = 0 Then Exit Sub
    SaveMarkdownDoc ActiveDocument, True, True
End Sub

' Write a Markdown copy of any document; the document stays as it is.
Public Sub ExportMarkdownCopy()
    If Documents.Count = 0 Then Exit Sub
    SaveMarkdownDoc ActiveDocument, True, False
End Sub

' Untie the document from its .md file and show Word's normal Save As.
Public Sub SaveAsWord()
    Dim doc As Document, src As String
    If Documents.Count = 0 Then Exit Sub
    Set doc = ActiveDocument
    src = GetSource(doc)
    ClearSource doc
    If Application.Dialogs(wdDialogFileSaveAs).Show <> -1 Then
        If Len(src) > 0 Then SetSource doc, src
    Else
        On Error Resume Next
        doc.ActiveWindow.Caption = ""
        On Error GoTo 0
    End If
End Sub

Public Sub ShowSettings()
    Dim v As String

    v = InputBox("Full path to pandoc.exe." & vbCrLf & "Leave blank to auto-detect." & vbCrLf & _
                 "(Cancel keeps all current settings.)", _
                 "WordMarkdown settings (1 of 4)", Opt("PandocPath", ""))
    If StrPtr(v) = 0 Then Exit Sub
    SetOpt "PandocPath", Trim$(v)

    v = InputBox("Pandoc format used when READING Markdown." & vbCrLf & "Blank = " & DEF_READ, _
                 "WordMarkdown settings (2 of 4)", Opt("ReadFormat", DEF_READ))
    If StrPtr(v) = 0 Then Exit Sub
    If Len(Trim$(v)) = 0 Then v = DEF_READ
    SetOpt "ReadFormat", Trim$(v)

    v = InputBox("Pandoc format used when WRITING Markdown." & vbCrLf & "Blank = " & DEF_WRITE, _
                 "WordMarkdown settings (3 of 4)", Opt("WriteFormat", DEF_WRITE))
    If StrPtr(v) = 0 Then Exit Sub
    If Len(Trim$(v)) = 0 Then v = DEF_WRITE
    SetOpt "WriteFormat", Trim$(v)

    v = InputBox("Line endings for NEW Markdown files: lf or crlf." & vbCrLf & _
                 "(Existing files keep the line endings they already have.)", _
                 "WordMarkdown settings (4 of 4)", Opt("DefaultEol", "lf"))
    If StrPtr(v) = 0 Then Exit Sub
    v = LCase$(Trim$(v))
    If v <> "crlf" Then v = "lf"
    SetOpt "DefaultEol", v
End Sub

' ---------------------------------------------------------------------------
' Save logic (also called from the BeforeSave event)
' ---------------------------------------------------------------------------

Public Function IsMarkdownDoc(ByVal doc As Document) As Boolean
    IsMarkdownDoc = (Len(GetSource(doc)) > 0)
End Function

Public Sub SaveMarkdownDoc(ByVal doc As Document, ByVal askPath As Boolean, ByVal bind As Boolean)
    Dim target As String, cur As String

    cur = GetSource(doc)
    If bind Then target = cur
    If askPath Or Len(target) = 0 Then
        target = AskSavePath(DefaultName(doc, cur))
        If Len(target) = 0 Then Exit Sub
    End If

    If Not WriteMarkdown(doc, target) Then Exit Sub

    If bind Then
        SetSource doc, target
        doc.Saved = True
        On Error Resume Next
        doc.ActiveWindow.Caption = Fso().GetFileName(target)
        On Error GoTo 0
    End If
    Application.StatusBar = "Saved " & target
    ShowWarnings
End Sub

Private Function WriteMarkdown(ByVal doc As Document, ByVal target As String) As Boolean
    Dim work As String, tmpDocx As String, tmpMd As String
    Dim folder As String, base As String, args As String, errText As String

    folder = Fso().GetParentFolderName(target)
    base = Fso().GetBaseName(target)
    work = NewWorkDir()
    tmpDocx = work & "\" & base & ".docx"
    tmpMd = work & "\" & base & ".md"

    Application.StatusBar = "Converting to Markdown with Pandoc..."
    If Not ExportDocx(doc, tmpDocx) Then
        Application.StatusBar = ""
        Exit Function
    End If

    args = Q(tmpDocx) & " -f docx+styles -t " & Opt("WriteFormat", DEF_WRITE) _
         & " -s --wrap=none --eol=" & DetectEol(target) _
         & " --extract-media=" & Q(base & "-media") _
         & FilterArg("word-to-md.lua") & " -o " & Q(tmpMd)

    If Not RunPandoc(folder, args, errText) Then
        Application.StatusBar = ""
        MsgBox "Pandoc could not convert the document. Nothing was written." & vbCrLf & vbCrLf & _
               errText, vbExclamation, "Save Markdown"
        Exit Function
    End If

    On Error GoTo CopyFail
    BackupOnce target
    Fso().CopyFile tmpMd, target, True
    WriteMarkdown = True
    Exit Function

CopyFail:
    Application.StatusBar = ""
    MsgBox "Could not write " & target & vbCrLf & vbCrLf & Err.Description, _
           vbExclamation, "Save Markdown"
End Function

' Save a copy of the document as .docx without touching the original.
Private Function ExportDocx(ByVal doc As Document, ByVal path As String) As Boolean
    Dim tmp As Document

    On Error GoTo Fail
    Set tmp = Documents.Add(Visible:=False)
    tmp.Content.FormattedText = doc.Content.FormattedText
    tmp.SaveAs2 FileName:=path, FileFormat:=wdFormatXMLDocument, AddToRecentFiles:=False
    tmp.Close SaveChanges:=wdDoNotSaveChanges
    ExportDocx = True
    Exit Function

Fail:
    MsgBox "Could not prepare a temporary copy of the document:" & vbCrLf & vbCrLf & _
           Err.Description, vbExclamation, "Save Markdown"
    On Error Resume Next
    If Not tmp Is Nothing Then tmp.Close SaveChanges:=wdDoNotSaveChanges
End Function

' ---------------------------------------------------------------------------
' Pandoc
' ---------------------------------------------------------------------------

Private Function RunPandoc(ByVal workDir As String, ByVal args As String, _
                           ByRef errText As String) As Boolean
    Dim exe As String, logPath As String, inner As String, rc As Long

    gLastLog = ""
    exe = FindPandoc(True)
    If Len(exe) = 0 Then
        errText = "Pandoc was not found. Install it from https://pandoc.org or set its path in Markdown > Settings."
        Exit Function
    End If

    EnsureFolder WorkRoot()
    logPath = WorkRoot() & "\pandoc-" & Format$(Now, "hhnnss") & "-" & CStr(Int(Rnd * 10000)) & ".log"
    inner = "cd /d " & Q(workDir) & " && " & Q(exe) & " " & args & " 2> " & Q(logPath)
    rc = CreateObject("WScript.Shell").Run("cmd.exe /d /c " & Q(inner), 0, True)

    errText = ReadTextFile(logPath)
    gLastLog = errText
    On Error Resume Next
    Kill logPath
    On Error GoTo 0

    If rc <> 0 Then
        If Len(Trim$(errText)) = 0 Then errText = "Pandoc exited with code " & rc & "."
        gLastLog = ""
    End If
    RunPandoc = (rc = 0)
End Function

Private Function FindPandoc(ByVal interactive As Boolean) As String
    Dim f As Object, p As String, dirs() As String, i As Long, c As Variant

    Set f = Fso()
    p = Opt("PandocPath", "")
    If Len(p) > 0 Then
        If f.FileExists(p) Then
            FindPandoc = p
            Exit Function
        End If
    End If

    dirs = Split(Environ$("PATH"), ";")
    For i = LBound(dirs) To UBound(dirs)
        p = Trim$(Replace(dirs(i), """", ""))
        If Len(p) > 0 Then
            If Right$(p, 1) <> "\" Then p = p & "\"
            p = p & "pandoc.exe"
            If f.FileExists(p) Then
                FindPandoc = p
                Exit Function
            End If
        End If
    Next i

    For Each c In Array(Environ$("LOCALAPPDATA") & "\Pandoc\pandoc.exe", _
                        Environ$("ProgramFiles") & "\Pandoc\pandoc.exe", _
                        Environ$("ProgramFiles(x86)") & "\Pandoc\pandoc.exe")
        If f.FileExists(CStr(c)) Then
            FindPandoc = CStr(c)
            Exit Function
        End If
    Next c

    If interactive Then
        MsgBox "Pandoc (pandoc.exe) was not found. Please locate it.", vbInformation, "WordMarkdown"
        With Application.FileDialog(msoFileDialogFilePicker)
            .Title = "Locate pandoc.exe"
            .AllowMultiSelect = False
            .Filters.Clear
            .Filters.Add "pandoc.exe", "pandoc.exe"
            If .Show = -1 Then
                p = .SelectedItems(1)
                SetOpt "PandocPath", p
                FindPandoc = p
            End If
        End With
    End If
End Function

Private Function RefArg() As String
    Dim r As String
    r = SupportDir() & "\reference.docx"
    If Fso().FileExists(r) Then RefArg = " --reference-doc=" & Q(r)
End Function

Private Function FilterArg(ByVal fileName As String) As String
    Dim p As String
    p = SupportDir() & "\filters\" & fileName
    If Fso().FileExists(p) Then FilterArg = " --lua-filter=" & Q(p)
End Function

Private Sub ShowWarnings()
    If Len(Trim$(gLastLog)) > 0 Then
        MsgBox "Pandoc reported:" & vbCrLf & vbCrLf & Left$(gLastLog, 1500), _
               vbInformation, "WordMarkdown"
    End If
    gLastLog = ""
End Sub

' ---------------------------------------------------------------------------
' Document property that ties a Word document to its .md file
' ---------------------------------------------------------------------------

Private Function GetSource(ByVal doc As Document) As String
    On Error Resume Next
    GetSource = CStr(doc.CustomDocumentProperties(PROP_SRC).Value)
End Function

Private Sub SetSource(ByVal doc As Document, ByVal mdPath As String)
    Dim props As Object
    Set props = doc.CustomDocumentProperties
    On Error Resume Next
    props(PROP_SRC).Delete
    On Error GoTo 0
    props.Add Name:=PROP_SRC, LinkToContent:=False, Type:=msoPropertyTypeString, Value:=mdPath
End Sub

Private Sub ClearSource(ByVal doc As Document)
    On Error Resume Next
    doc.CustomDocumentProperties(PROP_SRC).Delete
End Sub

' ---------------------------------------------------------------------------
' Dialogs and paths
' ---------------------------------------------------------------------------

Private Function PickMarkdownFile() As String
    With Application.FileDialog(msoFileDialogFilePicker)
        .Title = "Open Markdown"
        .AllowMultiSelect = False
        .Filters.Clear
        .Filters.Add "Markdown files", "*.md;*.markdown;*.mdown;*.mkd;*.txt"
        .Filters.Add "All files", "*.*"
        If .Show = -1 Then PickMarkdownFile = .SelectedItems(1)
    End With
End Function

' Windows' own Save dialog (comdlg32) with a Markdown file-type filter.
' Word's FileDialog(msoFileDialogSaveAs) cannot offer one: it insists on
' "Word Document (*.docx)" and appends .docx to whatever is typed.
Private Function AskSavePath(ByVal suggested As String) As String
    Dim ofn As OPENFILENAME
    Dim buf As String, flt As String, ttl As String, ext As String, dir As String, nm As String
    Dim p As String, k As Long, rc As Long

    k = InStrRev(suggested, "\")
    If k > 0 Then
        dir = Left$(suggested, k - 1)
        nm = Mid$(suggested, k + 1)
    Else
        nm = suggested
        dir = Application.Options.DefaultFilePath(wdDocumentsPath)
    End If
    If Right$(LCase$(nm), 5) = ".docx" Then nm = Left$(nm, Len(nm) - 5)
    If Not IsMdExt(nm) Then nm = nm & ".md"

    buf = nm & String$(1040 - Len(nm), vbNullChar)
    flt = "Markdown (*.md;*.markdown)" & vbNullChar & "*.md;*.markdown" & vbNullChar & _
          "All files (*.*)" & vbNullChar & "*.*" & vbNullChar & vbNullChar
    ttl = "Save as Markdown"
    ext = "md"

    On Error GoTo Fallback
    With ofn
        .lStructSize = LenB(ofn)
        On Error Resume Next
        .hwndOwner = Application.ActiveWindow.Hwnd
        On Error GoTo Fallback
        .lpstrFilter = StrPtr(flt)
        .nFilterIndex = 1
        .lpstrFile = StrPtr(buf)
        .nMaxFile = 1040
        .lpstrInitialDir = StrPtr(dir)
        .lpstrTitle = StrPtr(ttl)
        .lpstrDefExt = StrPtr(ext)
        .Flags = &H2 Or &H4 Or &H8 Or &H800 Or &H80000   ' overwrite prompt, hide read-only, no chdir, path must exist, explorer
    End With
    rc = GetSaveFileNameW(ofn)
    If rc = 0 Then
        If CommDlgExtendedError() = 0 Then Exit Function    ' cancelled
        GoTo Fallback
    End If
    k = InStr(buf, vbNullChar)
    If k > 0 Then p = Left$(buf, k - 1) Else p = buf
    AskSavePath = NormalizeMdPath(p)
    Exit Function

Fallback:
    On Error GoTo 0
    With Application.FileDialog(msoFileDialogSaveAs)
        .Title = "Save as Markdown (a .md extension is added)"
        .InitialFileName = dir & "\" & nm
        If .Show <> -1 Then Exit Function
        p = .SelectedItems(1)
    End With
    AskSavePath = NormalizeMdPath(p)
End Function

Private Function DefaultName(ByVal doc As Document, ByVal cur As String) As String
    If Len(cur) > 0 Then
        DefaultName = cur
    ElseIf Len(doc.Path) > 0 Then
        DefaultName = doc.Path & "\" & Fso().GetBaseName(doc.Name) & ".md"
    Else
        DefaultName = "Document.md"
    End If
End Function

Private Function IsMdExt(ByVal fileName As String) As Boolean
    Dim dot As Long, e As String
    dot = InStrRev(fileName, ".")
    If dot = 0 Then Exit Function
    e = LCase$(Mid$(fileName, dot + 1))
    IsMdExt = (e = "md" Or e = "markdown" Or e = "mdown" Or e = "mkd" Or e = "txt")
End Function

' Markdown commands always write Markdown: a trailing ".docx" (added by a
' fallback dialog, or typed) is dropped and ".md" added if there is no
' Markdown extension.  Use "Save as Word (.docx)" for Word files.
Private Function NormalizeMdPath(ByVal p As String) As String
    If LCase$(Right$(p, 5)) = ".docx" Then p = Left$(p, Len(p) - 5)
    If Not IsMdExt(p) Then p = p & ".md"
    NormalizeMdPath = p
End Function

' ---------------------------------------------------------------------------
' Backups of the .md being overwritten (3 newest kept, in BAK\ next to it)
' ---------------------------------------------------------------------------

Private Sub BackupOnce(ByVal path As String)
    Dim key As String

    If gBackedUp Is Nothing Then Set gBackedUp = CreateObject("Scripting.Dictionary")
    key = LCase$(path)
    If gBackedUp.Exists(key) Then Exit Sub
    gBackedUp.Add key, True
    If Fso().FileExists(path) Then BackupFile path
End Sub

Private Sub ForgetBackup(ByVal path As String)
    If gBackedUp Is Nothing Then Exit Sub
    If gBackedUp.Exists(LCase$(path)) Then gBackedUp.Remove LCase$(path)
End Sub

Private Sub BackupFile(ByVal path As String)
    Dim f As Object, fl As Object, bdir As String, prefix As String
    Dim names() As String, cnt As Long, i As Long, j As Long, tmp As String

    Set f = Fso()
    bdir = f.GetParentFolderName(path) & "\BAK"
    EnsureFolder bdir
    f.CopyFile path, bdir & "\" & f.GetFileName(path) & ".bak-" & Format$(Now, "yyyymmdd-hhnnss"), True

    On Error Resume Next
    prefix = LCase$(f.GetFileName(path)) & ".bak-"
    ReDim names(0 To 0)
    For Each fl In f.GetFolder(bdir).Files
        If LCase$(Left$(fl.Name, Len(prefix))) = prefix Then
            ReDim Preserve names(0 To cnt)
            names(cnt) = fl.Name
            cnt = cnt + 1
        End If
    Next fl
    For i = 0 To cnt - 2
        For j = i + 1 To cnt - 1
            If names(j) > names(i) Then
                tmp = names(i)
                names(i) = names(j)
                names(j) = tmp
            End If
        Next j
    Next i
    For i = BACKUPS_KEEP To cnt - 1
        f.DeleteFile bdir & "\" & names(i), True
    Next i
End Sub

' Keep the line endings the file already has.
Private Function DetectEol(ByVal path As String) As String
    Dim n As Integer, buf As String, take As Long

    DetectEol = Opt("DefaultEol", "lf")
    If Not Fso().FileExists(path) Then Exit Function
    On Error GoTo Done
    n = FreeFile
    Open path For Binary Access Read As #n
    take = LOF(n)
    If take > 8192 Then take = 8192
    If take > 0 Then
        buf = Space$(take)
        Get #n, , buf
        If InStr(buf, vbCrLf) > 0 Then
            DetectEol = "crlf"
        ElseIf InStr(buf, vbLf) > 0 Then
            DetectEol = "lf"
        End If
    End If
Done:
    On Error Resume Next
    Close #n
End Function

' ---------------------------------------------------------------------------
' Small helpers
' ---------------------------------------------------------------------------

Private Function Q(ByVal s As String) As String
    Q = """" & s & """"
End Function

Private Function Fso() As Object
    Set Fso = CreateObject("Scripting.FileSystemObject")
End Function

Private Function Opt(ByVal optName As String, ByVal def As String) As String
    Opt = GetSetting(APP_KEY, "Options", optName, def)
End Function

Private Sub SetOpt(ByVal optName As String, ByVal optValue As String)
    SaveSetting APP_KEY, "Options", optName, optValue
End Sub

Private Function SupportDir() As String
    SupportDir = Environ$("APPDATA") & "\WordMarkdown"
End Function

Private Function WorkRoot() As String
    WorkRoot = Environ$("LOCALAPPDATA") & "\WordMarkdown\work"
End Function

Private Sub EnsureFolder(ByVal path As String)
    Dim f As Object, parent As String
    Set f = Fso()
    If f.FolderExists(path) Then Exit Sub
    parent = f.GetParentFolderName(path)
    If Len(parent) > 0 Then
        If Not f.FolderExists(parent) Then EnsureFolder parent
    End If
    f.CreateFolder path
End Sub

Private Function NewWorkDir() As String
    Dim p As String
    Randomize
    p = WorkRoot() & "\" & Format$(Now, "yyyymmdd_hhnnss") & "_" & CStr(Int(Rnd * 100000))
    EnsureFolder p
    NewWorkDir = p
End Function

Private Sub PurgeOldWork()
    Dim f As Object, d As Object
    On Error Resume Next
    Set f = Fso()
    If Not f.FolderExists(WorkRoot()) Then Exit Sub
    For Each d In f.GetFolder(WorkRoot()).SubFolders
        If DateDiff("d", d.DateCreated, Now) > 3 Then d.Delete True
    Next d
End Sub

Private Function ReadTextFile(ByVal path As String) As String
    Dim n As Integer, s As String, take As Long

    If Not Fso().FileExists(path) Then Exit Function
    On Error GoTo Done
    n = FreeFile
    Open path For Binary Access Read As #n
    take = LOF(n)
    If take > 4000 Then take = 4000
    If take > 0 Then
        s = Space$(take)
        Get #n, , s
        ReadTextFile = s
    End If
Done:
    On Error Resume Next
    Close #n
End Function
