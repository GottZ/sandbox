#!/usr/bin/expect -f
#
# Wrapper script to auto-confirm the bypass permissions warning
# using arrow down + enter to select the option
#

# Short timeout - if prompt doesn't show quickly, skip it
set timeout 2

# Get all arguments
set args $argv

# Spawn claude with bypass permissions
spawn -noecho claude --allow-dangerously-skip-permissions --permission-mode bypassPermissions {*}$args

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

# Hand over to interactive mode
interact
