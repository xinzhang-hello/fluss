#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="infra.fluss.fluss"
# Service path defaults to /data/service/fluss
DEFAULT_APP_DIR="/data/service/fluss"
if [ -z "${APP_DIR:-}" ]; then
    if [ -d "${PARENT_DIR}/bin" ] || [ -d "${PARENT_DIR}/fluss/bin" ]; then
        APP_DIR="${PARENT_DIR}"
    else
        APP_DIR="${DEFAULT_APP_DIR}"
    fi
fi

# Locate Fluss installation directory
if [ -d "${APP_DIR}/bin" ]; then
    FLUSS_HOME="${APP_DIR}"
elif [ -d "${APP_DIR}/fluss/bin" ]; then
    FLUSS_HOME="${APP_DIR}/fluss"
else
    FLUSS_HOME="${APP_DIR}"
fi
cd "${FLUSS_HOME}"

echo "=== [Post-Deploy] Starting post-deploy script for ${APP_NAME} ==="
echo "Working directory: ${FLUSS_HOME}"

# 1. Setup Java 17 environment
if [ -z "${JAVA_HOME:-}" ]; then
    for candidate in \
        "/data/sdk/jdk17" \
        "/data/sdk/jdk-17" \
        "/usr/local/java/jdk-17" \
        "/usr/lib/jvm/java-17-openjdk" \
        "/usr/lib/jvm/java-17" \
        "/data/sdk/jdk11"; do
        if [ -d "${candidate}" ] && [ -x "${candidate}/bin/java" ]; then
            export JAVA_HOME="${candidate}"
            break
        fi
    done
fi
export JAVA_HOME="${JAVA_HOME:-/data/sdk/jdk17}"

if [ -d "${JAVA_HOME}" ]; then
    export PATH="${JAVA_HOME}/bin:${PATH}"
    echo "Using JAVA_HOME: ${JAVA_HOME}"
else
    echo "JAVA_HOME not explicitly set, using system default: $(which java || true)"
fi

# Verify Java is available
if ! command -v java >/dev/null 2>&1; then
    echo "ERROR: Java not found. Please install JDK 17 or set JAVA_HOME." >&2
    exit 1
fi
java -version

# 2. Setup Logging and Data directories
export FLUSS_LOG_DIR="${FLUSS_LOG_DIR:-/data/log/fluss}"
mkdir -p "${FLUSS_LOG_DIR}" 2>/dev/null || true

# Prepare data directories (/mnt/storage00 and /mnt/storage01)
mkdir -p /mnt/storage00/fluss/data /mnt/storage01/fluss/data 2>/dev/null || true

# 3. Setup Hadoop environment for HDFS remote storage if available
if [ -z "${HADOOP_HOME:-}" ]; then
    for candidate in "/data/service/hadoop-3.3.2-SNAPSHOT" "/data/service/hadoop" "/usr/local/hadoop"; do
        if [ -d "${candidate}" ]; then
            export HADOOP_HOME="${candidate}"
            break
        fi
    done
fi
if [ -n "${HADOOP_HOME:-}" ]; then
    export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-${HADOOP_HOME}/etc/hadoop}"
    if [ -z "${HADOOP_CLASSPATH:-}" ]; then
        export HADOOP_CLASSPATH="${HADOOP_CONF_DIR}:${HADOOP_HOME}/share/hadoop/common/lib/*:${HADOOP_HOME}/share/hadoop/common/*:${HADOOP_HOME}/share/hadoop/hdfs:${HADOOP_HOME}/share/hadoop/hdfs/lib/*:${HADOOP_HOME}/share/hadoop/hdfs/*"
    fi
    echo "Using Hadoop: HADOOP_HOME=${HADOOP_HOME}"
fi

# 3.1 Setup Kerberos keytab environment for HDFS remote storage
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")
HOST_SHORT="$(hostname 2>/dev/null | cut -d. -f1)"
KRB5_REALM="${KRB5_REALM:-BILIBILI.CO}"

# Keytab path defaults to /etc/security/keytabs/kafka.service.keytab
if [ -z "${KRB5KEYTAB:-}" ]; then
    for candidate in \
        "/etc/security/keytabs/kafka.service.keytab" \
        "/data/service/fluss/conf/fluss.keytab" \
        "${FLUSS_HOME}/conf/fluss.keytab"; do
        if [ -f "${candidate}" ]; then
            KRB5KEYTAB="${candidate}"
            break
        fi
    done
