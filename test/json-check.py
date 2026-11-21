#!/usr/bin/env python3
# test/json-check.py: the checker of test/json-contract.sh. No third-party module.
#
#   json-check.py check <schema> <json file>   every schema line holds: exit 0, else one line per
#                                               broken rule on stdout and exit 1
#   json-check.py derive <json file>...        a schema from outputs (the union of what they show),
#                                               for a new verb; review its "null" lines by hand
#
# A schema is one rule per line: <path>:<type>. A path is keys joined by ".", "[]" after a key for
# every element of an array ("apps[].state"); the empty path "" is the document itself. Types:
# string, number, bool, null, array, object, and null-or-<type> (null or that type). A key the
# schema names must be present (a removed key fails), with that type (a retyped key fails); keys it
# does not name pass (adding a key is not a break). An array the rules walk into must not be empty
# in the output checked (else its elements' rules would hold vacuously). Lines starting with # and
# blank lines are ignored.
import json
import sys


def kind(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


def walk(doc, parts, where, errs):
    """the values at parts below doc (a list: [] fans out), or [] with an error noted"""
    vals = [(doc, where)]
    for p in parts:
        nxt = []
        arr = p.endswith("[]")
        key = p[:-2] if arr else p
        for v, w in vals:
            if key:
                if not isinstance(v, dict):
                    errs.append("%s: not an object (%s)" % (w or "(top)", kind(v)))
                    continue
                if key not in v:
                    errs.append("%s: missing" % (w + "." + key if w else key))
                    continue
                v, w = v[key], (w + "." + key if w else key)
            if arr:
                if not isinstance(v, list):
                    if v is not None:
                        errs.append("%s: not an array (%s)" % (w, kind(v)))
                    continue
                if not v:
                    errs.append("%s: empty array: its element rules would hold vacuously" % w)
                for i, e in enumerate(v):
                    nxt.append((e, "%s[%d]" % (w, i)))
            else:
                nxt.append((v, w))
        vals = nxt
    return vals


def check(schema, doc):
    errs = []
    for ln in open(schema, encoding="utf-8"):
        ln = ln.rstrip("\n")
        if not ln.strip() or ln.startswith("#"):
            continue
        path, _, typ = ln.rpartition(":")
        want = typ.split("null-or-")[-1]
        nullable = typ.startswith("null-or-") or typ == "null"
        if want not in ("string", "number", "bool", "null", "array", "object"):
            errs.append("bad rule: " + ln)
            continue
        parts = [p for p in path.split(".") if p] if path else []
        for v, w in walk(doc, parts, "", errs):
            k = kind(v)
            if k == want or (k == "null" and nullable):
                continue
            errs.append("%s: %s, want %s" % (w or "(top)", k, typ))
    return errs


def derive(docs):
    seen = {}

    def rec(v, path):
        k = kind(v)
        seen.setdefault(path, set()).add(k)
        if k == "object":
            for key, x in v.items():
                rec(x, path + "." + key if path else key)
        elif k == "array":
            for x in v:
                rec(x, path + "[]")
            if v:
                seen[path].add("array")

    for d in docs:
        rec(d, "")
    for path in sorted(seen):
        ks = seen[path] - {"null"}
        if len(ks) > 1:
            t = "/".join(sorted(ks)) + "?"
        elif ks:
            t = ("null-or-" if "null" in seen[path] else "") + ks.pop()
        else:
            t = "null"
        if path.endswith("[]"):
            continue  # the element itself: its keys carry the rules
        print("%s:%s" % (path, t))


def load(f):
    with open(f, encoding="utf-8") as fh:
        return json.load(fh)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "check":
        try:
            doc = load(sys.argv[3])
        except ValueError as e:
            print("not JSON: %s" % e)
            sys.exit(1)
        errs = check(sys.argv[2], doc)
        for e in errs:
            print(e)
        sys.exit(1 if errs else 0)
    if len(sys.argv) >= 3 and sys.argv[1] == "derive":
        derive([load(f) for f in sys.argv[2:]])
        sys.exit(0)
    print(__doc__ if __doc__ else "usage: json-check.py check <schema> <json> | derive <json>...")
    sys.exit(2)
