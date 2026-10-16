#!/bin/sh
# Keeps this pane attached to the Herdr terminal named in the target file.
# Targets are "SELECTOR TERMINAL_ID": local/default, local/<session>, or a saved
# Herdr machine profile ID. The profile, not its SSH host, selects the remote session.
# The plugin changes the file; this loop stops only its local attach client
# with SIGTERM, so no escape key can leak into a different terminal.
#   follow.sh TARGET_FILE [LOCAL_HERDR_BIN]

file="$1"
local_herdr="${2:-herdr}"
on="$file.on" # the target this pane is attached to right now, empty while waiting

# An inherited Herdr client socket or session must never override the explicit
# target selector; it could silently attach to another server's terminal ID.
unset HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH HERDR_SESSION

: > "$on"
trap 'if [ -n "${child:-}" ]; then kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; fi; : > "$on"' EXIT
waiting=""
failures=0
while :; do
	target=$(cat "$file" 2>/dev/null)
	if [ -z "$target" ] || [ "$target" = "$waiting" ]; then
		sleep 0.3
		continue
	fi
	waiting=""
	selector=${target% *}
	terminal=${target##* }
	case "$terminal" in
		''|*[!a-zA-Z0-9_.-]*)
			printf 'Invalid Herdr terminal ID in target file.\n' >&2
			waiting="$target"
			continue
			;;
	esac
	case "$selector" in
		local/*)
			session=${selector#local/}
			case "$session" in
				''|*[!a-zA-Z0-9_.-]*)
					printf 'Invalid local Herdr session in target file.\n' >&2
					waiting="$target"
					continue
					;;
			esac
			[ "${#session}" -le 64 ] || {
				waiting="$target"
				continue
			}
			[ "$session" != . ] && [ "$session" != .. ] || {
				waiting="$target"
				continue
			}
			machine=local
			;;
		*)
			case "$selector" in
				????????????????????????????????) ;;
				*)
					printf 'Invalid saved Herdr profile ID in target file.\n' >&2
					waiting="$target"
					continue
					;;
			esac
			case "$selector" in
				*[!a-fA-F0-9]*)
					waiting="$target"
					continue
					;;
			esac
			# Herdr resolves the saved profile ID itself, including its SSH target,
			# enabled state and session. Do not duplicate its catalog in this loop.
			machine=remote
			;;
	esac
	if [ "$machine" = local ]; then
		HERDR_NATIVE_ATTACH_TARGET_FILE="$file" HERDR_NATIVE_ATTACH_TARGET="$target" \
			HERDR_NATIVE_ATTACH_READY_FILE="$on" \
			"$local_herdr" --session "$session" terminal native-attach "$terminal" </dev/tty &
	else
		# The local Unix client attaches through the saved profile's SSH socket
		# bridge; this also works with a Windows Herdr server.
		HERDR_NATIVE_ATTACH_TARGET_FILE="$file" HERDR_NATIVE_ATTACH_TARGET="$target" \
			HERDR_NATIVE_ATTACH_READY_FILE="$on" \
			"$local_herdr" --machine "$selector" terminal native-attach "$terminal" </dev/tty &
	fi
	child=$!
	# The client publishes .on only after native READY. Its per-input target
	# check revokes old input even if this observer is delayed or stopped.
	switched=0
	while kill -0 "$child" 2>/dev/null; do
		if [ "$(cat "$file" 2>/dev/null)" != "$target" ]; then
			# Herdr's SIGTERM handler restores the local TTY and releases only
			# this attach connection. It never signals the server's PTY child.
			kill -TERM "$child" 2>/dev/null
			switched=1
			break
		fi
		sleep 0.2
	done
	wait "$child"
	status=$?
	child=
	: > "$on"
	[ "$switched" -eq 0 ] && [ "$(cat "$file" 2>/dev/null)" = "$target" ] || {
		failures=0
		continue
	}
	if [ "$status" -ne 0 ] && [ "$failures" -lt 5 ]; then
		# A pane that isn't laid out yet has no size and Herdr refuses it; try again shortly.
		failures=$((failures + 1))
		sleep 1
		continue
	fi
	# Same target: the user detached, or attaching keeps failing. Wait for a new one.
	failures=0
	waiting="$target"
	printf '\033[2J\033[H'
	if [ "$status" -ne 0 ]; then
		if [ "$machine" = local ]; then
			printf 'Attaching to %s in local session %s failed (exit %s).\n' "$terminal" "$session" "$status"
		else
			printf 'Attaching to %s on saved profile %s failed (exit %s).\n' "$terminal" "$selector" "$status"
		fi
	fi
	printf 'Detached. Pick a pane in the Herdr sidebar, or close this block.\n'
done
