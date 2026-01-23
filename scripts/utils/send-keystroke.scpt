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
    set targetWindow to missing value

    -- Find the session with matching TTY
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
                            set targetWindow to theWindow
                            set foundSession to true
                            exit repeat
                        end if
                    end try
                end repeat
                if foundSession then exit repeat
            end repeat
            if foundSession then exit repeat
        end repeat
    end tell

    if not foundSession then
        return "Error: Session with TTY " & targetTTY & " not found"
    end if

    -- Retry loop: activate iTerm, verify correct session is focused, then send keystrokes
    set maxRetries to 5
    set retryCount to 0
    set success to false

    repeat while retryCount < maxRetries and not success
        set retryCount to retryCount + 1

        -- Select the target session and activate its window
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
                                exit repeat
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            activate
        end tell

        -- Wait for activation
        delay 0.2

        -- Verify iTerm is frontmost
        tell application "System Events"
            set frontApp to name of first application process whose frontmost is true
        end tell

        if frontApp is not "iTerm2" then
            -- iTerm not focused, wait and retry
            delay 0.3
        else
            -- Verify the correct session (by TTY) is now active
            set currentTTY to ""
            try
                tell application "iTerm"
                    set currentTTY to tty of current session of current window
                end tell
            end try

            if currentTTY is targetTTY then
                -- Correct session is focused, send keystrokes
                delay 0.1

                tell application "System Events"
                    tell process "iTerm2"
                        keystroke messageText
                        delay 0.1
                        keystroke return
                    end tell
                end tell

                set success to true
            else
                -- Wrong session focused, wait and retry
                delay 0.3
            end if
        end if
    end repeat

    if success then
        return "Message sent to " & targetTTY & " (attempts: " & retryCount & ")"
    else
        return "Error: Failed to focus session " & targetTTY & " after " & maxRetries & " attempts"
    end if
end run
