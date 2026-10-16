#!/bin/sh
# Keeps this pane attached to the Herdr terminal named in the target file.
# Targets are "SELECTOR TERMINAL_ID MODE": local/default, local/<session>,
# or a saved Herdr profile ID; MODE is explicitly native or ansi.
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
	selector=${target%% *}
	rest=${target#* }
	terminal=${rest%% *}
	mode=${rest#* }
	case "$mode" in
		native|ansi) ;;
		*)
			printf 'Invalid Herdr presentation mode in target file.\n' >&2
			waiting="$target"
			continue
			;;
	esac
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
	# Check every launch, including restored layouts and a downgraded local CLI.
	# This help path never contacts a saved profile or starts its backend.
	support=$("$local_herdr" --machine 00000000000000000000000000000000 terminal native-attach --help 2>/dev/null)
	support_status=$?
	case "$support_status:$support" in
		0:*native-terminal-attach-v1*scoped-terminal-attach-v2*) ;;
		*)
			printf 'Herdr viewer unavailable: upgrade local HERDR_BIN to scoped-terminal-attach-v2; inventory remains available.\n' >&2
			exit 1
			;;
	esac
	if [ "$machine" = local ]; then
		set -- "$local_herdr" --session "$session" terminal
	else
		# The local Unix client uses the saved profile's SSH socket bridge.
		set -- "$local_herdr" --machine "$selector" terminal
	fi
	if [ "$mode" = ansi ]; then
		set -- "$@" attach "$terminal"
	else
		set -- "$@" native-attach "$terminal"
	fi
	HERDR_ATTACH_TARGET_FILE="$file" HERDR_ATTACH_TARGET="$target" \
		HERDR_ATTACH_READY_FILE="$on" "$@" </dev/tty &
	child=$!
	# The client publishes .on only after native READY or the first approved
	# classic terminal frame. Its input guard revokes stale input even if this
	# observer is delayed or stopped.
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
