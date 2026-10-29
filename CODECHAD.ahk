; ============================================================================
; Portable Auto-Typer - AutoHotkey v2
; ----------------------------------------------------------------------------
; Sends source text to the active application one character at a time.
; WPM is calculated using the standard convention of 5 characters per word.
;
; Optional flattening removes line breaks and line indentation before typing.
; Optional bracket compensation steps over closing brackets/quotes that the
; target editor has already inserted automatically.
;
; Hotkeys:
;   Start: Ctrl+Alt+S or F8 (after a 3-second countdown)
;   Stop:  Ctrl+Alt+X or Esc (Esc is registered only while typing)
;
; Compile with AutoHotkey v2 / Ahk2Exe to create a standalone executable.
; ============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force

;@Ahk2Exe-SetName Portable Auto-Typer
;@Ahk2Exe-SetDescription Portable Auto-Typer - Character-by-character typing
;@Ahk2Exe-SetVersion 2.0.0.0

; ============================== CONFIG ======================================
APP_TITLE         := "Portable Auto-Typer"
WPM_MIN           := 10
WPM_MAX           := 300
WPM_DEFAULT       := 60
COUNTDOWN_SECONDS := 3

START_HOTKEYS := ["^!s", "F8"]   ; ^ = Ctrl, ! = Alt
STOP_HOTKEYS  := ["^!x"]
ESC_HOTKEY    := "*Esc"           ; active only during a typing run

SEND_MODE     := "Input"          ; Use "Event" for some remote/VM targets
REQUIRE_ADMIN := false             ; Set true only if the target requires elevation
EDIT_ROWS     := 0                 ; 0 = calculate a suitable editor height

; Status colours (RRGGBB)
CLR_READY   := "2E7D32"
CLR_BUSY    := "1565C0"
CLR_WAIT    := "EF6C00"
CLR_STOPPED := "C62828"
; ============================================================================

; ---- Optional self-elevation ----
if REQUIRE_ADMIN && !A_IsAdmin {
    try {
        if A_IsCompiled
            Run '*RunAs "' A_ScriptFullPath '"'
        else
            Run '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
        ExitApp
    }
    ; If elevation is declined, continue without elevation.
}

SendMode SEND_MODE
SetKeyDelay -1, -1
A_IconTip := APP_TITLE

; ---- Runtime state ----
isTyping      := false
stopRequested := false

; ---- Hotkey descriptions shown in the GUI ----
startLabel := JoinHotkeys(START_HOTKEYS) . "   (" . COUNTDOWN_SECONDS . "-second countdown)"
stopLabel  := PrettyHotkey(ESC_HOTKEY) . " (only while typing)   or   " . JoinHotkeys(STOP_HOTKEYS)

; ============================== GUI =========================================
W := 680
editRows := EDIT_ROWS > 0 ? EDIT_ROWS : AutoEditRows()

g := Gui(, APP_TITLE)
g.MarginX := 14
g.MarginY := 10
g.SetFont("s10", "Segoe UI")
g.OnEvent("Close", (*) => ExitApp())

g.Add("Text", "w" W, "Text to type - paste code or plain text:")
edtText := g.Add("Edit", "y+6 w" W " r" editRows " Multi VScroll HScroll -Wrap WantTab Limit1000000")
edtText.SetFont("s10", "Consolas")
edtText.OnEvent("Change", RefreshInfo)

; ---- Speed controls: slider and number box stay synchronized ----
g.Add("Text", "xm y+10 h28 +0x200", "Typing speed (WPM):")
sldWpm := g.Add("Slider", "x+10 yp w360 h28 Range" WPM_MIN "-" WPM_MAX " Page10 NoTicks ToolTip", WPM_DEFAULT)
edtWpm := g.Add("Edit", "x+12 yp w62 h28 Number Center")
updWpm := g.Add("UpDown", "Range" WPM_MIN "-" WPM_MAX, WPM_DEFAULT)
sldWpm.OnEvent("Change", OnSliderChange)
edtWpm.OnEvent("Change", OnWpmEdit)
edtWpm.OnEvent("LoseFocus", ClampWpm)

