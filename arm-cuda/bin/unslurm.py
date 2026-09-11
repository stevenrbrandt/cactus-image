#!/usr/bin/env python3
"""Expand a SLURM nodelist into an explicit list of host names.

    unslurm.py                      # expands $SLURM_NODELIST
    unslurm.py 'db[001-003],dbgpu05'
    unslurm.py -s ...               # space separated instead of comma
    unslurm.py -i ...               # resolve each name to an IP address

Also importable:  from unslurm import unslurm

Fixes over the prototype in ~/repos/workenv/bin: that version applied one
re.match to the whole string, so a nodelist mixing a bracket group with
anything else silently lost hosts --

    db[001-003],dbgpu05      -> db001,db002,db003        (dbgpu05 dropped)
    db[001-002],db[005-006]  -> db001,db002              (second group dropped)
    dbgpu05,db[001-003]      -> dbgpu05,db[001-003]      (left unexpanded,
                                                          then handed to
                                                          mpirun as a host)

Those are exactly the shapes SLURM emits for a heterogeneous allocation,
and losing a host means ranks quietly land in the wrong place.
"""
import os
import re
import socket
import sys


def _split_top_level(s):
    """Split on commas that are not inside a [...] group."""
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur:
        parts.append(cur)
    return parts


def format_host(host, ipaddr):
    return socket.gethostbyname(host) if ipaddr else host


def _expand_group(base, body, suffix, ipaddr):
    """Expand one 'base[body]suffix' term, e.g. db[001-003,007]."""
    hosts = []
    for ext in body.split(","):
        g = re.match(r"^(\d+)-(\d+)$", ext)
        if g:
            lo, hi = g.group(1), g.group(2)
            # Keep SLURM's zero padding: db[001-003] is db001, not db1.
            width = max(len(lo), len(hi))
            for i in range(int(lo), int(hi) + 1):
                hosts.append(format_host("%s%0*d%s" % (base, width, i, suffix), ipaddr))
        else:
            hosts.append(format_host(base + ext + suffix, ipaddr))
    return hosts


def unslurm(fname, ipaddr=False):
    """Expand a (possibly compound) SLURM nodelist into a list of hosts."""
    hosts = []
    for term in _split_top_level(fname):
        term = term.strip()
        if not term:
            continue
        g = re.match(r"^([^\[\]]+)\[([^\]]+)\](.*)$", term)
        if g:
            hosts += _expand_group(g.group(1), g.group(2), g.group(3), ipaddr)
        else:
            hosts.append(format_host(term, ipaddr))
    return hosts


if __name__ == "__main__":
    spaces = ipaddr = False
    targets = []
    for a in sys.argv[1:]:
        if a == "-s":
            spaces = True
        elif a == "-i":
            ipaddr = True
        else:
            targets.append(a)
    # Only fall back to the allocation when no nodelist was named. The
    # prototype appended $SLURM_NODELIST unconditionally, so an explicit
    # argument inside a job printed both it and the allocation.
    if not targets and "SLURM_NODELIST" in os.environ:
        targets = [os.environ["SLURM_NODELIST"]]
    hosts = []
    for t in targets:
        hosts += unslurm(t, ipaddr)
    print((" " if spaces else ",").join(hosts))
