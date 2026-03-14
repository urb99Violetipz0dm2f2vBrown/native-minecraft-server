#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cross-platform build script for native-minecraft-server (GraalVM native-image).

What it does:
- Works on Windows / Linux / macOS.
- Downloads Mojang server.jar (only if missing).
- Extracts META-INF/* to get classpath-joined + main-class.
- Compiles work/SelfMain.java and uses it as native-image entrypoint.
- Writes env-vars file (build/env.(cmd|sh)) so runtime can resolve real server entry.
- Optional: run native-image-agent to refresh/merge config.

Environment variables:
- GRAALVM_HOME (required)
- SERVER_VERSION (default: 1.21.11)
- GENERATE_CONFIG (optional: 1/true to run agent)
- NO_GUI (optional: 1/true, only used when GENERATE_CONFIG enabled)
- MC_ENTRY_CLASS (optional build-time override; default is read from META-INF/main-class)

Notes:
- SelfMain uses reflection to call the real server main. Ensure reflect-config.json includes the
  corresponding classes/methods (you already added entries).
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_DIR = SCRIPT_DIR / "configuration"
BUILD_DIR = SCRIPT_DIR / "build"
WORK_DIR = SCRIPT_DIR / "work"

SERVER_VERSION = os.environ.get("SERVER_VERSION", "1.21.11")
BINARY_NAME = "native-minecraft-server"

GRAALVM_HOME = os.environ.get("GRAALVM_HOME", "").strip()
if not GRAALVM_HOME:
    print("[ERROR] GRAALVM_HOME is not set. Please provide a GraalVM installation.")
    sys.exit(1)

GRAALVM_HOME_P = Path(GRAALVM_HOME)
NI_EXEC = (GRAALVM_HOME_P / "bin" / ("native-image.cmd" if os.name == "nt" else "native-image")).resolve()
JAVA_EXEC = (GRAALVM_HOME_P / "bin" / ("java.exe" if os.name == "nt" else "java")).resolve()
JAVAC_EXEC = (GRAALVM_HOME_P / "bin" / ("javac.exe" if os.name == "nt" else "javac")).resolve()

if not NI_EXEC.exists():
    print(f"[ERROR] native-image not found: {NI_EXEC}")
    sys.exit(1)
if not JAVA_EXEC.exists():
    print(f"[ERROR] java not found: {JAVA_EXEC}")
    sys.exit(1)
if not JAVAC_EXEC.exists():
    print(f"[ERROR] javac not found: {JAVAC_EXEC}")
    sys.exit(1)

JAR_PATH = BUILD_DIR / "server.jar"
ZIP_PATH = BUILD_DIR / "server.zip"
META_INF_PATH = BUILD_DIR / "META-INF"
VERSION_MARKER_PATH = BUILD_DIR / "server-version.txt"

SELFMAIN_SRC = WORK_DIR / "SelfMain.java"
SELFMAIN_OUT = BUILD_DIR / "selfmain-classes"

VERSION_MANIFEST_URL = "https://piston-meta.mojang.com/mc/game/version_manifest.json"


def run(cmd: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    printable = " ".join([f"\"{c}\"" if " " in c else c for c in cmd])
    print(f"[INFO] $ {printable}")
    subprocess.run(cmd, cwd=str(cwd) if cwd else None, env=env, check=True)


def download_json(url: str) -> dict:
    print(f"[INFO] Downloading JSON: {url}")
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read().decode("utf-8"))


def download_file(url: str, dest: Path) -> None:
    print(f"[INFO] Downloading: {url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as resp, open(dest, "wb") as f:
        shutil.copyfileobj(resp, f)


def truthy_env(name: str) -> bool:
    v = os.environ.get(name)
    if v is None:
        return False
    v = v.strip().lower()
    return v not in ("", "0", "false", "no", "off")


def ensure_build_artifacts() -> None:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    refresh_build_artifacts = True
    if VERSION_MARKER_PATH.exists() and JAR_PATH.exists() and META_INF_PATH.exists():
        current_build_version = VERSION_MARKER_PATH.read_text(encoding="utf-8").strip()
        refresh_build_artifacts = current_build_version != SERVER_VERSION

    if refresh_build_artifacts:
        if META_INF_PATH.exists():
            shutil.rmtree(META_INF_PATH, ignore_errors=True)
        if ZIP_PATH.exists():
            try:
                ZIP_PATH.unlink()
            except OSError:
                pass

        if not JAR_PATH.exists():
            manifest = download_json(VERSION_MANIFEST_URL)
            version_url = None
            for it in manifest.get("versions", []):
                if it.get("id") == SERVER_VERSION:
                    version_url = it.get("url")
                    break
            if not version_url:
                raise SystemExit(f"[ERROR] Unable to find manifest url for SERVER_VERSION={SERVER_VERSION}")

            server_manifest = download_json(version_url)
            server_url = server_manifest.get("downloads", {}).get("server", {}).get("url")
            if not server_url:
                raise SystemExit(f"[ERROR] Unable to find server.jar download url for SERVER_VERSION={SERVER_VERSION}")

            download_file(server_url, JAR_PATH)
            print(f"[INFO] Downloaded server.jar -> {JAR_PATH}")
        else:
            print(f"[INFO] Using existing server.jar: {JAR_PATH}")

        shutil.copy2(JAR_PATH, ZIP_PATH)
        print("[INFO] Extracting resources from server.zip ...")
        with zipfile.ZipFile(ZIP_PATH, "r") as zf:
            zf.extractall(path=str(BUILD_DIR))
        try:
            ZIP_PATH.unlink()
        except OSError:
            pass

        VERSION_MARKER_PATH.write_text(SERVER_VERSION, encoding="utf-8")

    if not (META_INF_PATH / "classpath-joined").exists():
        raise SystemExit("[ERROR] Unable to determine classpath (missing META-INF/classpath-joined)")
    if not (META_INF_PATH / "main-class").exists():
        raise SystemExit("[ERROR] Unable to determine main class (missing META-INF/main-class)")


def read_text(p: Path) -> str:
    return p.read_text(encoding="utf-8").strip()


def compile_selfmain() -> None:
    if not SELFMAIN_SRC.exists():
        raise SystemExit(f"[ERROR] Missing entrypoint source: {SELFMAIN_SRC}")

    SELFMAIN_OUT.mkdir(parents=True, exist_ok=True)
    # Always recompile to avoid stale classes.
    for f in SELFMAIN_OUT.rglob("*.class"):
        try:
            f.unlink()
        except OSError:
            pass

    run([str(JAVAC_EXEC), "-encoding", "UTF-8", "-d", str(SELFMAIN_OUT), str(SELFMAIN_SRC)])
    if not (SELFMAIN_OUT / "work" / "SelfMain.class").exists():
        raise SystemExit("[ERROR] Failed to compile SelfMain.java")


def write_env_files(main_class: str) -> None:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    # 1) Generate helper scripts for users to source.
    env_cmd = BUILD_DIR / "env.cmd"
    env_sh = BUILD_DIR / "env.sh"

    env_cmd.write_text(
        "\r\n".join(
            [
                "@echo off",
                "REM Auto-generated by build.py",
                f"set \"MC_ENTRY_CLASS={main_class}\"",
                "",
            ]
        )
        + "\r\n",
        encoding="utf-8",
    )

    env_sh.write_text(
        "\n".join(
            [
                "#!/usr/bin/env sh",
                "# Auto-generated by build.py",
                f"export MC_ENTRY_CLASS=\"{main_class}\"",
                "",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    try:
        os.chmod(env_sh, 0o755)
    except OSError:
        pass

    print(f"[INFO] Wrote runtime env helper: {env_cmd}")
    print(f"[INFO] Wrote runtime env helper: {env_sh}")

    # 2) Best-effort: set env var for current build.py process.
    # This does NOT affect the produced binary at runtime, but helps any subprocesses
    # or diagnostic tooling launched from this build process.
    os.environ["MC_ENTRY_CLASS"] = main_class


def maybe_run_agent(no_gui: bool) -> None:
    if not truthy_env("GENERATE_CONFIG"):
        return

    print(f"[INFO] GENERATE_CONFIG enabled. Running native-image-agent into: {CONFIG_DIR}")
    agent_opt = (
        f"-agentlib:native-image-agent=config-output-dir={CONFIG_DIR},"
        f"experimental-class-loader-support,config-merge-dir={CONFIG_DIR}"
    )

    args = [str(JAVA_EXEC), agent_opt, "-jar", str(JAR_PATH)]
    if no_gui:
        args.append("-nogui")

    run(args, cwd=SCRIPT_DIR)


def build_native_image(classpath_joined: str, extra_args: list[str]) -> None:
    # native-image expects OS path separators in -cp. classpath-joined in jar appears ';' separated.
    cp_server = classpath_joined
    if os.name != "nt":
        cp_server = cp_server.replace(";", ":")

    # Ensure SelfMain is first on classpath (so it can be resolved).
    cp_full = str(SELFMAIN_OUT) + (os.pathsep + cp_server if cp_server else "")

    system_name = platform.system().lower()

    args: list[str] = [
        str(NI_EXEC),
        "--no-fallback",
        "-H:ConfigurationFileDirectories=" + str(CONFIG_DIR),
        "-H:+AddAllCharsets",
        "-H:+ReportExceptionStackTraces",
        "--enable-url-protocols=https",
        "--initialize-at-run-time=io.netty",
        "--enable-monitoring=heapdump,jfr",
        "--enable-native-access=ALL-UNNAMED",
        "-H:+SharedArenaSupport",
        "--initialize-at-build-time=net.minecraft.util.profiling.jfr.event",
        "--initialize-at-build-time=org.apache.logging.log4j,org.apache.logging.slf4j,org.apache.logging.log4j.core.util.DefaultShutdownCallbackRegistry",
        "--initialize-at-run-time=joptsimple",
    ]

    if system_name == "linux":
        args.append("--gc=G1")

    # macOS needs desktop modules/init for AWT/Swing in some cases (kept consistent with build-macos.sh)
    if system_name == "darwin":
        args += [
            "--add-modules=java.desktop",
            "--initialize-at-run-time=java.awt",
            "--initialize-at-run-time=javax.swing",
            "--initialize-at-run-time=sun.awt",
            r'-H:IncludeResources=\Qjoptsimple/HelpFormatterMessages.properties\E',
            r'-H:IncludeResources=\Qjoptsimple/ExceptionMessages.properties\E',
        ]

    args += [
        "-H:Name=" + BINARY_NAME,
        "-cp",
        cp_full,
    ]

    # allow user to inject additional native-image args (e.g. -O, -H:+Trace...)
    args += extra_args

    # IMPORTANT: entrypoint is work.SelfMain (compiled from work/SelfMain.java)
    args.append("work.SelfMain")

    run(args, cwd=META_INF_PATH)

    # Move/copy output to repo root like original scripts.
    out_name = BINARY_NAME + (".exe" if os.name == "nt" else "")
    produced = META_INF_PATH / out_name
    if not produced.exists():
        raise SystemExit(f"[ERROR] Expected output not found: {produced}")

    final_out = SCRIPT_DIR / out_name
    shutil.copy2(produced, final_out)
    print("")
    print("[INFO] Done! Output:")
    print(str(final_out))


def main(argv: list[str]) -> int:
    # Allow passing extra native-image args after a `--` separator.
    extra_args: list[str] = []
    if "--" in argv:
        idx = argv.index("--")
        extra_args = argv[idx + 1 :]
        argv = argv[:idx]

    ensure_build_artifacts()

    classpath_joined = read_text(META_INF_PATH / "classpath-joined")
    main_class_in_jar = read_text(META_INF_PATH / "main-class")

    # Build-time override (optional), but default is jar-provided main-class.
    main_class = os.environ.get("MC_ENTRY_CLASS", "").strip() or main_class_in_jar

    print(f"[INFO] Server main-class (META-INF/main-class): {main_class_in_jar}")
    print(f"[INFO] Using MC_ENTRY_CLASS for runtime: {main_class}")

    # Write helper env files so users can easily run with correct entry.
    write_env_files(main_class)

    # Compile SelfMain so native-image can use it as entrypoint.
    compile_selfmain()

    # Optional agent run to refresh configs.
    maybe_run_agent(no_gui=truthy_env("NO_GUI"))

    # Build native image
    build_native_image(classpath_joined=classpath_joined, extra_args=extra_args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))