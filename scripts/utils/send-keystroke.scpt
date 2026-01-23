-- send-keystroke.scpt - Send a keystroke message to an iTerm2 session by TTY
-- Usage: osascript send-keystroke.scpt <tty> [message]
-- Example: osascript send-keystroke.scpt /dev/ttys007 "Task incoming, please complete the delegated task."

on run argv
    -- Parse arguments
    if (count of argv) < 1 then
        return "Error: TTY argument required. Usage: osascript send-keystroke.scpt <tty> [message]"
    end if

    set targetTTY to item 1 of argv

    -- Default message if not provided
    if (count of argv) >= 2 then
        set messageText to item 2 of argv
    else
        set messageText to "Task incoming, please complete the delegated task."
    end if

    set foundSession to false

    tell application "iTerm"
        set windowCount to count of windows
        repeat with w from 1 to windowCount
            set theWindow to window w
            set tabCount to count of tabs of theWindow
            repeat with t from 1 to tabCount
                set theTab to tab t of theWindow
                set sessionCount to count of sessions of theTab
                repeat with s from 1 to sessionCount
                    try
                        set theSession to session s of theTab
                        if tty of theSession is targetTTY then
                            select theSession
                            set index of theWindow to 1
                            set foundSession to true
                            exit repeat
                        end if
                    end try
                end repeat
                if foundSession then exit repeat
            end repeat
            if foundSession then exit repeat
        end repeat
        activate
    end tell

    if foundSession then
        delay 0.1

        tell application "System Events"
            tell process "iTerm2"
                keystroke messageText
                delay 0.05
                keystroke return
            end tell
        end tell
        return "Message sent to " & targetTTY
    else
        return "Error: Session with TTY " & targetTTY & " not found"
    end if
end run
