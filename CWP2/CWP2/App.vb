' ********************************************************
' * Draw a CWP! image like I did on the Apple ][ in 1985 *
' ********************************************************

Option Strict Off
Option Explicit On

' We want all of the following:
' 1. Fast 
' 2. Smooth
' 3. Works for entire run (from DrawCWP to RandomReverse)
' 4. No crashes (ideally with no discarded exceptions)
' 5. Responsive UI

Imports System.Threading

Public Class App

    '~~~~ Forms designer ~~~~~~~~~~~~~~~~~~
    'App.vb
    '  Layout
    '    Size
    '      Width  1500   ' This is a magic number
    '      Height  750   ' This is a magic number
    '~~~~ Auto generated code
    'Partial Class App
    '  InitializeComponent()
    '    Me.PictureBox1.Size = New System.Drawing.Size(1484, 712) ' 1484 is 1500 - window decorations
    '    Me.ClientSize       = New System.Drawing.Size(1484, 712) '  712 is  750 - window decorations
    '~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    ' Declare globals
    Shared ImgWidth As Integer
    Shared ImgHeight As Integer
    Shared bImage As Bitmap
    Shared gCanvas As Graphics
    Shared pDrawingPen As Pen
    Shared Box As Hashtable = New Hashtable
    Shared CWPHeight, CWPWidth, CWPTop, CWPLeft, Thickness As Integer
    Shared Count As Integer
    Shared Interval As Integer

    ' Main block
    Sub Main()

        ' init vars
        ImgWidth = PictureBox1.Size.Width
        ImgHeight = PictureBox1.Size.Height
        bImage = New Bitmap(ImgWidth, ImgHeight)
        gCanvas = Graphics.FromImage(bImage)
        pDrawingPen = New Pen(Color.White, 1)

        ' Size Constants
        CWPHeight = Math.Floor(ImgHeight * 0.4) ' The "0.4"  is a magic number
        CWPWidth = Math.Floor(ImgWidth * 0.6)   ' The "0.6"  is a magic number and is wrong (see hack below)
        Thickness = Math.Floor(CWPWidth * 0.06) ' The "0.06" is a magic number

        ' Calculated
        CWPTop = Math.Floor((ImgHeight - CWPHeight) / 2)
        CWPLeft = Math.Floor((ImgWidth - CWPWidth) / 2) + Thickness ' The "+ Thickness" is a hack

        ' Init other vars
        Count = 0
        Interval = 3

        'Clear The Canvas
        gCanvas.Clear(Color.Black)

        'Set The Images To The In-Memory Image Object
        PictureBox1.Image = bImage
        PictureBox1.Refresh()

        ' Draw CWP!
        DrawCWP()

        ' call drawbox and random reverse
        DrawBox()
        RandomReverse()

    End Sub

    ' Slow down drawing
    Sub DoRefresh()
        Count += 1
        If (Count Mod Interval = 0) Then
            PictureBox1.Refresh()
        End If
    End Sub

    Sub Sleep(sec As Decimal)
        System.Threading.Thread.Sleep(sec * 1000)
    End Sub

    ' Draw line
    Sub DrawLine(x1 As Integer, y1 As Integer, x2 As Integer, y2 As Integer)
        Try
            gCanvas.DrawLine(pDrawingPen, x1, y1, x2, y2)
        Catch ex As Exception
        End Try
    End Sub

    Sub DrawLine(p1 As Point, p2 As Point)
        Try
            gCanvas.DrawLine(pDrawingPen, p1, p2)
        Catch ex As Exception
        End Try
    End Sub

    ' Draw CWP!
    Sub DrawCWP()
        Dim r, x0, x1, x2, y0, y1, y2 As Integer
        Dim x1p, x2p, y1p, y2p As Integer
        Dim a As Decimal

        Sleep(2)
        ' -----------------------C--------------------

        ' Bottom arm of "C"
        x1 = CWPLeft + (Thickness * 3) - 2 ' the "+ (Thickness * 3)" is a magic number as is wrong
        y1 = CWPTop + CWPHeight
        x2 = x1
        y2 = y1 - Thickness
        For a = Thickness - 2 To 0 Step -1
            DrawLine(x1 + a, y1, x2 + a, y2)
            DoRefresh()
        Next

        ' Curve of "C"
        r = CWPHeight / 2
        x0 = CWPLeft + (Thickness * 3) ' the "+ (Thickness * 3)" is a magic number from above
        y0 = CWPTop + CWPHeight - r
        x1 = -1
        For a = 2 * Math.PI To Math.PI Step -0.007 ' The "-0.007" is a  magic number
            x1p = x1
            x2p = x2
            y1p = y1
            y2p = y2
            x1 = x0 + r * Math.Sin(a)
            y1 = y0 + r * Math.Cos(a)
            x2 = x0 + (r - Thickness) * Math.Sin(a)
            y2 = y0 + (r - Thickness) * Math.Cos(a)
            DrawLine(x1, y1, x2, y2)
            If x1p <> -1 Then
                DrawLine(x1, y1, x2p, y2p)
                DrawLine(x1p, y1p, x2, y2)
                DrawLine(x1, y1p, x2p, y2)
                DrawLine(x1p, y1, x2, y2p)
                DrawLine(x1, y1p, x2, y2p)
                DrawLine(x1p, y1, x2p, y2)
            End If
            DoRefresh()
        Next

        ' Top arm of "C"
        x1 = CWPLeft + (Thickness * 3) ' the "+ (Thickness * 3)" is a magic number from above
        y1 = CWPTop
        x2 = x1
        y2 = y1 + Thickness
        For a = 0 To Thickness
            DrawLine(x1 + a, y1, x2 + a, y2)
            DoRefresh()
        Next

        ' -----------------------W--------------------

        ' 1st arm of "W" (down)
        x1 = CWPLeft + (Thickness * 4)
        y1 = CWPTop
        x2 = x1 + Thickness
        y2 = y1
        For a = 0 To CWPHeight
            DrawLine(x1, y1 + a, x2, y2 + a)
            DoRefresh()
        Next

        ' 2nd arm of "W" (diagonal up)
        x1 = CWPLeft + (Thickness * 5)
        y1 = CWPTop + CWPHeight
        x2 = x1 - Math.Floor(Thickness / Math.Sqrt(2))
        y2 = y1 - Math.Floor(Thickness / Math.Sqrt(2))
        Dim magicW = 1.65                                        ' 1.65 is a magic number
        For a = 0 To Thickness * magicW                          ' 1.65 is a magic number
            DrawLine(x1 + a - 1, y1 - a, x2 + a - 1, y2 - a)
            DoRefresh()
            DrawLine(x1 + a, y1 - a, x2 + a, y2 - a)
            DoRefresh()
        Next

        ' 3rd arm of "W" (middle bridge)
        x1 = CWPLeft + (Thickness * 5.95)                      ' 5.95 is a magic number
        y1 = CWPTop + CWPHeight - Math.Floor(Thickness * magicW) ' 1.65 is a magic number from above
        x2 = x1
        y2 = y1 - Math.Floor(Thickness / Math.Sqrt(2))
        For a = 0 To (Thickness * 1.12)                        ' 1.12 is a magic number
            DrawLine(x1 + a, y1, x2 + a, y2)
            DoRefresh()
        Next

        ' 4th arm of "W" (diagonal down)
        x1 = CWPLeft + (Thickness * 6.35)                      ' 6.35 is a magic number
        y1 = CWPTop + CWPHeight - Math.Floor(Thickness * magicW) ' 1.65 is a magic number from above
        x2 = x1 + Math.Floor(Thickness / Math.Sqrt(2))
        y2 = y1 - Math.Floor(Thickness / Math.Sqrt(2))
        For a = 0 To Thickness * magicW                          ' 1.65 is a magic number from above
            DrawLine(x1 + a - 1, y1 + a, x2 + a - 1, y2 + a)
            DoRefresh()
            DrawLine(x1 + a, y1 + a, x2 + a, y2 + a)
            DoRefresh()
        Next

        ' 5th arm of "W" (up)
        x1 = CWPLeft + (Thickness * 8)
        y1 = CWPTop
        x2 = x1 + Thickness
        y2 = y1
        For a = CWPHeight To 0 Step -1
            DrawLine(x1, y1 + a, x2, y2 + a)
            DoRefresh()
        Next

        ' -----------------------P--------------------

        ' Top arm of "P"
        x1 = CWPLeft + (Thickness * 9)
        y1 = CWPTop
        x2 = x1
        y2 = y1 + Thickness
        For a = 0 To Thickness
            DrawLine(x1 + a, y1, x2 + a, y2)
            DoRefresh()
        Next

        ' Curve
        r = CWPHeight / 3
        x0 = CWPLeft + (Thickness * 10)
        y0 = CWPTop + r
        x1 = -1
        For a = Math.PI To 0 Step -0.009 ' -0.009 is a magic number
            x1p = x1
            x2p = x2
            y1p = y1
            y2p = y2
            x1 = x0 + r * Math.Sin(a)
            y1 = y0 + r * Math.Cos(a)
            x2 = x0 + (r - Thickness) * Math.Sin(a)
            y2 = y0 + (r - Thickness) * Math.Cos(a)
            DrawLine(x1, y1, x2, y2)
            If x1p <> -1 Then
                DrawLine(x1, y1, x2p, y2p)
                DrawLine(x1p, y1p, x2, y2)
                DrawLine(x1, y1p, x2p, y2)
                DrawLine(x1p, y1, x2, y2p)
                DrawLine(x1, y1p, x2, y2p)
                DrawLine(x1p, y1, x2p, y2)
            End If
            DoRefresh()
        Next

        ' Bottom arm of "P"
        r = CWPHeight / 3
        x1 = CWPLeft + (Thickness * 9)
        y1 = CWPTop + r * 2
        x2 = x1
        y2 = y1 - Thickness
        For a = Thickness To 4 Step -1
            DrawLine(x1 + a, y1, x2 + a, y2)
            DoRefresh()
        Next

        ' -----------------------!--------------------

        ' The "!"
        x1 = CWPLeft + CWPWidth - Thickness * 4.8
        y1 = CWPTop
        x2 = x1 + Thickness
        y2 = y1
        For a = 0 To CWPHeight
            If (a < (CWPHeight - Thickness - 10)) Or (a > (CWPHeight - Thickness)) Then
                DrawLine(x1, y1 + a, x2, y2 + a)
            End If
            DoRefresh()
        Next
        ' --------------------------------------------
    End Sub

    ' Draw boxes
    Sub DrawBox()
        Dim a, offset As Integer
        Dim BoxRatio As Decimal

        ' sleep for 2 sec
        Sleep(2)

        ' ~~~~Image

        Box("I00") = New Point(0, 0)
        Box("I11") = New Point(ImgWidth - 1, ImgHeight - 1)
        Box("I01") = New Point(Box("I00").x, Box("I11").y)
        Box("I10") = New Point(Box("I11").x, Box("I00").y)

        ' ~~~~Large Box

        Box("L00") = New Point(CWPLeft, CWPTop - Thickness)
        Box("L11") = New Point(Box("L00").x + CWPWidth - Thickness * 3, Box("L00").y + CWPHeight + Thickness * 2)
        Box("L01") = New Point(Box("L00").x, Box("L11").y)
        Box("L10") = New Point(Box("L11").x, Box("L00").y)
        Box("LDB") = 6
        Box("LDE") = 30
        Box("LDS") = 6
        ' top
        DrawLine(Box("L00"), Box("L10"))
        ' bottom
        DrawLine(Box("L01"), Box("L11"))
        ' left
        DrawLine(Box("L00"), Box("L01"))
        ' right
        DrawLine(Box("L10"), Box("L11"))
        ' ratio
        BoxRatio = (CWPHeight + Thickness * 2) / (CWPWidth - Thickness * 3)

        ' ~~~~~Small Box

        Box("S00") = New Point(0 + Thickness, 0 + Thickness)
        Box("S11") = New Point(Box("S00").x + Thickness * 2, Box("S00").y + Thickness * 2 * BoxRatio)
        Box("S01") = New Point(Box("S00").x, Box("S11").y)
        Box("S10") = New Point(Box("S11").x, Box("S00").y)
        Box("SDB") = 4
        Box("SDE") = 12
        Box("SDS") = 4
        ' top
        DrawLine(Box("S00"), Box("S10"))
        ' bottom
        DrawLine(Box("S01"), Box("S11"))
        ' left
        DrawLine(Box("S00"), Box("S01"))
        ' right
        DrawLine(Box("S10"), Box("S11"))

        '~~~~~~ diag lines
        ' 00
        DrawLine(Box("S00"), Box("L00"))
        ' 01
        DrawLine(Box("S01"), Box("L01"))
        ' 10
        DrawLine(Box("S10"), Box("L10"))
        ' 11
        offset = (CWPWidth - Thickness * 3 + Box("LDE")) * -1
        DrawLine(Box("S11"), New Point(Box("L11").x + offset, CalcO(Box("S11"), Box("L11"), offset, False)))

        '~~~~~ small depth
        For a = Box("SDB") To Box("SDE") Step Box("SDS")
            offset = a
            ' right
            DrawLine(
              New Point(Box("S10").x + offset, CalcO(Box("S10"), Box("L10"), offset, False)),
              New Point(Box("S10").x + offset, CalcO(Box("S11"), Box("L11"), offset, False))
            )
            ' bottom
            offset = offset * ((Box("L11").Y - Box("S11").Y) / (Box("L11").X - Box("S11").X)) ' 2.105263 ' 11 ratio
            DrawLine(
              New Point(CalcO(Box("S01"), Box("L01"), offset, True), Box("S01").y + offset),
              New Point(CalcO(Box("S11"), Box("L11"), offset, True), Box("S01").y + offset)
            )
        Next

        '~~~~~ big depth
        For a = Box("LDB") To Box("LDE") Step Box("LDS")
            offset = a * -1
            ' left
            DrawLine(
              New Point(Box("L00").x + offset, CalcO(Box("S00"), Box("L00"), offset, False)),
              New Point(Box("L00").x + offset, CalcO(Box("S01"), Box("L01"), offset, False))
            )
            ' top
            offset = offset * ((Box("L00").Y - Box("S00").Y) / (Box("L00").X - Box("S00").X)) ' 2.688 ' 00 ratio
            DrawLine(
              New Point(CalcO(Box("S00"), Box("L00"), offset, True), Box("L00").y + offset),
              New Point(CalcO(Box("S10"), Box("L10"), offset, True), Box("L00").y + offset)
            )
        Next

        ' update picbox
        PictureBox1.Refresh()

    End Sub

    Function CalcO(first As Point, last As Point, offsetIn As Integer, IsX As Boolean) As Integer
        Dim ratio As Decimal
        Dim firstX, firstY, lastX, lastY As Integer

        If IsX Then
            firstX = first.X : lastX = last.X
            firstY = first.Y : lastY = last.Y
        Else
            firstX = first.Y : lastX = last.Y
            firstY = first.X : lastY = last.X
        End If

        ratio = (lastX - firstX) / (lastY - firstY)
        If offsetIn < 0 Then
            CalcO = lastX + (offsetIn * ratio)
        Else
            CalcO = firstX + (offsetIn * ratio)
        End If
    End Function

    Sub RandomReverse()
        Dim a, r As Integer

        ' Wait for 2 sec
        Sleep(2)

        ' do the two main reverses
        Reverse(0)
        Reverse(4)

        ' do 20 random reverses
        VBMath.Randomize()
        For a = 0 To 19
            ' calc rand
            r = Math.Floor(4 * VBMath.Rnd()) + If((a Mod 2) = 0, 0, 4)
            ' do it
            Reverse(r)
        Next

        ' End program
        Me.Close()
    End Sub

    Sub Reverse(r As Integer)
        Dim oSmall, iSmall, oLarge, iLarge, direction, slow As Integer
        Dim SmallX, SmallY, LargeX, LargeY As Integer
        Dim oSmallMax, iSmallMax, oSmallMin, iSmallMin As Integer
        Dim i, c As Color
        '    0             1             2             3             4             5             6             7
        '    oSmallB       oSmallE       oLargeB       oLargeE       iSmallB       iSmallE       iLargeB       iLargeE
        Dim RevList(,) As Integer = {
            {Box("S00").x, Box("S11").x, Box("L00").X, Box("L11").X, Box("S00").y, Box("S11").y, Box("L00").y, Box("L11").y},
            {Box("S00").y, Box("S11").y, Box("L00").y, Box("L11").y, Box("S00").x, Box("S11").x, Box("L00").x, Box("L11").x},
            {Box("S11").x, Box("S00").x, Box("L11").X, Box("L00").X, Box("S11").y, Box("S00").y, Box("L11").y, Box("L00").y},
            {Box("S11").y, Box("S00").y, Box("L11").y, Box("L00").y, Box("S11").x, Box("S00").x, Box("L11").x, Box("L00").x},
            {-1, -1, Box("I00").X, Box("I11").X, -1, -1, Box("I00").y, Box("I11").y},
            {-1, -1, Box("I00").y, Box("I11").y, -1, -1, Box("I00").x, Box("I11").x},
            {-1, -1, Box("I11").X, Box("I00").X, -1, -1, Box("I11").y, Box("I00").y},
            {-1, -1, Box("I11").y, Box("I00").y, -1, -1, Box("I11").x, Box("I00").x}
        }

        If RevList(r, 2) < RevList(r, 3) Then
            direction = 1
            oSmallMax = RevList(r, 1) : oSmallMin = RevList(r, 0)
            iSmallMax = RevList(r, 5) : iSmallMin = RevList(r, 4)
        Else
            direction = -1
            oSmallMax = RevList(r, 0) : oSmallMin = RevList(r, 1)
            iSmallMax = RevList(r, 4) : iSmallMin = RevList(r, 5)
        End If

        oSmall = RevList(r, 0)
        For oLarge = RevList(r, 2) To RevList(r, 3) Step direction
            iSmall = RevList(r, 4)
            For iLarge = RevList(r, 6) To RevList(r, 7) Step direction
                If ((r Mod 2) = 0) Then
                    slow = 7
                    SmallX = oSmall : SmallY = iSmall
                    LargeX = oLarge : LargeY = iLarge
                Else
                    slow = 6
                    SmallX = iSmall : SmallY = oSmall
                    LargeX = iLarge : LargeY = oLarge
                End If
                ' large
                Try
                    c = bImage.GetPixel(LargeX, LargeY)
                    i = Color.FromArgb(255, 255 - c.R, 255 - c.G, 255 - c.B)
                    bImage.SetPixel(LargeX, LargeY, i)
                Catch ex As Exception
                End Try
                ' small
                If (oSmall > 0) And ((oLarge Mod slow) = 0) Then
                    If oSmallMin < oSmall And oSmall < oSmallMax And _
                       iSmallMin < iSmall And iSmall < iSmallMax Then
                        Try
                            c = bImage.GetPixel(SmallX, SmallY)
                            i = Color.FromArgb(255, 255 - c.R, 255 - c.G, 255 - c.B)
                            bImage.SetPixel(SmallX, SmallY, i)
                        Catch ex As Exception
                        End Try
                    End If
                    iSmall += direction
                End If
            Next
            If (oSmall > 0) And ((oLarge Mod slow) = 0) Then
                oSmall += direction
            End If
            DoRefresh()
        Next
    End Sub

    Private Sub Picture_Click(sender As Object, e As EventArgs) Handles PictureBox1.Click
        ' Call main on click
        'Main()
    End Sub

    Private Sub App_KeyPress(sender As Object, e As EventArgs) Handles MyBase.KeyPress
        ' End program
        Me.Close()
    End Sub

    Private Sub App_Shown(sender As Object, e As EventArgs) Handles MyBase.Shown
        ' Call main
        Main()
    End Sub

    Private Sub App_Load(sender As Object, e As EventArgs) Handles MyBase.Load
        CheckForIllegalCrossThreadCalls = False
    End Sub

    Private Sub App_Close(sender As Object, e As EventArgs) Handles MyBase.FormClosing
    End Sub

    Private Sub Timer1_Tick(sender As Object, e As EventArgs) Handles Timer1.Tick
    End Sub

    Private Sub Timer2_Tick(sender As Object, e As EventArgs) Handles Timer2.Tick
    End Sub
End Class