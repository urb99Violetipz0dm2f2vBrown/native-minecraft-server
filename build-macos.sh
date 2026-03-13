#!/usr/bin/env bash

set -o errexit
set -o nounset

SERVER_VERSION="${SERVER_VERSION:-"1.21.11"}"
SERVER_MANIFEST_URL="$(curl "https://piston-meta.mojang.com/mc/game/version_manifest.json" | jq -r ".versions[] | select(.id == \"${SERVER_VERSION}\") | .url")"

SERVER_JAR_DL="$(curl "$SERVER_MANIFEST_URL" | jq -r ".downloads.server.url")"
SCRIPT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
AGENT_CONFIG_DIR="${SCRIPT_DIR}/configuration/"
BUILD_DIR="${SCRIPT_DIR}/build"
JAR_PATH="${BUILD_DIR}/server.jar"
META_INF_PATH="${BUILD_DIR}/META-INF"
BINARY_NAME="native-minecraft-server"
NI_EXEC="${GRAALVM_HOME:-}/bin/native-image"
readonly SERVER_VERSION SERVER_MANIFEST_URL SERVER_JAR_DL SCRIPT_DIR AGENT_CONFIG_DIR BUILD_DIR JAR_PATH META_INF_PATH BINARY_NAME NI_EXEC

if [[ -z "${GRAALVM_HOME:-}" ]]; then
    echo "\$GRAALVM_HOME is not set. Please provide a GraalVM installation. Exiting..."
    exit 1
fi

if ! command -v "${NI_EXEC}" &> /dev/null; then
    echo "Installing GraalVM Native Image..."
    "${GRAALVM_HOME}/bin/gu" install --no-progress native-image
fi

if [[ ! -d "${BUILD_DIR}" ]]; then
    mkdir "${BUILD_DIR}"
fi
pushd "${BUILD_DIR}" > /dev/null

if [[ ! -f "${JAR_PATH}" ]]; then
    echo "Downloading Minecraft's server.jar..."
    curl --show-error --fail --location -o "${JAR_PATH}" "${SERVER_JAR_DL}"
fi

if [[ ! -d "${META_INF_PATH}" ]]; then
    echo "Extracting resources from Minecraft's server.jar..."
    unzip -qq "${JAR_PATH}" "META-INF/*" -d "."
fi

if [[ ! -f "${META_INF_PATH}/classpath-joined" ]]; then
    echo "Unable to determine classpath. Exiting..."
    exit 1
fi
CLASSPATH_JOINED=$(cat "${META_INF_PATH}/classpath-joined")
readonly CLASSPATH_JOINED

if [[ ! -f "${META_INF_PATH}/main-class" ]]; then
    echo "Unable to determine main class. Exiting..."
    exit 1
fi
MAIN_CLASS=$(cat "${META_INF_PATH}/main-class")
readonly MAIN_CLASS

pushd "${META_INF_PATH}" > /dev/null
echo "${NI_EXEC}" --no-fallback \
    -H:ConfigurationFileDirectories="${AGENT_CONFIG_DIR}" \
    -H:+AddAllCharsets \
    -H:+ReportExceptionStackTraces \
    --enable-url-protocols=https \
    --initialize-at-run-time=io.netty \
    # --enable-monitoring=heapdump,jfr \
    --enable-native-access=ALL-UNNAMED \
    --initialize-at-build-time=net.minecraft.util.profiling.jfr.event \
    --initialize-at-run-time=org.apache.logging.log4j \
    --initialize-at-run-time=joptsimple \
    --initialize-at-run-time=org.apache.logging.log4j.core.util.DefaultShutdownCallbackRegistry \
    -H:Name="${BINARY_NAME}" \
    -cp "${CLASSPATH_JOINED//;/:}" \
    "$@" \
    "${MAIN_CLASS}"
"${NI_EXEC}" --no-fallback \
    -H:ConfigurationFileDirectories="${AGENT_CONFIG_DIR}" \
    -H:+AddAllCharsets \
    -H:+ReportExceptionStackTraces \
    --enable-url-protocols=https \
    --initialize-at-run-time=io.netty \
    # --enable-monitoring=heapdump,jfr \
    --enable-native-access=ALL-UNNAMED \
    --initialize-at-build-time=net.minecraft.util.profiling.jfr.event \
    --initialize-at-run-time=org.apache.logging.log4j \
    --initialize-at-run-time=joptsimple \
    --initialize-at-run-time=org.apache.logging.log4j.core.util.DefaultShutdownCallbackRegistry \
    -H:Name="${BINARY_NAME}" \
    -cp "${CLASSPATH_JOINED//;/:}" \
    "$@" \
    "${MAIN_CLASS}"
mv "${BINARY_NAME}" "${SCRIPT_DIR}/${BINARY_NAME}"
popd > /dev/null # Exit $META_INF_PATH
popd > /dev/null # Exit $BUILD_DIR

# if command -v upx &> /dev/null; then
#     echo "Compressing the native Minecraft server with upx..."
#     upx "${SCRIPT_DIR}/${BINARY_NAME}"
# fi

echo ""
echo "Done! The native Minecraft server is located at:"
echo "${SCRIPT_DIR}/${BINARY_NAME}"
