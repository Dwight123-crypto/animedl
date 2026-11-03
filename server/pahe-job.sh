#!/usr/bin/env bash
#
# Download one episode using the functions from animepahe-dl.sh, without its
# interactive fzf prompts. Called by server.py, one process per episode.
#
# Usage: pahe-job.sh <anime_slug> <anime_title> <episode> [resolution] [audio]
# Env:   PAHE_SCRIPT        path to animepahe-dl.sh
#        PAHE_DOWNLOAD_DIR  where "<anime>/<episode>.mp4" is written

set -euo pipefail

# animepahe-dl.sh only runs main() when executed directly, so sourcing it just
# defines its functions.
# shellcheck source=/dev/null
source "$PAHE_SCRIPT"

# set_args with no arguments only sets defaults (e.g. the 1080p fallback).
set_args
# Reads config.json (cf_clearance + user-agent) from this script's directory.
set_var
check_config

_SCRIPT_PATH="$PAHE_DOWNLOAD_DIR"
_ANIME_SLUG="$1"
_ANIME_NAME="$(sed -E 's/[[:space:]]+$//; s/[^[:alnum:] ,\+\-\)\(]/_/g' <<< "$2")"
_ANIME_EPISODE="$3"
if [[ -n "${4:-}" ]]; then _ANIME_RESOLUTION="$4"; fi
if [[ -n "${5:-}" ]]; then _ANIME_AUDIO="$5"; fi

# Tell server.py where the file will land.
echo "@@FILE $_ANIME_NAME/$_ANIME_EPISODE.mp4"

download_source
download_episodes "$_ANIME_EPISODE"
