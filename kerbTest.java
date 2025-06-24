import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.io.Console;

public class KerberosSqlServerAuthTest {

    public static void main(String[] args) {
        String server = getValue("SQLSERVER_HOST", "sqlserver.host", "SQL Server Host (FQDN): ");
        String database = getValue("SQLSERVER_DB", "sqlserver.db", "Database Name: ");
        String username = getValue("KRB_USER", "kerb.user", "Kerberos Username (user@DOMAIN.COM or DOMAIN\\user): ");
        String password = getPassword();

        // JDBC URL for SQL Server with Kerberos
        String connectionUrl = String.format(
                "jdbc:sqlserver://%s:1433;databaseName=%s;" +
                        "integratedSecurity=true;authenticationScheme=JavaKerberos;userName=%s",
                server, database, username
        );

        // Set krb5.conf path (assumed always at /etc/krb5.conf)
        System.setProperty("java.security.krb5.conf", "/etc/krb5.conf");
        // Uncomment for Kerberos debugging:
        // System.setProperty("sun.security.krb5.debug", "true");

        try {
            Class.forName("com.microsoft.sqlserver.jdbc.SQLServerDriver");

            // If password is required for this principal, add it as a property
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
            // Clear sensitive data
            password = null;
        }
    }

    // Get value from env, then system property, then prompt
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

    // Securely get password from env, property, or prompt
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
