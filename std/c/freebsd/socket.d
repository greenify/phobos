// Written in the D programming language.

// @@@DEPRECATED_2017-06@@@

/++
    $(RED Deprecated. Use the appropriate $(D core.sys.posix.*) modules instead.
          This module will be removed in June 2017.)
  +/
deprecated("Import the appropriate core.sys.posix.* modules instead")
module std.c.freebsd.socket;

version (FreeBSD):
public import core.sys.posix.netdb;
public import core.sys.posix.netinet.in_ : IPPROTO_PUP,
                                           IPPROTO_ND,
                                           IPPROTO_MAX,
                                           IPPROTO_IGMP,
                                           IPPROTO_IDP,
                                           IPPROTO_GGP,
                                           INADDR_NONE,
                                           INADDR_LOOPBACK;
public import core.sys.posix.sys.socket : AF_APPLETALK, AF_IPX, MSG_NOSIGNAL, SOCK_RDM;
