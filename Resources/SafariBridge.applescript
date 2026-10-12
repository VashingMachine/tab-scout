use framework "Foundation"
use scripting additions

on run argv
    if (count of argv) is 0 then error "Missing command"
    set operation to item 1 of argv

    if operation is "list" then
        if application "Safari" is not running then return "[]"
        set tabRows to current application's NSMutableArray's array()
        with timeout of 12 seconds
            tell application "Safari"
                set windowIDs to id of every window
            end tell
            repeat with browserWindowID in windowIDs
                set windowID to browserWindowID as integer
                set windowRows to my rowsForWindow(windowID)
                repeat with tabRow in windowRows
                    tabRows's addObject:(contents of tabRow)
                end repeat
            end repeat
        end timeout
        return my jsonText(tabRows)
    end if

    -- Only the tab on screen, cheap enough to read after every tab switch.
    if operation is "active" then
        if application "Safari" is not running then return "[]"
        try
            with timeout of 5 seconds
                tell application "Safari"
                    if (count of windows) is 0 then return "[]"
                    set browserWindow to front window
                    set windowID to id of browserWindow
                    set activeTab to current tab of browserWindow
                    set tabIndex to index of activeTab
                    set tabTitle to name of activeTab
                    set tabURL to URL of activeTab
                end tell
            end timeout
        on error errorMessage number errorNumber
            if errorNumber is -1743 then error errorMessage number errorNumber
            return "[]"
        end try
        return my jsonText(my activeRow(windowID, tabIndex, tabTitle, tabURL))
    end if

    if operation is "switch" then
        set targetWindowID to (item 2 of argv) as integer
        set targetIndex to (item 3 of argv) as integer
        set targetURL to item 4 of argv
        set targetTitle to item 5 of argv
        with timeout of 12 seconds
            tell application "Safari"
                if not (exists window id targetWindowID) then error "TAB_SCOUT_STALE"
                set browserWindow to window id targetWindowID
                set targetTab to missing value
                if targetIndex <= (count of tabs of browserWindow) then
                    set candidate to tab targetIndex of browserWindow
                    set candidateURL to URL of candidate
                    set candidateTitle to name of candidate
                    if candidateURL is missing value then set candidateURL to ""
                    if candidateTitle is missing value then set candidateTitle to ""
                    if candidateURL is targetURL and candidateTitle is targetTitle then set targetTab to candidate
                end if
                if targetTab is missing value then
                    repeat with candidate in tabs of browserWindow
                        set candidateURL to URL of candidate
                        set candidateTitle to name of candidate
                        if candidateURL is missing value then set candidateURL to ""
                        if candidateTitle is missing value then set candidateTitle to ""
                        if candidateURL is targetURL and candidateTitle is targetTitle then
                            set targetTab to contents of candidate
                            exit repeat
                        end if
                    end repeat
                end if
                if targetTab is missing value then error "TAB_SCOUT_STALE"
                set current tab of browserWindow to targetTab
                set miniaturized of browserWindow to false
                set index of browserWindow to 1
                activate
            end tell
        end timeout
        return "ok"
    end if

    if operation is "prepare-new-tab" then
        set targetWindowID to (item 2 of argv) as integer
        with timeout of 12 seconds
            tell application "Safari"
                if (count of windows) is not 0 then
                    if targetWindowID is not 0 and (exists window id targetWindowID) then
                        set browserWindow to window id targetWindowID
                    else
                        set browserWindow to front window
                    end if
                    set miniaturized of browserWindow to false
                    set index of browserWindow to 1
                end if
                activate
            end tell
        end timeout
        return "ok"
    end if

    if operation is "url" or operation is "search" then
        set targetWindowID to (item 2 of argv) as integer
        set destination to item 3 of argv
        with timeout of 12 seconds
            tell application "Safari"
                set createdWindow to false
                if (count of windows) is 0 then
                    make new document
                    set createdWindow to true
                end if
                if targetWindowID is not 0 and (exists window id targetWindowID) then
                    set browserWindow to window id targetWindowID
                else
                    set browserWindow to front window
                end if
                tell browserWindow
                    if createdWindow then
                        set newTab to current tab
                    else
                        set newTab to make new tab at end of tabs with properties {URL:"about:blank"}
                    end if
                    set current tab to newTab
                end tell
                set miniaturized of browserWindow to false
                set index of browserWindow to 1
                if operation is "url" then
                    set URL of newTab to destination
                else
                    search the web in newTab for destination
                end if
                activate
            end tell
        end timeout
        return "ok"
    end if
    error "Unknown command"
end run

on rowsForWindow(windowID)
    set stableSnapshot to false
    repeat 2 times
        try
            tell application "Safari"
                if not (exists window id windowID) then return {}
                set browserWindow to window id windowID
                -- Fetch arrays in bulk; never send an Apple event for each tab.
                set tabURLs to URL of every tab of browserWindow
                set tabTitles to name of every tab of browserWindow
                set verifiedURLs to URL of every tab of browserWindow
                set currentIndex to index of current tab of browserWindow
            end tell
        on error errorMessage number errorNumber
            -- A window closed during the snapshot is no longer part of the session.
            if errorNumber is -1728 then return {}
            error errorMessage number errorNumber
        end try
        if my snapshotIsStable(tabTitles, tabURLs, verifiedURLs) then
            set stableSnapshot to true
            exit repeat
        end if
    end repeat
    if not stableSnapshot then error "TAB_SCOUT_SNAPSHOT_CHANGED"
    return my rowsFromSnapshot(windowID, tabTitles, tabURLs, currentIndex)
end rowsForWindow

on snapshotIsStable(tabTitles, tabURLs, verifiedURLs)
    considering case
        return tabURLs is verifiedURLs and (count of tabTitles) is (count of tabURLs)
    end considering
end snapshotIsStable

-- The last field marks the window's current tab. Windows are listed front to back,
-- so the first marked row is the tab on screen.
on rowsFromSnapshot(windowID, tabTitles, tabURLs, currentIndex)
    if (count of tabTitles) is not (count of tabURLs) then error "TAB_SCOUT_SNAPSHOT_CHANGED"
    set windowRows to {}
    repeat with tabIndex from 1 to count of tabURLs
        set tabTitle to item tabIndex of tabTitles
        set tabURL to item tabIndex of tabURLs
        if tabTitle is missing value then set tabTitle to ""
        if tabURL is missing value then set tabURL to ""
        set end of windowRows to {windowID, tabIndex, tabTitle, tabURL, tabIndex is currentIndex}
    end repeat
    return windowRows
end rowsFromSnapshot

on activeRow(windowID, tabIndex, tabTitle, tabURL)
    if tabTitle is missing value then set tabTitle to ""
    if tabURL is missing value then set tabURL to ""
    return {windowID, tabIndex, tabTitle, tabURL}
end activeRow

on jsonText(value)
    set jsonData to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(missing value)
    return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end jsonText
