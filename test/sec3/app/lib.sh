# sec3 helpers (source me). Needs: R (bin/tando), HP (http port), an app "alpha" with the backdoor of
# test/sec2/w/alpha (POST /__x runs bash as tando-alpha inside its unit), victim "bravo".
x() { curl -s -m ${XT:-60} --data-binary @- "http://${XAPP:-alpha}.localhost:$HP/__x" <<< "$*"; }
