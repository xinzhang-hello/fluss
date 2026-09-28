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

# Script to deploy Fluss Flink connectors and client artifacts to Bilibili Maven Nexus
#
# Usage:
#   ./deploy_maven.sh [snapshots|releases] [settings_file]
#
# Example:
#   ./deploy_maven.sh snapshots
#   ./deploy_maven.sh releases /path/to/settings.xml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

REPO_TYPE="${1:-snapshots}"
SETTINGS_ARG=()
if [ -n "${2:-}" ] && [ -f "${2}" ]; then
    SETTINGS_ARG=("-s" "${2}")
elif [ -f "${HOME}/.m2/settings.xml" ]; then
    SETTINGS_ARG=("-s" "${HOME}/.m2/settings.xml")
fi

if [ "${REPO_TYPE}" = "releases" ]; then
    REPO_ID="${REPO_ID:-bilibili-nexus-releases}"
    REPO_URL="https://nexus.bilibili.co/content/repositories/releases/"
else
    REPO_TYPE="snapshots"
    REPO_ID="${REPO_ID:-bilibili-nexus-snapshots}"
    REPO_URL="https://nexus.bilibili.co/content/repositories/snapshots/"
fi

echo "=== Deploying Fluss Artifacts to Bilibili Maven Nexus ==="
echo "Project Root: ${PROJECT_ROOT}"
echo "Target Repository Type: ${REPO_TYPE}"
echo "Target Repository URL: ${REPO_URL}"
echo "Server ID: ${REPO_ID}"

# Locate Maven
MVN_CMD="mvn"
if command -v mvn >/dev/null 2>&1; then
    MVN_CMD="mvn"
elif [ -x "./mvnw" ]; then
    MVN_CMD="./mvnw"
fi

# Modules required by downstream Flink jobs & clients
# (root pom, common, rpc, client, lake-paimon, flink modules)
DEPLOY_MODULES="org.apache.fluss:fluss,org.apache.fluss:fluss-common,org.apache.fluss:fluss-rpc,org.apache.fluss:fluss-client,org.apache.fluss:fluss-lake-paimon,org.apache.fluss:fluss-flink,org.apache.fluss:fluss-flink-common,org.apache.fluss:fluss-flink-1.20,org.apache.fluss:fluss-flink-1.19,org.apache.fluss:fluss-flink-1.18,org.apache.fluss:fluss-flink-2.2,org.apache.fluss:fluss-flink-2.3,org.apache.fluss:fluss-flink-tiering"

echo "Deploying target modules: ${DEPLOY_MODULES}"

${MVN_CMD} deploy \
    -DskipTests \
    -Dspotless.check.skip=true \
    -Dcheckstyle.skip=true \
    -DaltDeploymentRepository="${REPO_ID}::default::${REPO_URL}" \
    -pl "${DEPLOY_MODULES}" \
    "${SETTINGS_ARG[@]}"

echo "=== Deployment Completed Successfully ==="
