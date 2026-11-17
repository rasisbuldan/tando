package daemon

import (
	_ "tando/srv/daemon/proto"
	_ "tando/srv/internal/b"
	_ "tando/srv/logs"
	_ "tando/srv/status"
	_ "tando/srv/status/sdbus"
	_ "tando/srv/watch/sub"
)
