#!/usr/bin/expect -f
#
# Wrapper script to auto-confirm the bypass permissions warning
# using arrow down + enter to select the option
#
# Handles SIGWINCH (terminal resize) properly to fix resize-down issues
#

# Timeout for waiting on the bypass permissions prompt
# Give Claude enough time to start up (especially on slower systems or first run)
set timeout 30

# Get all arguments
set args $argv

# Spawn claude with bypass permissions
spawn -noecho claude --allow-dangerously-skip-permissions --permission-mode bypassPermissions {*}$args

# Store the spawn id for SIGWINCH handling
set claude_spawn $spawn_id

# Wait for the bypass permissions warning and select with arrow down + enter
expect {
    -re {WARNING.*[Bb]ypass [Pp]ermissions} {
        sleep 0.2
        send "\033\[B"
        sleep 0.1
        send "\r"
    }
    -re {\[y/N\]} {
        send "y\r"
    }
    timeout {
        # No prompt appeared, continue immediately
    }
}

# Set up SIGWINCH (window change) handler to propagate terminal resize
# This fixes the issue where terminal can resize up but not down
trap {
    # Get current terminal dimensions
    set stty_output [stty size]
    regexp {(\d+) (\d+)} $stty_output match rows cols

    # Propagate to the spawned process's pty
    if {[info exists spawn_out(slave,name)]} {
        catch {stty rows $rows columns $cols < $spawn_out(slave,name)}
    }
} WINCH

# Sync initial terminal size before interaction
set stty_output [stty size]
regexp {(\d+) (\d+)} $stty_output match rows cols
if {[info exists spawn_out(slave,name)]} {
    catch {stty rows $rows columns $cols < $spawn_out(slave,name)}
}

# Hand over to interactive mode
interact
