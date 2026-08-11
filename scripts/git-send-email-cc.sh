#!/bin/sh
# git-send-email appends the current patch path; only read the explicit list.
set -eu

if [ "$#" -lt 1 ]; then
	echo "usage: $0 RECIPIENTS_FILE [PATCH_FILE]" >&2
	exit 2
fi

cat -- "$1"
