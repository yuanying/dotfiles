#!/usr/bin/env bats

# The entrypoints baked into the app images. Each one runs in the container's
# working directory, which compose sets to the app's source checkout; here that
# is a scratch directory and the toolchains are stand-ins that record how they
# were called.

bats_require_minimum_version 1.5.0

load helpers

setup() {
    APPS="${REPO}/devbox/apps"
    STUB_DIR="${BATS_TEST_TMPDIR}/stub"
    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${STUB_DIR}/bin" "${WORK}"
    export STUB_DIR
    PATH="${STUB_DIR}/bin:${PATH}"
    cd "${WORK}"
}

stub() {
    cat > "${STUB_DIR}/bin/$1"
    chmod +x "${STUB_DIR}/bin/$1"
}

alive() {
    kill -0 "$1" 2> /dev/null
}

# --- sd-webui --------------------------------------------------------------

@test "sd-webui runs launch.py with the venv's python and the given arguments" {
    mkdir -p venv/bin
    cat > venv/bin/python <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${STUB_DIR}/python.args"
echo "${VIRTUAL_ENV}" > "${STUB_DIR}/python.venv"
command -v python > "${STUB_DIR}/python.which"
EOF
    chmod +x venv/bin/python
    run "${APPS}/sd-webui/entrypoint.sh" --listen --api
    [ "${status}" -eq 0 ]
    [ "$(cat "${STUB_DIR}/python.args")" = "launch.py
--listen
--api" ]
    [ "$(cat "${STUB_DIR}/python.venv")" = "${WORK}/venv" ]
    [ "$(cat "${STUB_DIR}/python.which")" = "${WORK}/venv/bin/python" ]
}

@test "sd-webui without a venv fails instead of making one" {
    run "${APPS}/sd-webui/entrypoint.sh" --listen
    [ "${status}" -ne 0 ]
    [[ ${output} == *venv* ]]
    [ ! -e venv ]
}

# --- sd-viewer -------------------------------------------------------------

@test "sd-viewer builds the checkout and runs the result with the given arguments" {
    stub go <<'EOF'
#!/bin/bash
echo "$*" > "${STUB_DIR}/go.args"
out=
while (( $# )); do
    [[ $1 == -o ]] && out=$2
    shift
done
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/viewer.args"\n' "${STUB_DIR}" > "${out}"
chmod +x "${out}"
EOF
    TMPDIR="${BATS_TEST_TMPDIR}" run "${APPS}/sd-viewer/entrypoint.sh" --webui-url http://sd-webui:7860
    [ "${status}" -eq 0 ]
    [ "$(cat "${STUB_DIR}/go.args")" = "build -o ${BATS_TEST_TMPDIR}/sd-viewer ./cmd/sd-viewer" ]
    [ "$(cat "${STUB_DIR}/viewer.args")" = "--webui-url
http://sd-webui:7860" ]
}

@test "sd-viewer that does not build does not start" {
    stub go <<'EOF'
#!/bin/bash
echo "compile error" >&2
exit 1
EOF
    TMPDIR="${BATS_TEST_TMPDIR}" run "${APPS}/sd-viewer/entrypoint.sh"
    [ "${status}" -ne 0 ]
    [ ! -e "${STUB_DIR}/viewer.args" ]
}

# --- tageditor -------------------------------------------------------------

# A process that stays up: records where and how it was started, then sleeps
# with its pid written down so the test can see whether it was stopped.
long_running() {
    stub "$1" <<EOF
#!/bin/bash
echo "\${PWD} \$*" > "\${STUB_DIR}/$1.args"
echo \$\$ > "\${STUB_DIR}/$1.pid"
exec sleep 30 > /dev/null 2>&1
EOF
}

exits_with() {
    stub "$1" <<EOF
#!/bin/bash
echo "\${PWD} \$*" > "\${STUB_DIR}/$1.args"
exit $2
EOF
}

@test "tageditor starts the backend and the dev server in their directories" {
    mkdir backend frontend
    long_running uv
    exits_with npm 3
    run timeout 10 "${APPS}/tageditor/entrypoint.sh"
    [ "$(cat "${STUB_DIR}/uv.args")" = "${WORK}/backend run uvicorn app.main:app --reload --host 127.0.0.1 --port 8000" ]
    [ "$(cat "${STUB_DIR}/npm.args")" = "${WORK}/frontend run dev -- --host 0.0.0.0 --port 5173" ]
}

@test "tageditor goes down when the dev server does" {
    mkdir backend frontend
    long_running uv
    exits_with npm 3
    run timeout 10 "${APPS}/tageditor/entrypoint.sh"
    [ "${status}" -eq 3 ]
    ! alive "$(cat "${STUB_DIR}/uv.pid")"
}

@test "tageditor goes down when the backend does" {
    mkdir backend frontend
    exits_with uv 4
    long_running npm
    run timeout 10 "${APPS}/tageditor/entrypoint.sh"
    [ "${status}" -eq 4 ]
    ! alive "$(cat "${STUB_DIR}/npm.pid")"
}

@test "tageditor goes down even when a process exits cleanly" {
    mkdir backend frontend
    long_running uv
    exits_with npm 0
    run timeout 10 "${APPS}/tageditor/entrypoint.sh"
    [ "${status}" -ne 0 ]
    [ "${status}" -ne 124 ]
    ! alive "$(cat "${STUB_DIR}/uv.pid")"
}
