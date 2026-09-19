#!/usr/bin/env bash
# BEVERLY — the norm-s115 champion, on the server.
#
#   bot/beverly.sh                      play briankeegan's server
#   bot/beverly.sh <ip> [port] [name]   somewhere else
#
# The weights are bot/profiles/beverly.json. Everything about HOW it is run
# lives in bot/plamp.sh, which this hands off to: one launcher, one cadence
# rule, one place to fix. Only the weight set and the name differ.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
export PA_SEARCH_PROFILE="${PA_SEARCH_PROFILE:-bot/profiles/beverly.json}"
exec "$here/plamp.sh" "${1:-104.156.250.136}" "${2:-49569}" "${3:-Beverly}"
