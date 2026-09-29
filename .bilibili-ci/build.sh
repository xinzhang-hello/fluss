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

# Determine repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# Default output directory: /output in Docker/root environments, else ./build-output
if [ -d "/output" ] || [ "$(id -u)" -eq 0 ]; then
    DEFAULT_OUTPUT="/output"
else
    DEFAULT_OUTPUT="${PROJECT_ROOT}/build-output"
fi
OUTPUT_DIR="${OUTPUT_DIR:-${DEFAULT_OUTPUT}}"

echo "=== Building Apache Fluss Binary Distribution ==="
echo "Project Root: ${PROJECT_ROOT}"
echo "Output Directory: ${OUTPUT_DIR}"

# Locate Maven
MVN_CMD="mvn"
if command -v mvn >/dev/null 2>&1; then
    MVN_CMD="mvn"
elif [ -x "./mvnw" ]; then
    MVN_CMD="./mvnw"
else
    echo "ERROR: Neither mvn nor ./mvnw is available." >&2
    exit 1
fi

echo "Running Maven build using: ${MVN_CMD} ..."
${MVN_CMD} clean install \
    -DskipTests \
    -Dspotless.check.skip=true \
    -Dcheckstyle.skip=true \
    -T 1C

echo "=== Preparing Release Output Artifacts ==="
mkdir -p "${OUTPUT_DIR}"

# Copy binary tarball (.tgz)
cp -f fluss-dist/target/fluss-*-bin.tgz "${OUTPUT_DIR}/"

# Copy uncompressed binary distribution directory (fluss/)
if [ -d fluss-dist/target/fluss-*-bin/fluss ]; then
    cp -rf fluss-dist/target/fluss-*-bin/fluss "${OUTPUT_DIR}/"
elif compgen -G "fluss-dist/target/fluss-*-bin/fluss-*" > /dev/null; then
    cp -rf fluss-dist/target/fluss-*-bin/fluss-* "${OUTPUT_DIR}/fluss"
fi

# Copy bilibili-cicd deployment scripts
if [ -d "bilibili-cicd" ]; then
    cp -rf bilibili-cicd "${OUTPUT_DIR}/"
fi

# Collect all fluss-flink connector & client jars produced by this build
echo "=== Collecting Fluss Flink & Client Artifacts ==="
FLINK_ARTIFACTS_DIR="${OUTPUT_DIR}/flink-connectors"
mkdir -p "${FLINK_ARTIFACTS_DIR}"
find fluss-flink -name "fluss-flink-*.jar" ! -name "*-tests.jar" -exec cp -f {} "${FLINK_ARTIFACTS_DIR}/" \;
find fluss-client -name "fluss-client-*.jar" ! -name "*-tests.jar" -exec cp -f {} "${FLINK_ARTIFACTS_DIR}/" \;
find fluss-lake/fluss-lake-paimon -name "fluss-lake-paimon-*.jar" ! -name "*-tests.jar" -exec cp -f {} "${FLINK_ARTIFACTS_DIR}/" \;

# Ensure fluss server binary package includes bilibili-cicd scripts and conf-coord
if [ -d "${OUTPUT_DIR}/fluss" ]; then
    echo "Re-packaging fluss-1.1-SNAPSHOT-bin.tgz with bilibili-cicd scripts..."
    tar -czf "${OUTPUT_DIR}/fluss-1.1-SNAPSHOT-bin.tgz" -C "${OUTPUT_DIR}" fluss
fi

echo "=== Build Complete ==="
echo "Artifacts generated in ${OUTPUT_DIR}:"
ls -la "${OUTPUT_DIR}"
