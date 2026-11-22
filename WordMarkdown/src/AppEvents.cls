VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
END
Attribute VB_Name = "AppEvents"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
Option Explicit

' Catches File > Save / Save As / Ctrl+S for documents that are tied to a
' Markdown file and writes Markdown instead of .docx.

Public WithEvents App As Word.Application

Private Sub App_DocumentBeforeSave(ByVal Doc As Document, SaveAsUI As Boolean, Cancel As Boolean)
    If Not MarkdownIO.IsMarkdownDoc(Doc) Then Exit Sub
    Cancel = True
    MarkdownIO.SaveMarkdownDoc Doc, SaveAsUI, True
End Sub
