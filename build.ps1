#!/usr/bin/env pwsh
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# 配置变量
$SERVER_JAR_DL = "https://launcher.mojang.com/v1/objects/c8f83c5655308435b3dcf03c06d9fe8740a77469/server.jar"
$SCRIPT_DIR = $PSScriptRoot
$BUILD_DIR = Join-Path $SCRIPT_DIR "build"
$JAR_PATH = Join-Path $BUILD_DIR "server.jar"
$META_INF_PATH = Join-Path $BUILD_DIR "META-INF"
$BINARY_NAME = "native-minecraft-server"

if (-not $env:GRAALVM_HOME) {
    Write-Host '$GRAALVM_HOME is not set. Please provide a GraalVM installation. Exiting...'
    exit 1
}

$NI_EXEC = Join-Path $env:GRAALVM_HOME "bin\native-image"

# 检查 native-image 是否存在，不存在则安装
if (-not (Test-Path $NI_EXEC)) {
    Write-Host "Installing GraalVM Native Image..."
    & (Join-Path $env:GRAALVM_HOME "bin\gu") install --no-progress native-image
}

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
    Write-Host "Extracting resources from Minecraft's server.jar..."
    Expand-Archive -Path $JAR_PATH -DestinationPath $BUILD_DIR -Force
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

# 构建 native-image 命令（注意Windows下使用分号作为classpath分隔符）
$nativeImageCmd = "`"$NI_EXEC`" --no-fallback " +
    "-H:ConfigurationFileDirectories=`"$SCRIPT_DIR\configuration\`" " +
    "--enable-url-protocols=https " +
    "--initialize-at-run-time=io.netty " +
    "-H:+AllowVMInspection " +
    "--initialize-at-build-time=net.minecraft.util.profiling.jfr.event " +
    "-H:Name=`"$BINARY_NAME`" " +
    "-cp `"$CLASSPATH_JOINED`" " +
    "`"$MAIN_CLASS`""

# 先打印出命令
Write-Host "Executing command:"
Write-Host $nativeImageCmd

# 执行 native-image 命令
Invoke-Expression $nativeImageCmd

# 移动生成的二进制文件到脚本目录
$sourceBinary = Join-Path $META_INF_PATH $BINARY_NAME
$destinationBinary = Join-Path $SCRIPT_DIR $BINARY_NAME
Move-Item -Path $sourceBinary -Destination $destinationBinary -Force

Pop-Location  # 退出 META_INF_PATH
Pop-Location  # 退出 BUILD_DIR

# 如果存在 upx，则进行压缩
if (Get-Command upx -ErrorAction SilentlyContinue) {
    Write-Host "Compressing the native Minecraft server with upx..."
    & upx $destinationBinary
}

Write-Host ""
Write-Host "Done! The native Minecraft server is located at:"
Write-Host $destinationBinary
