package work;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/**
 * Minimal entrypoint for native-image AOT compilation.
 *
 * Behavior:
 * 1) Ensures eula.txt exists with "eula=true".
 * 2) Delegates to the real Minecraft server main, passing through args.
 *
 * This is useful when you want a controlled entrypoint that always generates EULA.
 */
public final class SelfMain {
    private SelfMain() {}

    public static void main(String[] args) {
        configureRuntimeDefaults();

        try {
            // Match Minecraft server behavior: EULA is checked in current working directory.
            // Avoid repeated disk writes: only create it if missing.
            Path eula = Path.of("eula.txt");
            if (!Files.exists(eula)) {
                Files.writeString(eula, "eula=true\n", StandardCharsets.UTF_8);
            }
        } catch (IOException e) {
            // Don't fail hard; still try to start the server. Print for debugging.
            e.printStackTrace();
        }

        // Prefer query.port from server.properties; if occupied, increment until a free port is found.
        int port = findAvailablePort(resolvePreferredPort());

        // Delegate to the real server main.
        // Force --nogui and inject --port while preserving user args.
        String[] forwarded;
        if (args == null || args.length == 0) {
            forwarded = new String[] { "--nogui", "--port", String.valueOf(port) };
        } else {
            forwarded = new String[args.length + 3];
            forwarded[0] = "--nogui";
            forwarded[1] = "--port";
            forwarded[2] = String.valueOf(port);
            System.arraycopy(args, 0, forwarded, 3, args.length);
        }

        // Determine real server main class, in priority order:
        // 1) env var MC_ENTRY_CLASS (written by build.py into build/env.{cmd,sh} for easy sourcing)
        // 2) META-INF/main-class (build.py already includes it as a resource in native image config)
        // 3) final fallback: net.minecraft.server.Main (vanilla)
        String entryClass = System.getenv("MC_ENTRY_CLASS");
        if (entryClass == null || entryClass.isBlank()) {
            entryClass = readResourceOrFileMainClass();
        }
        if (entryClass == null || entryClass.isBlank()) {
            entryClass = "net.minecraft.server.Main";
        }

        // Also expose the resolved entry to the process env for downstream code that reads it
        // via System.getenv (can't mutate env reliably), so we set a system property too.
        System.setProperty("MC_ENTRY_CLASS", entryClass);

        try {
            Class<?> mainClz = Class.forName(entryClass);
            java.lang.reflect.Method m = mainClz.getMethod("main", String[].class);
            m.invoke(null, (Object) forwarded);
        } catch (Throwable t) {
            t.printStackTrace();
        }
    }

    private static void configureRuntimeDefaults() {
        // Avoid loading AWT when the native server is always started with --nogui.
        setSystemPropertyIfAbsent("java.awt.headless", "true");

        // Reduce Log4j features that are problematic or unnecessary in Native Image.
        setSystemPropertyIfAbsent("log4j2.disableJmx", "true");
        setSystemPropertyIfAbsent("log4j2.disable.jmx", "true");
        setSystemPropertyIfAbsent("log4j2.is.webapp", "false");
        setSystemPropertyIfAbsent("log4j2.shutdownHookEnabled", "false");

        // Prefer the simple Log4j provider to avoid initializing log4j-core WatchManager,
        // which triggers runtime lambda class generation in Native Image.
        setSystemPropertyIfAbsent("log4j.provider", "org.apache.logging.log4j.simple.internal.SimpleProvider");
        setSystemPropertyIfAbsent("log4j2.loggerContextFactory", "org.apache.logging.log4j.simple.SimpleLoggerContextFactory");
    }

    private static void setSystemPropertyIfAbsent(String key, String value) {
        if (System.getProperty(key) == null) {
            System.setProperty(key, value);
        }
    }

    private static int resolvePreferredPort() {
        Path serverProperties = Path.of("server.properties");
        if (!Files.exists(serverProperties)) {
            return 25565;
        }

        Properties properties = new Properties();
        try (var in = Files.newInputStream(serverProperties)) {
            properties.load(in);
        } catch (IOException ignored) {
            return 25565;
        }

        String value = properties.getProperty("query.port");
        if (value == null || value.isBlank()) {
            return 25565;
        }

        try {
            int port = Integer.parseInt(value.trim());
            if (port < 1 || port > 65535) {
                return 25565;
            }
            return port;
        } catch (NumberFormatException ignored) {
            return 25565;
        }
    }

    private static int findAvailablePort(int startPort) {
        int port = startPort;
        while (true) {
            try (ServerSocket ss = new ServerSocket()) {
                ss.setReuseAddress(false);
                ss.bind(new InetSocketAddress("0.0.0.0", port));
                return port;
            } catch (IOException ignored) {
                port++;
                if (port > 65535) {
                    throw new RuntimeException("No available port found in range " + startPort + "-65535");
                }
            }
        }
    }

    private static String readResourceOrFileMainClass() {
        // Try classpath resource first (works inside native-image if included).
        try (var is = SelfMain.class.getClassLoader().getResourceAsStream("META-INF/main-class")) {
            if (is != null) {
                return new String(is.readAllBytes(), StandardCharsets.UTF_8).trim();
            }
        } catch (Throwable ignored) {
        }

        // Fallback: if someone runs on JVM or keeps META-INF extracted on disk.
        try {
            Path p = Path.of("META-INF", "main-class");
            if (Files.exists(p)) {
                return Files.readString(p, StandardCharsets.UTF_8).trim();
            }
        } catch (Throwable ignored) {
        }

        return null;
    }
}
