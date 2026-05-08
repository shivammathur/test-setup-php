import java.io.File;
import java.net.InetAddress;

import com.unboundid.ldap.listener.InMemoryDirectoryServer;
import com.unboundid.ldap.listener.InMemoryDirectoryServerConfig;
import com.unboundid.ldap.listener.InMemoryListenerConfig;
import com.unboundid.ldap.listener.SelfSignedCertificateGenerator;
import com.unboundid.ldap.sdk.schema.Schema;
import com.unboundid.util.ObjectPair;
import com.unboundid.util.ssl.KeyStoreKeyManager;
import com.unboundid.util.ssl.SSLUtil;

public final class LdapTestServer {
    public static void main(String[] args) throws Exception {
        InMemoryDirectoryServerConfig config =
            new InMemoryDirectoryServerConfig("dc=example,dc=org");
        config.setSchema(Schema.getDefaultStandardSchema());

        ObjectPair<File, char[]> keyStore =
            SelfSignedCertificateGenerator.generateTemporarySelfSignedCertificate(
                "LdapTestServer",
                "JKS"
            );
        SSLUtil serverSSLUtil = new SSLUtil(
            new KeyStoreKeyManager(keyStore.getFirst(), keyStore.getSecond(), "JKS", null),
            null
        );

        InetAddress loopback = InetAddress.getByName("127.0.0.1");
        config.setListenerConfigs(InMemoryListenerConfig.createLDAPConfig(
            "LDAP",
            loopback,
            1389,
            serverSSLUtil.createSSLSocketFactory()
        ), InMemoryListenerConfig.createLDAPSConfig(
            "LDAPS",
            loopback,
            1636,
            serverSSLUtil.createSSLServerSocketFactory(),
            null
        ));
        config.addAdditionalBindCredentials(
            "cn=admin,dc=example,dc=org",
            "secret"
        );

        InMemoryDirectoryServer server = new InMemoryDirectoryServer(config);
        server.add(
            "dn: dc=example,dc=org",
            "objectClass: top",
            "objectClass: domain",
            "dc: example"
        );
        server.add(
            "dn: ou=People,dc=example,dc=org",
            "objectClass: top",
            "objectClass: organizationalUnit",
            "ou: People"
        );
        server.add(
            "dn: uid=alice,ou=People,dc=example,dc=org",
            "objectClass: top",
            "objectClass: person",
            "objectClass: organizationalPerson",
            "objectClass: inetOrgPerson",
            "cn: Alice Example",
            "sn: Example",
            "uid: alice",
            "mail: alice@example.org",
            "userPassword: alice-secret"
        );
        server.add(
            "dn: uid=brian,ou=People,dc=example,dc=org",
            "objectClass: top",
            "objectClass: person",
            "objectClass: organizationalPerson",
            "objectClass: inetOrgPerson",
            "cn: Brian Example",
            "sn: Example",
            "uid: brian",
            "mail: brian@example.org",
            "userPassword: brian-secret"
        );
        server.add(
            "dn: uid=carol,ou=People,dc=example,dc=org",
            "objectClass: top",
            "objectClass: person",
            "objectClass: organizationalPerson",
            "objectClass: inetOrgPerson",
            "cn: Carol Example",
            "sn: Example",
            "uid: carol",
            "mail: carol@example.org",
            "userPassword: carol-secret"
        );
        server.add(
            "dn: ou=Groups,dc=example,dc=org",
            "objectClass: top",
            "objectClass: organizationalUnit",
            "ou: Groups"
        );
        server.add(
            "dn: cn=developers,ou=Groups,dc=example,dc=org",
            "objectClass: top",
            "objectClass: groupOfNames",
            "cn: developers",
            "member: uid=alice,ou=People,dc=example,dc=org",
            "member: uid=brian,ou=People,dc=example,dc=org"
        );

        server.startListening();
        System.out.println("LDAP server ready on 127.0.0.1:1389");
        System.out.println("LDAPS server ready on 127.0.0.1:1636");
        System.out.flush();
        Thread.currentThread().join();
    }
}
