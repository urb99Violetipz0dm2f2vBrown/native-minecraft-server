#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# 配置变量
$SERVER_VERSION = if ($env:SERVER_VERSION) { $env:SERVER_VERSION } else { "1.21.11" }

$versionManifestJson = Invoke-RestMethod -Uri "https://piston-meta.mojang.com/mc/game/version_manifest.json"
$serverManifestUrl = ($versionManifestJson.versions | Where-Object { $_.id -eq $SERVER_VERSION } | Select-Object -First 1).url
if (-not $serverManifestUrl) {
    Write-Host "Unable to find manifest url for SERVER_VERSION=$SERVER_VERSION. Exiting..."
    exit 1
}

$serverManifestJson = Invoke-RestMethod -Uri $serverManifestUrl
$SERVER_JAR_DL = $serverManifestJson.downloads.server.url
if (-not $SERVER_JAR_DL) {
    Write-Host "Unable to find server.jar download url for SERVER_VERSION=$SERVER_VERSION. Exiting..."
    exit 1
}

$SCRIPT_DIR = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SCRIPT_DIR)) {
    if ($MyInvocation.MyCommand.Path) {
        $SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $SCRIPT_DIR = (Get-Location).Path
    }
}
$AGENT_CONFIG_DIR = Join-Path $SCRIPT_DIR "configuration"
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
    "-H:ConfigurationFileDirectories=$AGENT_CONFIG_DIR",
    "-H:+AddAllCharsets",
    "-H:+ReportExceptionStackTraces",
    "--enable-url-protocols=https",
    "--initialize-at-run-time=io.netty",
    "--enable-monitoring=heapdump,jfr",
    "--enable-native-access=ALL-UNNAMED",
    "--initialize-at-build-time=net.minecraft.util.profiling.jfr.event",
    "--initialize-at-run-time=org.apache.logging.log4j",
    "--initialize-at-run-time=joptsimple",
    "--initialize-at-run-time=org.apache.logging.log4j.core.util.DefaultShutdownCallbackRegistry",
    "-H:Name=$BINARY_NAME",
    "-cp", "$CLASSPATH_JOINED",
    "$MAIN_CLASS"
)

# 打印完整命令用于调试
Write-Host "Executing command:"
Write-Host "$NI_EXEC $($nativeImageArgs -join ' ')"

# 直接调用 native-image 命令
& $NI_EXEC @nativeImageArgs

Move-Item -Path (Join-Path $META_INF_PATH "$BINARY_NAME.exe") -Destination (Join-Path $SCRIPT_DIR "$BINARY_NAME.exe") -Force

Pop-Location  # 退出 META-INF
Pop-Location  # 退出 BUILD_DIR

Write-Host ""
Write-Host "Done! The native Minecraft server is located at:"
Write-Host (Join-Path $SCRIPT_DIR "$BINARY_NAME.exe")
