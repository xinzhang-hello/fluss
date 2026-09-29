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

# Locate Fluss installation directory
if [ -n "${FLUSS_HOME:-}" ] && [ -d "${FLUSS_HOME}" ]; then
    APP_DIR="${FLUSS_HOME}"
elif [ -d "${PARENT_DIR}/bin" ]; then
    APP_DIR="${PARENT_DIR}"
elif [ -d "${PARENT_DIR}/fluss/bin" ]; then
    APP_DIR="${PARENT_DIR}/fluss"
else
    APP_DIR="/data/service/fluss"
fi
export FLUSS_HOME="${APP_DIR}"

TARGET_ROLE="${1:-${FLUSS_ROLE:-tablet}}"

echo "=== [Systemd-Init] Initializing systemd for Fluss (Role: ${TARGET_ROLE}) ==="
echo "Fluss Home: ${FLUSS_HOME}"

# Environment defaults
JAVA_HOME="${JAVA_HOME:-/data/sdk/jdk17}"
FLUSS_LOG_DIR="${FLUSS_LOG_DIR:-/data/log/fluss}"
KRB5KEYTAB="${KRB5KEYTAB:-/etc/security/keytabs/kafka.service.keytab}"
KRB5_CONFIG="${KRB5_CONFIG:-/etc/krb5.conf}"

# Hadoop environment defaults for HDFS remote storage
if [ -z "${HADOOP_HOME:-}" ]; then
    for candidate in "/data/service/hadoop-3.3.2-SNAPSHOT" "/data/service/hadoop" "/usr/local/hadoop"; do
        if [ -d "${candidate}" ]; then
            HADOOP_HOME="${candidate}"
            break
        fi
    done
fi
export HADOOP_HOME="${HADOOP_HOME:-}"
if [ -n "${HADOOP_HOME}" ]; then
    export HADOOP_CONF_DIR="${HADOOP_CONF_DIR:-${HADOOP_HOME}/etc/hadoop}"
    if [ -z "${HADOOP_CLASSPATH:-}" ]; then
        export HADOOP_CLASSPATH="${HADOOP_CONF_DIR}:${HADOOP_HOME}/share/hadoop/common/lib/*:${HADOOP_HOME}/share/hadoop/common/*:${HADOOP_HOME}/share/hadoop/hdfs:${HADOOP_HOME}/share/hadoop/hdfs/lib/*:${HADOOP_HOME}/share/hadoop/hdfs/*"
    fi
fi

# Principal detection / fallback
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")
HOST_SHORT="$(hostname 2>/dev/null | cut -d. -f1)"
KRB5_REALM="${KRB5_REALM:-BILIBILI.CO}"

if [ -z "${KRB5PRINCIPAL:-}" ] && [ -f "${KRB5KEYTAB}" ] && command -v klist >/dev/null 2>&1; then
    DETECTED_PRINCIPAL=$(klist -kt "${KRB5KEYTAB}" 2>/dev/null | awk '{print $NF}' | grep '@' | tail -n 1 || true)
    if [ -n "${DETECTED_PRINCIPAL}" ]; then
        KRB5PRINCIPAL="${DETECTED_PRINCIPAL}"
    fi
fi
if [ -z "${KRB5PRINCIPAL:-}" ]; then
    if [[ "${HOSTNAME_FQDN}" == *"."* ]]; then
        KRB5PRINCIPAL="kafka/${HOSTNAME_FQDN}@${KRB5_REALM}"
    elif [ -n "${HOST_SHORT}" ]; then
        KRB5PRINCIPAL="kafka/${HOST_SHORT}.host.bilibili.co@${KRB5_REALM}"
    else
        KRB5PRINCIPAL="kafka/${HOSTNAME_FQDN}@${KRB5_REALM}"
    fi
fi

CURRENT_USER=$(id -un 2>/dev/null || echo "root")
CURRENT_GROUP=$(id -gn 2>/dev/null || echo "root")
if [ "$(id -u)" -eq 0 ]; then
    SERVICE_USER="${SERVICE_USER:-root}"
    SERVICE_GROUP="${SERVICE_GROUP:-root}"