txtInfo := g.Add("Text", "xm y+4 w" W, "")

; ---- Character-by-character options ----
; Flattening is opt-in so ordinary multi-line text can still be typed as-is.
chkFlatten := g.Add("Checkbox", "xm+10 y+10 w" . (W - 20), "Flatten code to a single line before typing")
chkAntiBrackets := g.Add("Checkbox", "xm+10 y+6 w" . (W - 20), "Enable Anti-Auto-Bracket Compensation")

; ---- Hotkey information ----
valW := W - 130
lblHot := g.Add("Text", "xm y+12 w130 r2", "Start typing:`nEmergency stop:")
lblHot.SetFont("s10 bold", "Segoe UI")
g.Add("Text", "x+0 yp w" valW " r2", startLabel "`n" stopLabel)

; ---- Status and progress ----
txtStatus := g.Add("Text", "xm y+12 w" W " h34 Center +Border +0x200", "Ready")
txtStatus.SetFont("s12 bold c" CLR_READY, "Segoe UI")
prgBar := g.Add("Progress", "xm y+6 w" W " h12 Range0-100", 0)

; ---- Buttons ----
btnStart := g.Add("Button", "xm y+12 w210 h36", "Start Typing (" COUNTDOWN_SECONDS "s delay)")
btnStop  := g.Add("Button", "x+8 yp w100 h36 Disabled", "Stop")
btnClear := g.Add("Button", "x+8 yp w100 h36", "Clear Text")
chkMin   := g.Add("Checkbox", "x+16 yp+7 Checked", "Minimize while typing")

btnStart.OnEvent("Click", StartTyping)
btnStop.OnEvent("Click", StopTyping)
btnClear.OnEvent("Click", ClearText)
chkFlatten.OnEvent("Click", RefreshInfo)
chkAntiBrackets.OnEvent("Click", RefreshInfo)

; ============================== HOTKEYS =====================================
try {
    for hk in START_HOTKEYS
        Hotkey hk, StartTyping
    for hk in STOP_HOTKEYS
        Hotkey hk, StopTyping

    ; Esc is active only during typing, so it behaves normally elsewhere.
    HotIf(IsTypingHotIf)
    Hotkey ESC_HOTKEY, StopTyping
    HotIf()
} catch as regErr {
    HotIf()
    MsgBox "Could not register a hotkey:`n`n" regErr.Message "`n`nCheck the CONFIG section of the script.", APP_TITLE, "Iconx"
    ExitApp
}

g.Show("AutoSize Center")
RefreshInfo()
edtText.Focus()
; (Auto-execute section ends here; the GUI and hotkeys keep the script alive.)


; ============================================================================
; START / STOP
; ============================================================================
StartTyping(*) {
    global isTyping, stopRequested, edtText, chkFlatten, chkAntiBrackets, chkMin
    global WPM_MIN, WPM_MAX, APP_TITLE, COUNTDOWN_SECONDS, CLR_BUSY, CLR_READY, CLR_STOPPED
    global g, btnStart, btnStop, prgBar

    if isTyping
        return

    ; Normalize Windows, Unix, and old-Mac line endings before processing input.
    text := NormalizeNewlines(edtText.Value)

    ; Flatten before the countdown so the engine never sends Enter when enabled.
    ; The original text in the editor is not overwritten.
    if chkFlatten.Value
        text := FlattenToSingleLine(text)

    if Trim(text, " `t`n") = "" {
        ShowError("The text area is empty.`n`nEnter the text you want typed, then start again.")
        edtText.Focus()
        return
    }

    wpm := ReadWpm()
    if !wpm
        return

    delayMs      := CharDelayMs(wpm)
    antiBrackets := chkAntiBrackets.Value
    minimize     := chkMin.Value

    ; Enter the active typing state and reset stop/progress controls.
    isTyping      := true
    stopRequested := false
    btnStart.Enabled := false
    btnStop.Enabled  := true
    prgBar.Value := 0

    if minimize
        WinMinimize "ahk_id " g.Hwnd

    result := "Stopped"
    errMsg := ""
    try {
        if Countdown(COUNTDOWN_SECONDS) {
            ; Avoid typing into the Auto-Typer's own input box by mistake.
            if WinActive("ahk_id " g.Hwnd) {
                errMsg := "The Auto-Typer window still has focus.`n`nClick the destination editor during the countdown, or enable 'Minimize while typing', then try again."
            } else {
                SetStatus("Typing in progress...", CLR_BUSY)
                finished := TypeKeystrokes(text, delayMs, antiBrackets)
                if finished {
                    result := "Ready"
                    prgBar.Value := 100
                }
            }
        }
    } catch as err {
        errMsg := err.Message
        result := "Stopped"
    } finally {
        ; Always restore the GUI state, whether typing finished, stopped, or failed.
        isTyping      := false
        stopRequested := false
        btnStart.Enabled := true
        btnStop.Enabled  := false
        ToolTip()

        if minimize && WinGetMinMax("ahk_id " g.Hwnd) = -1
            WinRestore "ahk_id " g.Hwnd

        SetStatus(result, result = "Ready" ? CLR_READY : CLR_STOPPED)
    }

    if errMsg != ""
        ShowError("Typing was aborted:`n`n" errMsg)
}

