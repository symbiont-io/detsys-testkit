#!/usr/bin/env bash

# Change directory to the source directory of this script. Taken from:
# https://stackoverflow.com/a/246128/3858681
pushd "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )" > /dev/null

if [ "$1" == "--version" ]; then
    cat $(which detsys-generator-version)
    echo ""
    exit 0
fi

TEST="$1"
DETSYS_DB=${DETSYS_DB:-"${HOME}/.detsys.db"}

# Create test.
TEST_ID=$(sqlite3 "${DETSYS_DB}" "SELECT IFNULL(max(test_id),-1)+1 from test_info")

META=''
DATA=''

if [ "${TEST}" == "register" ]; then
    META=$(cat <<END_META
{"component": "detsys-generator", "test-id": ${TEST_ID}}
END_META
        )
    DATA=$(cat <<END_DATA
 {"agenda":[{"kind": "invoke", "event": "write", "args": {"value": 1}, "from": "client:0", "to": "frontend", "at": "1970-01-01T00:00:00Z"}, {"kind": "invoke", "event": "read", "args": {}, "from": "client:0", "to": "frontend", "at": "1970-01-01T00:00:10Z"}], "deployment": [{"reactor": "frontend", "type": "frontend", "args": {"inFlight":{},"inFlightSessionToClient":{},"nextSessionId":0}}, {"reactor": "register1", "type": "register", "args": {"value":[]}}, {"reactor": "register2", "type": "register", "args": {"value":[]}}]}
END_DATA
        )
elif [ "${TEST}" == "broadcast" ]; then
    META=$(cat <<END_META
{"component": "detsys-generator", "test-id": ${TEST_ID}}
END_META
        )
    DATA=$(cat <<END_DATA
{"agenda":[], "deployment": [{"reactor": "A", "type": "node", "args": {"name":"A","log":"Hello world!","neighbours":{"B":true,"C":true},"round":""}} , {"reactor": "B", "type": "node", "args": {"name":"B","log":"","neighbours":{"C":""},"round":""}} , {"reactor": "C", "type": "node", "args": {"name":"C","log":"","neighbours":{"B":""},"round":""}}]}
END_DATA
        )
fi

sqlite3 "${DETSYS_DB}" <<EOF
INSERT INTO event_log(event, meta,data) VALUES("CreateTest", '${META}', '${DATA}')
EOF
echo "${TEST_ID}"

popd > /dev/null
