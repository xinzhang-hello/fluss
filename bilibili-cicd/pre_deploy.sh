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

echo "=== [Pre-Deploy] Starting pre-deploy script for ${APP_NAME} ==="
echo "Target application directory: ${APP_DIR}"

# Locate Fluss installation directory
if [ -d "${APP_DIR}/bin" ]; then
    FLUSS_HOME="${APP_DIR}"
elif [ -d "${APP_DIR}/fluss/bin" ]; then
    FLUSS_HOME="${APP_DIR}/fluss"
else
    FLUSS_HOME="${APP_DIR}"
fi

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
fi

# 2. Gracefully stop services if previous installation exists
# Determine target service(s) to stop based on FLUSS_ROLE (defaults to tablet)
FLUSS_ROLE="${FLUSS_ROLE:-tablet}"
case "${FLUSS_ROLE}" in
    tablet|tablet-server|table|table-server)
        TARGET_ROLE="tablet"
        TARGET_SERVICES=("fluss-tablet-server")
        TARGET_PROC_PATTERN="org.apache.fluss.server.tablet.TabletServer"
        ;;
    coordinator|coordinator-server)
        TARGET_ROLE="coordinator"
        TARGET_SERVICES=("fluss-coordinator-server")
        TARGET_PROC_PATTERN="org.apache.fluss.server.coordinator.CoordinatorServer"
        ;;
    all)
        TARGET_ROLE="all"
        TARGET_SERVICES=("fluss-tablet-server" "fluss-coordinator-server")
        TARGET_PROC_PATTERN="org.apache.fluss.server"
        ;;
    *)
        echo "WARNING: Unknown FLUSS_ROLE '${FLUSS_ROLE}', defaulting to tablet"
        TARGET_ROLE="tablet"
        TARGET_SERVICES=("fluss-tablet-server")
        TARGET_PROC_PATTERN="org.apache.fluss.server.tablet.TabletServer"
        ;;
esac

echo "Target service role to stop: ${TARGET_ROLE}"

# 2.1 Stop via systemctl if running under systemd
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    SUDO=""
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        SUDO="sudo"
    fi
    for svc in "${TARGET_SERVICES[@]}"; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            echo "Stopping ${svc} via systemctl..."
            ${SUDO} systemctl stop "${svc}" || true
        fi
    done
fi

# 2.2 Stop via script fallback
if [ -d "${FLUSS_HOME}/bin" ]; then
    echo "Stopping services via Fluss control scripts..."

    if [ "${TARGET_ROLE}" = "coordinator" ] || [ "${TARGET_ROLE}" = "all" ]; then
        if [ -f "${FLUSS_HOME}/bin/coordinator-server.sh" ]; then
            echo "Stopping CoordinatorServer..."
            "${FLUSS_HOME}/bin/coordinator-server.sh" stop || true
        fi
    fi

    if [ "${TARGET_ROLE}" = "tablet" ] || [ "${TARGET_ROLE}" = "all" ]; then
        if [ -f "${FLUSS_HOME}/bin/tablet-server.sh" ]; then
            echo "Stopping TabletServer..."
            "${FLUSS_HOME}/bin/tablet-server.sh" stop || true
        fi
    fi
fi

# 2.3 Wait and verify processes have terminated
echo "Verifying process shutdown for ${TARGET_ROLE} (${TARGET_PROC_PATTERN})..."
MAX_WAIT=30
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    PIDS=$(pgrep -f "${TARGET_PROC_PATTERN}" || true)
    if [ -z "${PIDS}" ]; then
        echo "Target Fluss server processes (${TARGET_ROLE}) stopped cleanly."
        break
    fi
    echo "Waiting for Fluss processes (${PIDS}) to exit... (${WAITED}s/${MAX_WAIT}s)"
    sleep 2
    WAITED=$((WAITED + 2))
done

# Force kill any remaining target processes if still running
PIDS=$(pgrep -f "${TARGET_PROC_PATTERN}" || true)
if [ -n "${PIDS}" ]; then
    echo "WARNING: Forcibly killing remaining Fluss processes: ${PIDS}"
    kill -9 ${PIDS} || true
    sleep 1
fi

echo "=== [Pre-Deploy] Pre-deploy completed successfully ==="