; HotIf callback: Esc should be intercepted only while a typing run is active.
IsTypingHotIf(*) {
    global isTyping
    return isTyping
}

; Emergency stop: the active engine checks stopRequested between characters
; and during short timing waits, so no remaining source text is queued.
StopTyping(*) {
    global isTyping, stopRequested, CLR_STOPPED
    if !isTyping
        return
    stopRequested := true
    SetStatus("Stopped", CLR_STOPPED)  ; Immediate visual feedback; cleanup follows.
}

ClearText(*) {
    global edtText
    edtText.Value := ""
    RefreshInfo()
    edtText.Focus()
}


; ============================================================================
; CHARACTER-BY-CHARACTER TYPING ENGINE
; ============================================================================

; Delay = 60,000 / (WPM * 5). The loop uses this delay between output events.
CharDelayMs(wpm) => 60000 / (wpm * 5)

; Types each character individually. Returns true on completion, false on Stop.
TypeKeystrokes(text, delayMs, antiBrackets) {
    global stopRequested, prgBar

    total    := StrLen(text)
    pos      := 1
    lastPct  := -1
    nextTick := A_TickCount

    ; Each item represents a closer the editor is expected to auto-insert.
    ; This stack supports nested pairs such as { call([value]) }.
    expectedClosers := []

    while pos <= total {
        if stopRequested
            return false

        ; Read a complete Unicode character where possible, including surrogate pairs.
        charStart := pos
        code := Ord(SubStr(text, pos, 2))
        ch := SubStr(text, pos, code > 0xFFFF ? 2 : 1)
        pos += StrLen(ch)

        if (ch = "`n") {
            ; Enter is only emitted when flattening is disabled and source has newlines.
            Send "{Enter}"
        } else if (ch = "`t") {
            ; A real Tab key is used for literal tabs when flattening is disabled.
            Send "{Tab}"
        } else {
            handledByBracketCompensation := false

            if antiBrackets && expectedClosers.Length {
                topCloser := expectedClosers[expectedClosers.Length]
                isInsideQuote := (topCloser = Chr(34) || topCloser = "'")

                ; Inside a tracked string, only its matching unescaped quote closes it.
                if isInsideQuote {
                    if (ch = topCloser && !IsEscapedAt(text, charStart)) {
                        Send "{Right}"   ; Step over the quote already created by the editor.
                        expectedClosers.Pop()
                    } else {
                        SendText ch       ; Literal string content: never auto-track brackets.
                    }
                    handledByBracketCompensation := true
                } else if (ch = topCloser && !IsEscapedAt(text, charStart)) {
                    Send "{Right}"       ; Step over the matching auto-inserted closer.
                    expectedClosers.Pop()
                    handledByBracketCompensation := true
                }
            }

            if !handledByBracketCompensation {
                SendText ch               ; SendText avoids interpreting braces as AHK syntax.

                ; Remember openers only when compensation is enabled. This assumes the
                ; target editor auto-inserts matching characters for these openers.
                if antiBrackets && !IsEscapedAt(text, charStart) {
                    if (ch = "{")
                        expectedClosers.Push("}")
                    else if (ch = "(")
                        expectedClosers.Push(")")
                    else if (ch = "[")
                        expectedClosers.Push("]")
                    else if ((ch = Chr(34) || ch = "'") && HasMatchingQuoteLater(text, charStart, ch))
                        expectedClosers.Push(ch)
                }
            }
        }

        ; Progress reflects source characters, including source closers skipped with Right.
        pct := (pos - 1) * 100 // total
        if pct != lastPct {
            prgBar.Value := pct
            lastPct := pct
        }

        ; Drift-corrected pacing prevents accumulated timer delays from slowing the run.
        nextTick += delayMs
        if (A_TickCount - nextTick > 250)  ; If far behind, do not rapidly send characters to catch up.
            nextTick := A_TickCount
        if !WaitUntil(nextTick)
            return false
    }
    return true
}