fi
export KRB5KEYTAB="${KRB5KEYTAB:-/etc/security/keytabs/kafka.service.keytab}"
export KRB5_CONFIG="${KRB5_CONFIG:-/etc/krb5.conf}"

# Auto-detect principal from keytab if klist is available
if [ -z "${KRB5PRINCIPAL:-}" ] && [ -f "${KRB5KEYTAB}" ] && command -v klist >/dev/null 2>&1; then
    DETECTED_PRINCIPAL=$(klist -kt "${KRB5KEYTAB}" 2>/dev/null | awk '{print $NF}' | grep '@' | tail -n 1 || true)
    if [ -n "${DETECTED_PRINCIPAL}" ]; then
        export KRB5PRINCIPAL="${DETECTED_PRINCIPAL}"
        echo "Auto-detected Kerberos principal from keytab: ${KRB5PRINCIPAL}"
    fi
fi

# Fallback principal: prefer kafka/<hostname>@REALM since keytab is kafka.service.keytab
if [ -z "${KRB5PRINCIPAL:-}" ]; then
    if [[ "${HOSTNAME_FQDN}" == *"."* ]]; then
        export KRB5PRINCIPAL="kafka/${HOSTNAME_FQDN}@${KRB5_REALM}"
    elif [ -n "${HOST_SHORT}" ]; then
        export KRB5PRINCIPAL="kafka/${HOST_SHORT}.host.bilibili.co@${KRB5_REALM}"
    else
        export KRB5PRINCIPAL="kafka/${HOSTNAME_FQDN}@${KRB5_REALM}"
    fi
fi

echo "Kerberos principal: ${KRB5PRINCIPAL}"
echo "Kerberos keytab: ${KRB5KEYTAB}"
echo "Kerberos config: ${KRB5_CONFIG}"

# Perform kinit if keytab exists to initialize ticket cache
if [ -f "${KRB5KEYTAB}" ] && command -v kinit >/dev/null 2>&1; then
    echo "Initializing Kerberos ticket via keytab: ${KRB5PRINCIPAL} (${KRB5KEYTAB})"
    kinit -kt "${KRB5KEYTAB}" "${KRB5PRINCIPAL}" || {
        echo "WARNING: kinit failed for ${KRB5PRINCIPAL} using ${KRB5KEYTAB}" >&2
    }
    if command -v klist >/dev/null 2>&1; then
        echo "Current Kerberos ticket cache:"
        klist || true
    fi
else
    if [ ! -f "${KRB5KEYTAB}" ]; then
        echo "WARNING: Kerberos keytab not found at ${KRB5KEYTAB}." >&2
    fi
fi

