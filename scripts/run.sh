#!/usr/bin/env bash

# Smoke test and integration test.
# Starts EMQX cluster with 3 nodes, 2 cores and 1 replicant.

set -euo pipefail

cd -P -- "$(dirname -- "$0")/../"

PLUGIN="emqx_mcp_gateway"
PLUGIN_VSN="$(grep -o 'plugin_rel_vsn, "[^"]*"' rebar.config | cut -d'"' -f2)"
PLUGIN_NAME_VSN="$PLUGIN-$PLUGIN_VSN"

HAPROXY_PORTS=(-p 18083:18083 -p 1883:1883)

NET='emqx.io'
NODE1="node1.$NET"
NODE2="node2.$NET"
COOKIE='erlang-cookie'

cleanup() {
    docker rm -f haproxy >/dev/null 2>&1 || true
    docker rm -f "$NODE1" >/dev/null 2>&1 || true
    docker rm -f "$NODE2" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}

show_help() {
    echo "Usage: $0 [options] EMQX_IMAGE"
    echo ""
    echo "Specifiy which docker image to run with EMQX_IMAGE"
    echo ""
    echo "Options:"
    echo "  -h, --help: Show this help message and exit."
    echo "  -c: Cleanup: delete docker network, force delete the containers."
}

while getopts "hc6Pd:" opt
do
    case $opt in
        c) cleanup; exit 0;;
        h) show_help; exit 0;;
        *) ;;
    esac
done
shift $((OPTIND - 1))

IMAGE="${1:-}"

if [ -z "${IMAGE:-}" ]; then
    show_help
    exit 1
fi

cleanup

docker network create "$NET"

case "$IMAGE" in
    emqx/emqx-enterprise:5.8*)
        LICENSE_KEY="default"
        ;;
    emqx/emqx-enterprise:5.9*)
        LICENSE_KEY="evaluation"
        ;;
    *)
        show_help
        exit 1
esac

function run_emqx() {
    local node="$1"
    local name="$2"
    local role="$3"

    docker run -d -t --restart=always --name "$name" \
      --net "$NET" \
      -e EMQX_LOG__CONSOLE__LEVEL=debug \
      -e EMQX_NODE_NAME="emqx@$node" \
      -e EMQX_NODE_COOKIE="$COOKIE" \
      -e EMQX_NODE__ROLE="$role" \
      -e EMQX_LICENSE__KEY="${LICENSE_KEY}" \
      -e EMQX_PLUGINS__STATES="[{enable = true, name_vsn = \"$PLUGIN_NAME_VSN\"}]" \
      "$IMAGE"
}

function copy_files() {
    local container="$1"

    docker exec -t "$container" bash -c '\
        mkdir -p /opt/emqx/plugins && \
        mkdir -p /opt/emqx/data/plugins/$PLUGIN && \
        mkdir -p /tmp/test_data'

    docker cp "$(pwd)/_build/default/emqx_plugrel/." "$container:/opt/emqx/plugins"
    docker cp "$(pwd)/test/config/." "$container:/opt/emqx/data/plugins/$PLUGIN"
    docker cp "$(pwd)/test/data/." "$container:/tmp/test_data"

    docker exec -u root:root -t "$container" bash -c '\
        chown -R emqx:emqx /opt/emqx/plugins && \
        chown -R emqx:emqx /opt/emqx/data/plugins/$PLUGIN && \
        chown -R emqx:emqx /tmp/test_data'
}

init_python_env() {
    local container="$1"

    docker exec -t -u root:root "$container" bash -c '\
        apt update && \
        apt install python3-venv -y && \
        python3 -m venv /tmp/venv-mcp && \
        source /tmp/venv-mcp/bin/activate && \
        python3 -m pip install --no-cache-dir --upgrade pip && \
        python3 -m pip install "mcp[cli]"'
}

restart_plugin() {
    local container="$1"
    date -u +"%Y-%m-%dT%H:%M:%SZ"
    echo "restarting plugin $PLUGIN_NAME_VSN on $container"
    docker exec -t "$container" emqx ctl plugins stop $PLUGIN_NAME_VSN
    docker exec -t "$container" emqx ctl plugins start $PLUGIN_NAME_VSN
}

run_emqx "$NODE1" "$NODE1" "core"
run_emqx "$NODE2" "$NODE2" "core"

copy_files "$NODE1"
copy_files "$NODE2"

init_python_env "$NODE1"
init_python_env "$NODE2"

