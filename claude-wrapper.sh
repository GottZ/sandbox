#!/bin/bash
#
# Wrapper script for running Claude Code interactively in the sandbox.
#
# The bypass permissions confirmation dialog is auto-accepted because the
# entrypoint.sh sets bypassPermissionsModeAccepted:true in the config file
# (~/.claude.json or ~/.claude/.config.json) before claude starts.
#

exec claude --dangerously-skip-permissions "$@"
