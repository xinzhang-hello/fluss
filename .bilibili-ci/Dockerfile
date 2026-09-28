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

# Stage 1: Build binary distribution
FROM hub.bilibili.co/nyx-compile/bili-maven:3.9.7-openjdk-11 AS builder

WORKDIR /build

# Copy repository source code
COPY . /build

# Build Fluss binary distribution using build.sh
RUN chmod +x .bilibili-ci/build.sh && OUTPUT_DIR=/output .bilibili-ci/build.sh

# Stage 2: Output artifacts for Nyx cloud build platform
FROM scratch AS nyx-output

# Copy the binary distribution artifacts to root for export
COPY --from=builder /output/ .
