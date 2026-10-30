#!/usr/bin/env bats
#
# pi/extensions/vmapi。中身は node --test の単体テスト (test/pi-vmapi.test.ts と
# test/pi-vmapi-tools.test.ts)。

load helpers

@test "the vmapi extension's client passes its unit tests" {
    require node
    # .ts をそのまま読める (type stripping) 版が要る。
    node -e 'process.exit(process.features.typescript ? 0 : 1)' 2> /dev/null ||
        skip "node cannot run TypeScript directly"
    run node --test "${REPO}/test/pi-vmapi.test.ts"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "the vm tools call the API and their output schemas let unknown keys and values through" {
    require node
    require pi
    node -e 'process.exit(process.features.typescript ? 0 : 1)' 2> /dev/null ||
        skip "node cannot run TypeScript directly"
    # index.ts は pi が読み込むときに pi 同梱の typebox を使う。テストでも同じものを横に置く。
    pkg=$(readlink -f "$(command -v pi)")
    while [ "${pkg}" != / ] && [ "$(basename "${pkg}")" != pi-coding-agent ]; do
        pkg=$(dirname "${pkg}")
    done
    [ -d "${pkg}/node_modules/typebox" ] || skip "typebox is not found next to pi"
    ext="${BATS_TEST_TMPDIR}/vmapi"
    cp -R "${REPO}/pi/extensions/vmapi" "${ext}"
    mkdir "${ext}/node_modules"
    ln -s "${pkg}/node_modules/typebox" "${ext}/node_modules/typebox"
    # ツールは ~/.config/vmapi/tokens/pi を読む。偽の HOME に置く。
    home="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${home}/.config/vmapi/tokens"
    printf 'secret\n' > "${home}/.config/vmapi/tokens/pi"
    chmod 0600 "${home}/.config/vmapi/tokens/pi"
    HOME="${home}" VMAPI_EXTENSION="${ext}" run node --test "${REPO}/test/pi-vmapi-tools.test.ts"
    echo "$output"
    [ "$status" -eq 0 ]
}