; Returns true when the character at charPosition is escaped by an odd run of backslashes.
IsEscapedAt(text, charPosition) {
    slashCount := 0
    index := charPosition - 1
    while (index >= 1 && SubStr(text, index, 1) = Chr(92)) {
        slashCount += 1
        index -= 1
    }
    return Mod(slashCount, 2) = 1
}

; Only track a quote when its closing mate exists later on the same source line.
HasMatchingQuoteLater(text, charPosition, quoteChar) {
    index := charPosition + 1
    textLength := StrLen(text)
    while index <= textLength {
        ch := SubStr(text, index, 1)
        if (ch = "`n")
            return false
        if (ch = quoteChar && !IsEscapedAt(text, index))
            return true
        index += 1
    }
    return false
}

; Waits in small slices so the Stop hotkey can interrupt the delay promptly.
WaitUntil(targetTick) {
    global stopRequested
    while (remaining := targetTick - A_TickCount) > 0 {
        if stopRequested
            return false
        Sleep Min(Ceil(remaining), 10)
    }
    return !stopRequested
}

; Countdown gives time to select the target editor before simulated input begins.
Countdown(seconds) {
    global stopRequested, CLR_WAIT
    Loop seconds {
        remaining := seconds - A_Index + 1
        SetStatus("Starting in " remaining "... click into your target window", CLR_WAIT)
        endTick := A_TickCount + 1000
        while A_TickCount < endTick {
            if stopRequested
                return false
            Sleep 10
        }
    }
    return !stopRequested
}


; ============================================================================
; FLATTENING AND GUI HELPERS
; ============================================================================

; Converts normalized multi-line input into one line. For each line, remove only
; surrounding indentation/whitespace, discard blank lines, and join remaining
; lines with exactly one space. Internal spacing is preserved to avoid changing
; intentional runs of spaces inside quoted strings or ordinary text.
FlattenToSingleLine(text) {
    text := NormalizeNewlines(text)
    lines := StrSplit(text, "`n")
    result := ""

    for line in lines {
        line := Trim(line, " `t")
        if (line = "")
            continue
        result .= (result = "" ? "" : " ") . line
    }
    return result
}

SetStatus(msg, color) {
    global txtStatus, g
    txtStatus.SetFont("s12 bold c" color, "Segoe UI")
    txtStatus.Value := msg

    ; When minimized, show the current status in a small tooltip as well.
    if WinGetMinMax("ahk_id " g.Hwnd) = -1
        ToolTip(msg, 16, 16)
    else
        ToolTip()
}

ShowError(msg) {
    global APP_TITLE
    MsgBox msg, APP_TITLE, "Iconx 262144"  ; 262144 = always on top.
}

; Picks a text-box height that fits the screen work area, adjusted for DPI.
AutoEditRows() {
    MonitorGetWorkArea(MonitorGetPrimary(), &left, &top, &right, &bottom)
    availableLogical := (bottom - top) / (A_ScreenDPI / 96)
    rows := Floor((availableLogical - 480) / 18)
    return Min(Max(rows, 6), 22)
}

