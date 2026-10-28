// A single-user research service. Authentication is exclusively public-key.
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PAM_AUTH 0
#define DROPBEAR_SVR_MULTIUSER 1
// Darwin has setgid/initgroups/setuid, but no Linux-style setresgid.
// Use upstream's session-time user switch instead of its early-drop mode.
#define DROPBEAR_SVR_DROP_PRIVS 0
#define DROPBEAR_SVR_AGENTFWD 0
#define DROPBEAR_SVR_X11FWD 0
#define DROPBEAR_SVR_LOCALTCPFWD 0
#define DROPBEAR_SVR_REMOTETCPFWD 0
#define DROPBEAR_SVR_LOCALSTREAMFWD 0
#define DROPBEAR_SVR_REMOTESTREAMFWD 0
#define DROPBEAR_PLUGIN 0
#define DROPBEAR_RSA 0
#define DROPBEAR_ECDSA 0
#define DROPBEAR_DSS 0
#define DROPBEAR_ED25519 1
#define DO_MOTD 0
#define DEFAULT_PATH "/usr/local/libexec/vphone-ssh:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/libexec/vphone-ssh/bin"
#define DEFAULT_ROOT_PATH DEFAULT_PATH