else
    SERVICE_USER="${SERVICE_USER:-${CURRENT_USER}}"
    SERVICE_GROUP="${SERVICE_GROUP:-${CURRENT_GROUP}}"
fi

# Sudo detection for writing to /etc/systemd/system
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        SUDO="sudo"
    elif [ ! -w "/etc/systemd/system" ]; then
        echo "WARNING: /etc/systemd/system is not writable and sudo is unavailable. Skipping systemd init." >&2
        exit 0
    fi
fi

setup_unit() {
    local service_name="$1"
    local service_desc="$2"
    local start_cmd="$3"

    local unit_file="/etc/systemd/system/${service_name}.service"
    local dropin_dir="/etc/systemd/system/${service_name}.service.d"
    local timestamp
    timestamp="$(date +%Y%m%d%H%M%S)"

    echo "--- Configuring ${service_name} ---"

    # 0. Disable legacy fluss-coordinator service if configuring coordinator
    if [ "${service_name}" = "fluss-coordinator-server" ] && [ -f "/etc/systemd/system/fluss-coordinator.service" ]; then
        echo "Stopping and disabling legacy fluss-coordinator.service..."
        ${SUDO} systemctl stop fluss-coordinator 2>/dev/null || true
        ${SUDO} systemctl disable fluss-coordinator 2>/dev/null || true
    fi

    # 1. Backup old unit file if exists
    if [ -f "${unit_file}" ]; then
        echo "Backing up existing ${unit_file} -> ${unit_file}.bak.${timestamp}"
        ${SUDO} cp -p "${unit_file}" "${unit_file}.bak.${timestamp}"
        # Retain last 3 backups
        ${SUDO} bash -c "ls -dt ${unit_file}.bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true"
    fi

    # 2. Backup and clean old drop-in directory if exists
    if [ -d "${dropin_dir}" ]; then
        echo "Backing up existing ${dropin_dir} -> ${dropin_dir}.bak.${timestamp}"
        ${SUDO} cp -rp "${dropin_dir}" "${dropin_dir}.bak.${timestamp}"
        # Retain last 3 backups
        ${SUDO} bash -c "ls -dt ${dropin_dir}.bak.* 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true"
        echo "Cleaning old drop-in files in ${dropin_dir}..."
        ${SUDO} rm -rf "${dropin_dir:?}"/*
    else
        echo "Creating drop-in directory: ${dropin_dir}"
        ${SUDO} mkdir -p "${dropin_dir}"
    fi

    # 3. Write main systemd unit file
    echo "Writing unit file: ${unit_file}"
    ${SUDO} tee "${unit_file}" > /dev/null <<EOF
[Unit]
Description=${service_desc}
Documentation=https://fluss.apache.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${FLUSS_HOME}
ExecStartPre=/bin/mkdir -p ${FLUSS_LOG_DIR} /mnt/storage00/fluss/data /mnt/storage01/fluss/data
ExecStartPre=-/bin/bash -c "if [ -f '${KRB5KEYTAB}' ] && command -v kinit >/dev/null 2>&1; then kinit -kt '${KRB5KEYTAB}' '${KRB5PRINCIPAL}' 2>/dev/null || true; fi"
ExecStart=${start_cmd}
Restart=on-failure
RestartSec=10
LimitNOFILE=655360
LimitNPROC=655360
LimitMEMLOCK=infinity
TimeoutStopSec=60
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
    ${SUDO} chmod 644 "${unit_file}"

    local conf_dir="${FLUSS_HOME}/conf"
    if [ "${service_name}" = "fluss-coordinator-server" ]; then
        conf_dir="${FLUSS_HOME}/conf-coord"
        mkdir -p "${conf_dir}"
        cp -p "${FLUSS_HOME}/conf"/* "${conf_dir}/" 2>/dev/null || true
        if [ -f "${conf_dir}/server.yaml" ]; then
            sed -i "s|:9125|:9122|g" "${conf_dir}/server.yaml"
            sed -i "s|:9124|:9123|g" "${conf_dir}/server.yaml"
            sed -i "s|^metrics.reporter.prometheus.port:.*|metrics.reporter.prometheus.port: 9249|" "${conf_dir}/server.yaml"
            sed -i "/^tablet-server.id:/d" "${conf_dir}/server.yaml"
        fi
    fi

    # 4. Write drop-in override file
    local dropin_file="${dropin_dir}/override.conf"
    echo "Writing drop-in file: ${dropin_file}"
    ${SUDO} tee "${dropin_file}" > /dev/null <<EOF
[Service]
Environment="JAVA_HOME=${JAVA_HOME}"
Environment="FLUSS_HOME=${FLUSS_HOME}"
Environment="FLUSS_CONF_DIR=${conf_dir}"
Environment="FLUSS_LOG_DIR=${FLUSS_LOG_DIR}"
Environment="KRB5KEYTAB=${KRB5KEYTAB}"
Environment="KRB5PRINCIPAL=${KRB5PRINCIPAL}"
Environment="KRB5_CONFIG=${KRB5_CONFIG}"
EOF

    if [ -n "${HADOOP_HOME:-}" ]; then
        ${SUDO} bash -c "echo 'Environment=\"HADOOP_HOME=${HADOOP_HOME}\"' >> '${dropin_file}'"
    fi
    if [ -n "${HADOOP_CONF_DIR:-}" ]; then
        ${SUDO} bash -c "echo 'Environment=\"HADOOP_CONF_DIR=${HADOOP_CONF_DIR}\"' >> '${dropin_file}'"
    fi
    if [ -n "${HADOOP_CLASSPATH:-}" ]; then
        ${SUDO} bash -c "echo 'Environment=\"HADOOP_CLASSPATH=${HADOOP_CLASSPATH}\"' >> '${dropin_file}'"
    fi

    if [ -n "${FLUSS_ENV_JAVA_OPTS:-}" ]; then
        ${SUDO} bash -c "echo 'Environment=\"FLUSS_ENV_JAVA_OPTS=${FLUSS_ENV_JAVA_OPTS}\"' >> '${dropin_file}'"
    fi
    if [ -n "${FLUSS_ENV_JAVA_OPTS_TS:-}" ]; then
        ${SUDO} bash -c "echo 'Environment=\"FLUSS_ENV_JAVA_OPTS_TS=${FLUSS_ENV_JAVA_OPTS_TS}\"' >> '${dropin_file}'"
    fi
    if [ -n "${FLUSS_ENV_JAVA_OPTS_CS:-}" ]; then
        ${SUDO} bash -c "echo 'Environment=\"FLUSS_ENV_JAVA_OPTS_CS=${FLUSS_ENV_JAVA_OPTS_CS}\"' >> '${dropin_file}'"
    fi
    ${SUDO} chmod 644 "${dropin_file}"

    echo "${service_name} configured successfully."
}

case "${TARGET_ROLE}" in
    tablet|tablet-server|table|table-server)
        setup_unit "fluss-tablet-server" "Apache Fluss Tablet Server" "${FLUSS_HOME}/bin/tablet-server.sh start-foreground"
        ;;
    coordinator|coordinator-server)
        setup_unit "fluss-coordinator-server" "Apache Fluss Coordinator Server" "${FLUSS_HOME}/bin/coordinator-server.sh start-foreground"
        ${SUDO} ln -sf "/etc/systemd/system/fluss-coordinator-server.service" "/etc/systemd/system/fluss-coordinator.service"
        ;;
    all)
        setup_unit "fluss-coordinator-server" "Apache Fluss Coordinator Server" "${FLUSS_HOME}/bin/coordinator-server.sh start-foreground"
        ${SUDO} ln -sf "/etc/systemd/system/fluss-coordinator-server.service" "/etc/systemd/system/fluss-coordinator.service"
        setup_unit "fluss-tablet-server" "Apache Fluss Tablet Server" "${FLUSS_HOME}/bin/tablet-server.sh start-foreground"
        ;;
    *)
        echo "ERROR: Unknown role '${TARGET_ROLE}'. Valid options: tablet, coordinator, all." >&2
        exit 1
        ;;
esac

# 5. Reload systemd daemon if active
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    echo "Reloading systemd daemon..."
    ${SUDO} systemctl daemon-reload
    echo "Systemd daemon reloaded successfully."
else
    echo "Systemd is not running as init system. Unit files written for future use."
fi

echo "=== [Systemd-Init] Systemd initialization finished successfully ==="
