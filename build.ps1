#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# 配置变量
$SERVER_JAR_DL = "https://launcher.mojang.com/v1/objects/c8f83c5655308435b3dcf03c06d9fe8740a77469/server.jar"
$SCRIPT_DIR = $PSScriptRoot
$BUILD_DIR = Join-Path $SCRIPT_DIR "build"
$JAR_PATH = Join-Path $BUILD_DIR "server.jar"
$ZIP_PATH = Join-Path $BUILD_DIR "server.zip"
$META_INF_PATH = Join-Path $BUILD_DIR "META-INF"
$BINARY_NAME = "native-minecraft-server"


if (-not $env:GRAALVM_HOME) {
    Write-Host '$GRAALVM_HOME is not set. Please provide a GraalVM installation. Exiting...'
    exit 1
}

$NI_EXEC = Join-Path $env:GRAALVM_HOME "bin\native-image"

# 创建 build 目录
if (-not (Test-Path $BUILD_DIR)) {
    New-Item -ItemType Directory -Path $BUILD_DIR | Out-Null
}
Push-Location $BUILD_DIR

# 下载 server.jar（如果不存在）
if (-not (Test-Path $JAR_PATH)) {
    Write-Host "Downloading Minecraft's server.jar..."
    Invoke-WebRequest -Uri $SERVER_JAR_DL -OutFile $JAR_PATH
}


# 解压 META-INF 目录（如果不存在）
if (-not (Test-Path $META_INF_PATH)) {
    Rename-Item -Path $JAR_PATH -NewName "server.zip" -Force
    Write-Host "Extracting resources from Minecraft's server.zip..."
    Expand-Archive -Path $ZIP_PATH -DestinationPath $BUILD_DIR -Force

    # 解压完成后，将压缩包改回 jar 格式（便于后续可能的使用）
    Rename-Item -Path $ZIP_PATH -NewName "server.jar" -Force
}
# 检查并读取 classpath-joined 文件
$classpathJoinedFile = Join-Path $META_INF_PATH "classpath-joined"
if (-not (Test-Path $classpathJoinedFile)) {
    Write-Host "Unable to determine classpath. Exiting..."
    exit 1
}
$CLASSPATH_JOINED = (Get-Content $classpathJoinedFile -Raw).Trim()

# 检查并读取 main-class 文件
$mainClassFile = Join-Path $META_INF_PATH "main-class"
if (-not (Test-Path $mainClassFile)) {
    Write-Host "Unable to determine main class. Exiting..."
    exit 1
}
$MAIN_CLASS = (Get-Content $mainClassFile -Raw).Trim()

Push-Location $META_INF_PATH

# 构建 native-image 参数数组（Windows 下使用分号分隔 classpath）
$nativeImageArgs = @(
    "--no-fallback",
    "-H:ConfigurationFileDirectories=$SCRIPT_DIR\configuration\",
    "--enable-url-protocols=https",
    "-H:+AllowVMInspection",
    "--initialize-at-run-time=io.netty,jdk.jfr,jdk.jfr.internal.JVM,java.awt,net.minecraft.util.profiling.jfr.event.WorldLoadFinishedEvent",
    "--initialize-at-run-time=jdk.jfr.internal.TypeLibrary,jdk.jfr.internal.PlatformEventType,jdk.jfr.internal.Options,jdk.jfr.internal.FlightRecorderPermission,jdk.jfr.internal.JVM,jdk.jfr.internal.Type,jdk.jfr.internal.JVMSupport,jdk.jfr.internal.SecuritySupport",
    "--initialize-at-run-time=io.netty,jdk.jfr,jdk.jfr.internal.JVM,java.awt,net.minecraft.util.profiling.jfr.event.WorldLoadFinishedEvent"
    "--report-unsupported-elements-at-runtime",
    "-Djdk.jfr.disableInstrumentation=true",
    "-Djdk.jfr.unsupported.vm=true",
    "-H:Name=$BINARY_NAME",
    "-cp", "$CLASSPATH_JOINED",
    "$MAIN_CLASS",
    "-Dcom.oracle.svm.jfr.disable=true",
    "-H:IncludeResources=.*jnidispatch.dll$"
)

# 打印完整命令用于调试
Write-Host "Executing command:"
Write-Host "$NI_EXEC $($nativeImageArgs -join ' ')"

# 直接调用 native-image 命令
& $NI_EXEC @nativeImageArgs

Pop-Location  # 退出 META-INF
Pop-Location  # 退出 BUILD_DIR

Write-Host ""
Write-Host "Done! The native Minecraft server has been built under the build directory."
