#!/usr/bin/env python3
"""Reference for test/e2e-jobs.sh: the next times a crontab(5) schedule runs, computed from the
cron rules themselves (not from the OnCalendar text tando makes of it), to compare with what
systemd-analyze says about that text.

usage: cron-ref.py "<5 fields>" "<YYYY-MM-DD HH:MM:SS base>" <count>
prints the next <count> times after the base, one "YYYY-MM-DD HH:MM:SS" per line."""
import datetime
import sys

NAMES = {"jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9,
         "oct": 10, "nov": 11, "dec": 12, "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6}


def num(w):
    w = w.lower()
    return NAMES[w] if w in NAMES else int(w)


def field(text, lo, hi):
    out = set()
    for item in text.split(","):
        rng, _, step = item.partition("/")
        step = int(step) if step else 1
        if rng == "*":
            a, b = lo, hi
        elif "-" in rng:
            x, y = rng.split("-")
            a, b = num(x), num(y)
        else:
            a = b = num(rng)
        out.update(range(a, b + 1, step))
    return out


MACROS = {"@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
          "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"}


def main():
    f = MACROS.get(sys.argv[1], sys.argv[1]).split()
    base = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%d %H:%M:%S")
    count = int(sys.argv[3])
    mi, h, dom, mon, dow = field(f[0], 0, 59), field(f[1], 0, 23), field(f[2], 1, 31), field(f[3], 1, 12), field(f[4], 0, 7)
    dow = {d % 7 for d in dow}
    dom_star, dow_star = f[2].startswith("*"), f[4].startswith("*")
    n = 0
    day = base.replace(hour=0, minute=0, second=0)
    for _ in range(5000):  # days: enough for a 29 February
        wd = (day.weekday() + 1) % 7  # cron: Sunday is 0
        if day.month in mon:
            if dom_star or dow_star:
                ok = day.day in dom and wd in dow
            else:
                ok = day.day in dom or wd in dow
            if ok:
                for hh in sorted(h):
                    for mm in sorted(mi):
                        t = day.replace(hour=hh, minute=mm)
                        if t > base and n < count:
                            print(t.strftime("%Y-%m-%d %H:%M:%S"))
                            n += 1
        if n >= count:
            return
        day += datetime.timedelta(days=1)


main()
