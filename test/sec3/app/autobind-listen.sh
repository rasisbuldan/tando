#!/bin/bash
# sec3 S7: SocketBindDeny filters bind(); listen() on an unbound socket autobinds an ephemeral port on
# 0.0.0.0, so an app (or its job) gets a listener on every interface despite "binds only its port".
set -u; . "$(dirname "$0")/lib.sh"; : "${HP:?}"
x 'perl -MSocket -e "socket(S,PF_INET,SOCK_STREAM,0) or die; listen(S,5) or die qq(listen: \$!); my (\$p)=sockaddr_in(getsockname(S)); print qq(listening on 0.0.0.0:\$p\n); sleep 2" & sleep 1; ss -Hltnp | grep perl'