restart_plugin "$NODE1"
restart_plugin "$NODE2"

mkdir -p tmp
cat <<EOF > tmp/haproxy.cfg
global
    log stdout format raw daemon debug
    # Replace 1024000 with deployment connections
    maxconn 102400
    nbproc 1
    nbthread 2
    cpu-map auto:1/1-2 0-1
    # e.g. echo "show table emqx_tcp_back" | sudo socat stdio tcp4-connect:172.100.239.4:9999
    stats socket :9999 level admin expose-fd listeners

defaults
    log global
    mode tcp
    option tcplog
    # Replace 1024000 with deployment connections
    maxconn 102400
    timeout connect 30000
    timeout client 600s
    timeout server 600s

frontend emqx_dashboard
    mode tcp
    option tcplog
    bind *:18083
    default_backend emqx_dashboard_back

backend emqx_dashboard_back
    balance source
    mode http
    server emqx-1 $NODE1:18083
    server emqx-2 $NODE2:18083

frontend emqx_tcp
    mode tcp
    option tcplog
    bind *:1883
    default_backend emqx_backend_tcp

backend emqx_backend_tcp
    mode tcp
    server emqx-1 $NODE1:1883
    server emqx-2 $NODE2:1883
EOF

HAPROXY_IMAGE='ghcr.io/haproxytech/haproxy-docker-alpine:2.4.27'

docker run -d --name haproxy \
    --net "$NET" \
    -v "$(pwd)/tmp/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg" \
    "${HAPROXY_PORTS[@]}" \
    "${HAPROXY_IMAGE}" \
    haproxy -f /usr/local/etc/haproxy/haproxy.cfg

wait_for_emqx() {
    container="$1"
    wait_limit="$2"
    wait_sec=0
    while ! docker exec "$container" emqx ctl status >/dev/null 2>&1; do
        wait_sec=$(( wait_sec + 1 ))
        if [ $wait_sec -gt "$wait_limit" ]; then
            echo "timeout wait for EMQX"
            docker logs "$container"
            exit 1
        fi
        echo -n '.'
        sleep 1
    done
}

wait_for_running_nodes() {
    local container="$1"
    local expected_running_nodes="$2"
    local wait_limit="$3"
    local wait_sec=0
    while [ "${wait_sec}" -lt "${wait_limit}" ]; do
        running_nodes="$(docker exec -t "$container" emqx ctl cluster status --json)"
        echo -e "running_nodes: $running_nodes\n"
        running_nodes="$(echo "$running_nodes" | jq -r '.running_nodes | length')"
        if [ "${running_nodes}" -eq "${expected_running_nodes}" ]; then
            echo "Successfully confirmed ${running_nodes} running nodes."
            return
        fi
        if [ "$wait_sec" -gt "$wait_limit" ]; then
            echo "Expected running nodes is ${expected_running_nodes}, but got ${running_nodes} after ${wait_limit} seconds"
            docker logs "$container"
            exit 1
        fi
        wait_sec=$(( wait_sec + 1 ))
        echo -n '.'
        sleep 1
    done
}

wait_for_emqx "$NODE1" 60
wait_for_emqx "$NODE2" 30

echo

docker exec "${NODE2}" emqx ctl cluster join "emqx@$NODE1"

wait_for_running_nodes "$NODE1" "2" 30

validate_plugin() {
    local container="$1"
    local plugin_info
    plugin_info=$(docker exec -t "$container" emqx ctl plugins list | jq -r '.[] | select(.name == "'$PLUGIN'")')
    if [ -z "$plugin_info" ]; then
        echo "Error: Plugin $PLUGIN not found in node $container"
        exit 1
    fi
    local plugin_vsn
    plugin_vsn=$(echo "$plugin_info" | jq -r '.rel_vsn')
    if [ "$plugin_vsn" != "$PLUGIN_VSN" ]; then
        echo "Error: Plugin version mismatch. Expected [$PLUGIN_VSN] but got [$plugin_vsn] in node $container"
        exit 1
    fi
    local running_status
    running_status=$(echo "$plugin_info" | jq -r '.running_status')
    if [ "$running_status" != "running" ]; then
        echo "Error: Plugin is not running. Current status: $running_status in node $container"
        echo "Logs:"
        docker logs "$container"
        exit 1
    fi
}

validate_plugin "$NODE1"
validate_plugin "$NODE2"
echo "Plugin $PLUGIN_NAME_VSN is running in all nodes."
