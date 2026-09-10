#!/usr/bin/env bash
#
# Runs tageditor's two development servers from the checkout in the working
# directory: the API under uvicorn --reload, and the frontend under vite, which
# proxies /api to it on 127.0.0.1:8000 -- so the API needs no other address.
#
# When either one stops, the other is stopped and the script exits non-zero,
# whatever the status was. Half of the app is no app, and a container that
# exits is one restart: always brings back whole.

set -uo pipefail

(cd backend && exec uv run uvicorn app.main:app --reload --host 127.0.0.1 --port 8000) &
backend=$!
(cd frontend && exec npm run dev -- --host 0.0.0.0 --port 5173) &
frontend=$!

stop() {
    kill "${backend}" "${frontend}" 2> /dev/null
}
trap stop TERM INT

wait -n "${backend}" "${frontend}"
status=$?
stop
wait

if (( status == 0 )); then
    status=1
fi
exit "${status}"
