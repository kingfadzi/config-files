import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.io.Console;

public class KerberosSqlServerAuthTest {

    public static void main(String[] args) {
        String server = getValue("SQLSERVER_HOST", "sqlserver.host", "SQL Server Host (FQDN): ");
        String port = getValue("SQLSERVER_PORT", "sqlserver.port", "SQL Server Port: ");
        if (port == null || port.isBlank()) {
            System.err.println("Error: SQL Server port must be provided.");
            System.exit(1);
        }

        String database = getValue("SQLSERVER_DB", "sqlserver.db", "Database Name: ");
        String username = getValue("KRB_USER", "kerb.user", "Kerberos Username (user@DOMAIN.COM or DOMAIN\\user): ");
        String password = getPassword();

        String connectionUrl = String.format(
                "jdbc:sqlserver://%s:%s;databaseName=%s;" +
                        "integratedSecurity=true;authenticationScheme=JavaKerberos;trustServerCertificate=true;userName=%s",
                server, port, database, username
        );

        System.setProperty("java.security.krb5.conf", "/etc/krb5.conf");
        System.setProperty("sun.security.krb5.debug", "true");

        try {
            Class.forName("com.microsoft.sqlserver.jdbc.SQLServerDriver");

            java.util.Properties props = new java.util.Properties();
            props.setProperty("user", username);
            if (password != null && !password.isEmpty()) {
                props.setProperty("password", password);
            }

            try (Connection conn = DriverManager.getConnection(connectionUrl, props);
                 Statement stmt = conn.createStatement();
                 ResultSet rs = stmt.executeQuery(
                         "SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id=@@spid")) {

                while (rs.next()) {
                    System.out.println("Authentication Scheme: " + rs.getString(1));
                }
                System.out.println("Kerberos authentication test succeeded.");
            }
        } catch (Exception e) {
            System.err.println("Kerberos authentication test failed:");
            e.printStackTrace();
        } finally {
            password = null;
        }
    }

    private static String getValue(String envName, String propName, String prompt) {
        String value = System.getenv(envName);
        if (value != null && !value.isEmpty()) return value;

        value = System.getProperty(propName);
        if (value != null && !value.isEmpty()) return value;

        Console console = System.console();
        if (console != null) {
            value = console.readLine(prompt);
        } else {
            System.out.print(prompt);
            try {
                value = new java.util.Scanner(System.in).nextLine();
            } catch (Exception e) {
                throw new RuntimeException("Unable to read input", e);
            }
        }
        return value;
    }

    private static String getPassword() {
        String value = System.getenv("KRB_PASSWORD");
        if (value != null) return value;

        value = System.getProperty("kerb.password");
        if (value != null) return value;

        Console console = System.console();
        if (console != null) {
            char[] pwd = console.readPassword("Kerberos Password (leave blank for ticket cache): ");
            return pwd == null ? "" : new String(pwd);
        } else {
            System.out.print("Kerberos Password (leave blank for ticket cache): ");
            try {
                return new java.util.Scanner(System.in).nextLine();
            } catch (Exception e) {
                throw new RuntimeException("Unable to read password", e);
            }
        }
    }
}