# 4. System limits and ensure scripts are executable
ulimit -n 655360 2>/dev/null || true
chmod +x bin/*.sh 2>/dev/null || true
chmod +x bilibili-cicd/*.sh 2>/dev/null || true

# Optional JVM overrides from Wave environment variables
if [ -n "${COORDINATOR_JVM_OPTS:-}" ]; then
    export FLUSS_ENV_JAVA_OPTS_CS="${COORDINATOR_JVM_OPTS}"
fi
if [ -n "${TABLET_JVM_OPTS:-}" ]; then
    export FLUSS_ENV_JAVA_OPTS_TS="${TABLET_JVM_OPTS}"
fi
if [ -n "${COMMON_JVM_OPTS:-}" ]; then
    export FLUSS_ENV_JAVA_OPTS="${COMMON_JVM_OPTS}"
fi

# 5. Determine which service(s) to start
# FLUSS_ROLE can be: coordinator | tablet | all (default: tablet)
# Supports aliases: tablet-server, table-server, coordinator-server
# Can be configured in Wave deploy environment variables
FLUSS_ROLE="${FLUSS_ROLE:-tablet}"
case "${FLUSS_ROLE}" in
    tablet|tablet-server|table|table-server)
        FLUSS_ROLE="tablet"
        ;;
    coordinator|coordinator-server)
        FLUSS_ROLE="coordinator"
        ;;
    all)
        FLUSS_ROLE="all"
        ;;
esac

echo "Target service role: ${FLUSS_ROLE}"

# Derive TABLET_SERVER_ID if not explicitly provided
if [ -z "${TABLET_SERVER_ID:-}" ]; then
    HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname 2>/dev/null | cut -d. -f1)
    HOST_NUM=$(echo "${HOSTNAME_SHORT}" | grep -o '[0-9]\+$' || true)
    if [ -n "${HOST_NUM}" ]; then
        DEC_NUM=$((10#${HOST_NUM}))
        # Hosts are 1-based in cluster: test-01 -> 1, test-02 -> 2, ..., test-05 -> 5
        TABLET_SERVER_ID=${DEC_NUM}
        echo "Auto-derived tablet-server.id from hostname (${HOSTNAME_SHORT}): ${TABLET_SERVER_ID}"
    else
        TABLET_SERVER_ID=1
    fi
fi
export TABLET_SERVER_ID

# Optional server.yaml tuning if environment overrides or dynamic parameters are provided
if [ -f "conf/server.yaml" ]; then
    LOCAL_IP=$(hostname -i 2>/dev/null | awk '{print $1}' || true)
    if [ -z "${LOCAL_IP}" ] || [ "${LOCAL_IP}" = "127.0.0.1" ]; then
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi

    if [ -n "${ZOOKEEPER_ADDRESS:-}" ]; then
        echo "Overriding zookeeper.address to ${ZOOKEEPER_ADDRESS}"
        sed -i "s|^zookeeper.address:.*|zookeeper.address: ${ZOOKEEPER_ADDRESS}|" conf/server.yaml
        if [ -f "conf-coord/server.yaml" ]; then
            sed -i "s|^zookeeper.address:.*|zookeeper.address: ${ZOOKEEPER_ADDRESS}|" conf-coord/server.yaml
        fi
    fi
    if [ -n "${HDFS_NAMENODE_PRINCIPAL:-}" ]; then
        sed -i "s|^fluss.hadoop.dfs.namenode.kerberos.principal:.*|fluss.hadoop.dfs.namenode.kerberos.principal: ${HDFS_NAMENODE_PRINCIPAL}|" conf/server.yaml
        if [ -f "conf-coord/server.yaml" ]; then
            sed -i "s|^fluss.hadoop.dfs.namenode.kerberos.principal:.*|fluss.hadoop.dfs.namenode.kerberos.principal: ${HDFS_NAMENODE_PRINCIPAL}|" conf-coord/server.yaml
        fi
    fi

    # 1) Configure conf/server.yaml for TabletServer (or coordinator if explicitly running alone)
    if [ "${FLUSS_ROLE}" = "coordinator" ]; then
        # Coordinator dual listeners: INTERNAL (9122), CLIENT (9123), metrics (9249)
        sed -i "s|:9125|:9122|g" conf/server.yaml
        sed -i "s|:9124|:9123|g" conf/server.yaml
        sed -i "s|^metrics.reporter.prometheus.port:.*|metrics.reporter.prometheus.port: 9249|" conf/server.yaml
        sed -i "/^tablet-server.id:/d" conf/server.yaml
        if [ -n "${LOCAL_IP}" ]; then
            if grep -q "^advertised.listeners:" conf/server.yaml; then
                sed -i "s|^advertised.listeners:.*|advertised.listeners: INTERNAL://${LOCAL_IP}:9122, CLIENT://${LOCAL_IP}:9123|" conf/server.yaml
            else
                echo "advertised.listeners: INTERNAL://${LOCAL_IP}:9122, CLIENT://${LOCAL_IP}:9123" >> conf/server.yaml
            fi
        fi
    else
        # tablet or all (conf/server.yaml serves TabletServer)
        if [ -n "${TABLET_SERVER_ID:-}" ]; then
            echo "Configuring tablet-server.id to ${TABLET_SERVER_ID}"
            sed -i "s|^tablet-server.id:.*|tablet-server.id: ${TABLET_SERVER_ID}|" conf/server.yaml
        fi
        if [ -n "${LOCAL_IP}" ]; then
            if grep -q "^advertised.listeners:" conf/server.yaml; then
                sed -i "s|^advertised.listeners:.*|advertised.listeners: INTERNAL://${LOCAL_IP}:9125, CLIENT://${LOCAL_IP}:9124|" conf/server.yaml
            else
                echo "advertised.listeners: INTERNAL://${LOCAL_IP}:9125, CLIENT://${LOCAL_IP}:9124" >> conf/server.yaml
            fi
        fi
    fi

    # 2) Configure advertised.listeners for pre-packaged conf-coord/server.yaml
    if [ -n "${LOCAL_IP}" ] && [ -f "conf-coord/server.yaml" ]; then
        if grep -q "^advertised.listeners:" conf-coord/server.yaml; then
            sed -i "s|^advertised.listeners:.*|advertised.listeners: INTERNAL://${LOCAL_IP}:9122, CLIENT://${LOCAL_IP}:9123|" conf-coord/server.yaml
        else
            echo "advertised.listeners: INTERNAL://${LOCAL_IP}:9122, CLIENT://${LOCAL_IP}:9123" >> conf-coord/server.yaml
        fi
    fi
fi

# Align existing disk.properties with target TABLET_SERVER_ID to prevent startup conflict
if [ "${FLUSS_ROLE}" = "tablet" ] || [ "${FLUSS_ROLE}" = "all" ]; then
    for data_dir in /mnt/storage00/fluss/data /mnt/storage01/fluss/data; do
        prop_file="${data_dir}/disk.properties"
        if [ -f "${prop_file}" ]; then
            disk_id=$(grep '^server.id=' "${prop_file}" 2>/dev/null | cut -d= -f2 || true)
            if [ -n "${disk_id}" ] && [ "${disk_id}" != "${TABLET_SERVER_ID}" ]; then
                echo "Aligning ${prop_file} server.id (${disk_id} -> ${TABLET_SERVER_ID})"
                sed -i "s|^server.id=.*|server.id=${TABLET_SERVER_ID}|" "${prop_file}"
            fi
        fi
    done
fi

# 4.1 Systemd service and drop-in configuration
if [ -f "${SCRIPT_DIR}/init_systemd.sh" ]; then
    echo "Running systemd initialization for role '${FLUSS_ROLE}'..."
    bash "${SCRIPT_DIR}/init_systemd.sh" "${FLUSS_ROLE}" || {
        echo "WARNING: Systemd initialization encountered an issue. Proceeding with direct deployment." >&2
    }
fi

# Sudo detection for systemctl commands
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        SUDO="sudo"
    fi
fi

is_systemd_running() {
    [ "${USE_SYSTEMD:-auto}" != "false" ] && \
    [ -d /run/systemd/system ] && \
    command -v systemctl >/dev/null 2>&1 && \
    systemctl list-units >/dev/null 2>&1
}

start_service_unit() {
    local svc_name="$1"
    local script_path="$2"

    if is_systemd_running; then
        if [ "${svc_name}" = "fluss-coordinator-server" ]; then
            echo "Ensuring legacy fluss-coordinator service is stopped..."
            ${SUDO} systemctl stop fluss-coordinator 2>/dev/null || true
            ${SUDO} systemctl disable fluss-coordinator 2>/dev/null || true
        fi
        echo "Starting ${svc_name} via systemctl..."
        ${SUDO} systemctl enable "${svc_name}" 2>/dev/null || true
        ${SUDO} systemctl restart "${svc_name}"
    else
        if [ "${svc_name}" = "fluss-coordinator-server" ] && [ -d "conf-coord" ]; then
            echo "Starting ${svc_name} via direct script with FLUSS_CONF_DIR=conf-coord: ${script_path} start..."
            FLUSS_CONF_DIR="$(pwd)/conf-coord" "${script_path}" start
        else
            echo "Starting ${svc_name} via direct script: ${script_path} start..."
            "${script_path}" start
        fi
    fi
}

case "${FLUSS_ROLE}" in
    coordinator)
        start_service_unit "fluss-coordinator-server" "./bin/coordinator-server.sh"
        ;;
    tablet)
        start_service_unit "fluss-tablet-server" "./bin/tablet-server.sh"
        ;;
    all)
        start_service_unit "fluss-coordinator-server" "./bin/coordinator-server.sh"
        start_service_unit "fluss-tablet-server" "./bin/tablet-server.sh"
        ;;
    *)
        echo "ERROR: Unknown FLUSS_ROLE '${FLUSS_ROLE}'. Valid options: coordinator, tablet, all." >&2
        exit 1
        ;;
esac

# 6. Health check: Wait and verify service is running
echo "Verifying service startup..."
sleep 3

SERVICE_RUNNING=false
if is_systemd_running; then
    case "${FLUSS_ROLE}" in
        coordinator)
            systemctl is-active --quiet fluss-coordinator-server 2>/dev/null && SERVICE_RUNNING=true
            ;;
        tablet)
            systemctl is-active --quiet fluss-tablet-server 2>/dev/null && SERVICE_RUNNING=true
            ;;
        all)
            systemctl is-active --quiet fluss-coordinator-server 2>/dev/null && \
            systemctl is-active --quiet fluss-tablet-server 2>/dev/null && SERVICE_RUNNING=true
            ;;
    esac
fi

PIDS=$(pgrep -f "org.apache.fluss.server" || true)
if [ "${SERVICE_RUNNING}" != "true" ] && [ -z "${PIDS}" ]; then
    echo "ERROR: Fluss service failed to start. Checking recent logs..." >&2
    if is_systemd_running; then
        echo "=== Systemd journal logs ==="
        journalctl -u fluss-tablet-server -u fluss-coordinator-server -n 30 --no-pager 2>/dev/null || true
    fi
    if [ -d "${FLUSS_LOG_DIR}" ] && compgen -G "${FLUSS_LOG_DIR}/*.log" > /dev/null; then
        echo "=== Recent logs in ${FLUSS_LOG_DIR} ==="
        tail -n 30 "${FLUSS_LOG_DIR}"/*.log 2>/dev/null || true
    elif [ -d "${FLUSS_HOME}/log" ] && compgen -G "${FLUSS_HOME}/log/*.log" > /dev/null; then
        echo "=== Recent logs in ${FLUSS_HOME}/log ==="
        tail -n 30 "${FLUSS_HOME}/log"/*.log 2>/dev/null || true
    fi
    exit 1
fi
echo "Fluss service process started successfully (PIDs: ${PIDS:-systemd})."

# 6.1 Basic Port Readiness Check
echo "Checking service port bindings..."
PORT_WAIT_TIMEOUT=45
port_ready=false
while [ $PORT_WAIT_TIMEOUT -gt 0 ]; do
    ports_ok=true
    if [ "${FLUSS_ROLE}" = "tablet" ] || [ "${FLUSS_ROLE}" = "all" ]; then
        if ! (echo > /dev/tcp/127.0.0.1/9125) 2>/dev/null || ! (echo > /dev/tcp/127.0.0.1/9250) 2>/dev/null; then
            ports_ok=false
        fi
    fi
    if [ "${FLUSS_ROLE}" = "coordinator" ] || [ "${FLUSS_ROLE}" = "all" ]; then
        if ! (echo > /dev/tcp/127.0.0.1/9122) 2>/dev/null || ! (echo > /dev/tcp/127.0.0.1/9249) 2>/dev/null; then
            ports_ok=false
        fi
    fi
    if [ "${ports_ok}" = "true" ]; then
        port_ready=true
        echo "Required service ports are successfully bound."
        break
    fi
    sleep 2
    PORT_WAIT_TIMEOUT=$((PORT_WAIT_TIMEOUT - 2))
done

if [ "${port_ready}" != "true" ]; then
    echo "ERROR: Service ports failed to bind within timeout." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Health Check 1: Local Replica Catch-Up Gate (本地从副本追齐检查)
# Prevents consecutive fast rollouts from killing nodes before replicas sync.
# ------------------------------------------------------------------------------
if [ "${FLUSS_ROLE}" = "tablet" ] || [ "${FLUSS_ROLE}" = "all" ]; then
    echo "=== [Health Gate 1/2] Checking local replica synchronization (TS-${TABLET_SERVER_ID:-N/A}) ==="
    REPLICA_TIMEOUT="${FLUSS_REPLICA_CATCHUP_TIMEOUT_SECONDS:-120}"
    REPLICA_WAITED=0
    REPLICA_READY=false

    while [ $REPLICA_WAITED -lt $REPLICA_TIMEOUT ]; do
        METRICS_DATA=$(curl -s --connect-timeout 2 "http://127.0.0.1:9250/metrics" 2>/dev/null || true)

        UNDER_MIN_ISR=$(echo "${METRICS_DATA}" | grep '^fluss_tabletserver_underMinIsr' | head -n 1 | awk '{print $2}')
        UNDER_REP=$(echo "${METRICS_DATA}" | grep '^fluss_tabletserver_underReplicated' | head -n 1 | awk '{print $2}')
        LEADER_CNT=$(echo "${METRICS_DATA}" | grep '^fluss_tabletserver_leaderCount' | head -n 1 | awk '{print $2}')

        UNDER_MIN_ISR="${UNDER_MIN_ISR:--1}"
        UNDER_REP="${UNDER_REP:--1}"
        LEADER_CNT="${LEADER_CNT:-0}"

        echo "[Gate 1] TS-${TABLET_SERVER_ID:-N/A} replica sync status: underReplicated=${UNDER_REP}, underMinIsr=${UNDER_MIN_ISR}, leaderCount=${LEADER_CNT} (${REPLICA_WAITED}s/${REPLICA_TIMEOUT}s)..."

        # Hard requirement: underMinIsr must be 0 (never break Min.ISR)
        # Optimal requirement: underReplicated reaches 0
        if [ "${UNDER_MIN_ISR}" = "0.0" ] && [ "${UNDER_REP}" = "0.0" ]; then
            echo "[Gate 1] PASSED: All local replicas are fully in-sync (underReplicated=0, underMinIsr=0)."
            REPLICA_READY=true
            break
        fi

        sleep 3
        REPLICA_WAITED=$((REPLICA_WAITED + 3))
    done

    if [ "${REPLICA_READY}" != "true" ]; then
        if [ "${UNDER_MIN_ISR}" != "0.0" ] && [ "${UNDER_MIN_ISR}" != "0" ]; then
            echo "CRITICAL ERROR: TS-${TABLET_SERVER_ID:-N/A} has ${UNDER_MIN_ISR} replicas below Min.ISR! Blocking rollout." >&2
            exit 1
        fi
        echo "WARNING: Replica catch-up timed out after ${REPLICA_TIMEOUT}s, but Min.ISR is satisfied (underMinIsr=0, underReplicated=${UNDER_REP}). Proceeding with caution."
    fi
fi

# ------------------------------------------------------------------------------
# Health Check 2: Cluster Health Readiness Gate (集群全局健康就绪门禁检查)
# Validates that no buckets are offline and the cluster is in a healthy state.
# ------------------------------------------------------------------------------
if [ "${FLUSS_ROLE}" = "tablet" ] || [ "${FLUSS_ROLE}" = "all" ]; then
    echo "=== [Health Gate 2/2] Checking cluster-wide health readiness via ClusterHealthReadinessCheck ==="
    CLUSTER_HEALTH_TIMEOUT="${FLUSS_CLUSTER_HEALTH_TIMEOUT_SECONDS:-60}"
    CLUSTER_WAITED=0
    CLUSTER_READY=false

    JAVA_CMD="${JAVA_HOME}/bin/java"
    if [ ! -x "${JAVA_CMD}" ]; then
        JAVA_CMD="java"
    fi
    HEALTH_CP="${FLUSS_HOME}/lib/*"

    while [ $CLUSTER_WAITED -lt $CLUSTER_HEALTH_TIMEOUT ]; do
        # Call ClusterHealthReadinessCheck via INTERNAL listener (127.0.0.1:9125, plaintext)
        HEALTH_OUTPUT=$("${JAVA_CMD}" \
            -XX:+IgnoreUnrecognizedVMOptions \
            -Xmx64m \
            -classpath "${HEALTH_CP}" \
            org.apache.fluss.server.tools.ClusterHealthReadinessCheck \
            --host "127.0.0.1" \
            --port 9125 \
            --timeoutMs 5000 2>&1 || true)

        STATUS_VAL=$(echo "${HEALTH_OUTPUT}" | grep -o 'status=[0-9]\+' | cut -d= -f2 || echo "-1")
        NUM_LEADERS=$(echo "${HEALTH_OUTPUT}" | grep -o 'numLeaderReplicas=[0-9]\+' | cut -d= -f2 || echo "0")
        ACTIVE_LEADERS=$(echo "${HEALTH_OUTPUT}" | grep -o 'activeLeaderReplicas=[0-9]\+' | cut -d= -f2 || echo "0")
        NUM_REPLICAS=$(echo "${HEALTH_OUTPUT}" | grep -o 'numReplicas=[0-9]\+' | cut -d= -f2 || echo "0")
        INSYNC_REPLICAS=$(echo "${HEALTH_OUTPUT}" | grep -o 'inSyncReplicas=[0-9]\+' | cut -d= -f2 || echo "0")

        echo "[Gate 2] Cluster health status: ${STATUS_VAL} (activeLeaders=${ACTIVE_LEADERS}/${NUM_LEADERS}, inSyncReplicas=${INSYNC_REPLICAS}/${NUM_REPLICAS}) (${CLUSTER_WAITED}s/${CLUSTER_HEALTH_TIMEOUT}s)..."

        # status=0 is STATUS_GREEN (all leaders active, all replicas in ISR)
        if [ "${STATUS_VAL}" = "0" ]; then
            echo "[Gate 2] PASSED: Cluster health is GREEN (100% active leaders, 100% in-sync replicas)."
            CLUSTER_READY=true
            break
        fi

        # Check for RED status: active leaders < num leaders means offline buckets exist!
        if [ "${STATUS_VAL}" = "2" ] || [ -n "${ACTIVE_LEADERS}" -a -n "${NUM_LEADERS}" ] && [ "${ACTIVE_LEADERS}" -lt "${NUM_LEADERS}" ]; then
            echo "WARNING: Cluster currently has offline buckets (${ACTIVE_LEADERS}/${NUM_LEADERS} leaders active). Waiting for recovery..."
        fi

        sleep 3
        CLUSTER_WAITED=$((CLUSTER_WAITED + 3))
    done

    if [ "${CLUSTER_READY}" != "true" ]; then
        if [ -n "${ACTIVE_LEADERS}" -a -n "${NUM_LEADERS}" ] && [ "${ACTIVE_LEADERS}" -lt "${NUM_LEADERS}" ]; then
            echo "CRITICAL ERROR: Cluster has offline buckets (${ACTIVE_LEADERS}/${NUM_LEADERS} active)! Blocking Wave progression to protect data availability." >&2
            exit 1
        fi

        if [ -n "${ACTIVE_LEADERS}" -a -n "${NUM_LEADERS}" ] && [ "${ACTIVE_LEADERS}" -eq "${NUM_LEADERS}" ]; then
            echo "WARNING: Cluster health timed out waiting for GREEN, but 100% leaders are active (${ACTIVE_LEADERS}/${NUM_LEADERS}) and 0 buckets are offline. Proceeding safely."
        else
            echo "CRITICAL ERROR: Cluster health check failed or Coordinator unreachable. Blocking rollout." >&2
            exit 1
        fi
    fi
elif [ "${FLUSS_ROLE}" = "coordinator" ]; then
    echo "=== [Health Gate 2/2] Checking Coordinator server health metrics ==="
    COORD_METRICS=$(curl -s --connect-timeout 2 "http://127.0.0.1:9249/metrics" 2>/dev/null || true)
    OFFLINE_BUCKETS=$(echo "${COORD_METRICS}" | grep '^fluss_coordinator_offlineBucketCount' | head -n 1 | awk '{print $2}')
    ACTIVE_COORD=$(echo "${COORD_METRICS}" | grep '^fluss_coordinator_activeCoordinatorCount' | head -n 1 | awk '{print $2}')
    ACTIVE_TS=$(echo "${COORD_METRICS}" | grep '^fluss_coordinator_activeTabletServerCount' | head -n 1 | awk '{print $2}')

    echo "[Gate 2] Coordinator metrics: activeCoordinator=${ACTIVE_COORD}, activeTabletServers=${ACTIVE_TS}, offlineBuckets=${OFFLINE_BUCKETS}"
    if [ "${OFFLINE_BUCKETS}" != "0.0" ] && [ "${OFFLINE_BUCKETS}" != "0" ]; then
        echo "CRITICAL ERROR: Coordinator reports offline buckets (${OFFLINE_BUCKETS})! Blocking rollout." >&2
        exit 1
    fi
    if [ "${ACTIVE_COORD}" != "1.0" ] && [ "${ACTIVE_COORD}" != "1" ]; then
        echo "CRITICAL ERROR: Coordinator is not active! Blocking rollout." >&2
        exit 1
    fi
    echo "[Gate 2] PASSED: Coordinator is active with 0 offline buckets."
fi

echo "=== [Post-Deploy] Post-deploy completed successfully ==="