OnSliderChange(ctrl, *) {
    global updWpm
    updWpm.Value := ctrl.Value
    RefreshInfo()
}

OnWpmEdit(ctrl, *) {
    global sldWpm, WPM_MIN, WPM_MAX
    wpm := ParseWpm(ctrl.Value)
    if wpm
        sldWpm.Value := wpm
    RefreshInfo()
}

; Snap an invalid or incomplete speed entry back to a valid value on focus loss.
ClampWpm(*) {
    global edtWpm, WPM_DEFAULT, WPM_MIN, WPM_MAX, updWpm, sldWpm
    value := Trim(edtWpm.Value)
    wpm := IsInteger(value) ? Integer(value) : WPM_DEFAULT
    wpm := Min(Max(wpm, WPM_MIN), WPM_MAX)
    updWpm.Value := wpm
    sldWpm.Value := wpm
    RefreshInfo()
}

; Returns an integer when the input is within the given inclusive range, otherwise 0.
ParseIntInRange(value, low, high) {
    value := Trim(value)
    if IsInteger(value) && value >= low && value <= high
        return Integer(value)
    return 0
}

ParseWpm(value) {
    global WPM_MIN, WPM_MAX
    return ParseIntInRange(value, WPM_MIN, WPM_MAX)
}

ReadWpm() {
    global edtWpm, WPM_MIN, WPM_MAX
    wpm := ParseWpm(edtWpm.Value)
    if !wpm {
        ShowError("Typing speed must be a whole number between " WPM_MIN " and " WPM_MAX " WPM.")
        edtWpm.Focus()
    }
    return wpm
}

RefreshInfo(*) {
    global edtWpm, txtInfo, WPM_MIN, WPM_MAX, edtText, chkFlatten

    wpm := ParseWpm(edtWpm.Value)
    if !wpm {
        txtInfo.Value := "Enter a speed between " WPM_MIN " and " WPM_MAX " WPM."
        return
    }

    delayMs := CharDelayMs(wpm)
    sourceText := NormalizeNewlines(edtText.Value)
    displayedText := chkFlatten.Value ? FlattenToSingleLine(sourceText) : sourceText
    chars := StrLen(displayedText)
    lines := chars ? StrSplit(displayedText, "`n").Length : 0
    seconds := Round(chars * delayMs / 1000)

    modeNote := chkFlatten.Value ? "single-line output" : "original line breaks"
    txtInfo.Value := Format("{1} ms per character   |   {2} characters, {3} line(s)   |   {4}   |   estimated time: {5}"
        , Round(delayMs, 1), chars, lines, modeNote, FormatDuration(seconds))
}

FormatDuration(totalSeconds) {
    hours := totalSeconds // 3600
    minutes := Mod(totalSeconds // 60, 60)
    seconds := Mod(totalSeconds, 60)
    return hours ? Format("{1}h {2}m {3}s", hours, minutes, seconds) : Format("{1}m {2}s", minutes, seconds)
}

NormalizeNewlines(text) {
    return StrReplace(StrReplace(text, "`r`n", "`n"), "`r", "`n")
}

; Converts AHK hotkey notation to readable labels for display in the GUI.
PrettyHotkey(hotkey) {
    RegExMatch(hotkey, "^([*~$<>^!+#]*)(.*)$", &match)
    modifiers := match[1]
    key := match[2]
    output := ""
    if InStr(modifiers, "^")
        output .= "Ctrl + "
    if InStr(modifiers, "!")
        output .= "Alt + "
    if InStr(modifiers, "+")
        output .= "Shift + "
    if InStr(modifiers, "#")
        output .= "Win + "
    return output . (StrLen(key) = 1 ? StrUpper(key) : key)
}

JoinHotkeys(hotkeys) {
    output := ""
    for hotkey in hotkeys
        output .= (A_Index > 1 ? "   or   " : "") . PrettyHotkey(hotkey)
    return output
}
