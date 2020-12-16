import argparse
import os
import sqlite3
import z3
import json
from pkg_resources import get_distribution

def order(d):
    return("%s %s %s %d" % (d['kind'], d['from'], d.get('to', ""), d['at']))

def main():
    # Command-line argument parsing.
    parser = argparse.ArgumentParser(description='Lineage-driven fault injection.')
    parser.add_argument('--eff', metavar='TIME', type=int, required=True,
                        help='the time when finite failures end')
    parser.add_argument('--crashes', metavar='INT', type=int, required=True,
                        help='the max amount of node crashes')
    parser.add_argument('--test-id', metavar='TEST_ID', type=int, required=True,
                        help='the test id')
    parser.add_argument('--run-ids', metavar='RUN_ID', type=int, nargs='+', required=True,
                        help='the run ids')
    parser.add_argument('--json', action='store_true', help='output in JSON format?')
    parser.add_argument('--version', '-v', action='version',
                        version=get_distribution(__name__).version)

    args = parser.parse_args()

    # Load network traces from the database.
    db = os.getenv("DETSYS_DB", os.getenv("HOME") + "/.detsys.db")
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()

    products = []
    crashes = set()

    for run_id in args.run_ids:
        sums = []
        c.execute("""select * from network_trace
                     where test_id = (?)
                       and run_id = (?)
                       and kind <> 'timer'
                       and not (`from` like 'client:%')
                       and not (`to`   like 'client:%')""",
                  (args.test_id, run_id))
        for r in c:
            if r['at'] < args.eff:
                sums.append({"var":"{'kind':'omission', 'from':'%s', 'to':'%s', 'at':%d}" %
                             (r['from'], r['to'], r['at']),
                             "dropped": r['dropped']})
            crash = "{'kind':'crash', 'from':'%s', 'at':%d}" % (r['from'], r['at'])
            #sums.append(crash)
            #crashes.add(crash)
        products.append(sums)

    c.close()

    # Sanity check.
    for i, run_id in enumerate(args.run_ids):
        if not products[i]:
            print("Error: couldn't find a network trace for test id: %d, and run id: %d." %
                  (args.test_id, run_id))
            exit(1)

    # Create and solve SAT formula.
    for i, sum in enumerate(products):
        kept = [x["var"] for x in sum if x["dropped"] == 0]
        drop = [x["var"] for x in sum if x["dropped"] == 1]
        kept = z3.Bools(kept)
        drop = z3.Bools(drop)
        products[i] = z3.Or(z3.Or(kept), z3.Not(z3.And(drop)))

    crashes = z3.Bools(list(crashes))

    s = z3.Solver()
    s.add(z3.And(products))
    if crashes:
        crashes.append(args.crashes)
        s.add(z3.AtMost(crashes))
    r = s.check()

    # Output the result.
    if r == z3.unsat:
        if not(args.json):
            print("No further faults can be injected at this point, the test case is")
            print("certified for this particular failure specification!")
        else:
            print(json.dumps({"faults": []}))
    elif r == z3.unknown:
             print("Impossible: the SAT solver returned 'unknown'")
             try:
                 print(s.model())
             except Z3Exception:
                 pass
             finally:
                 exit(2)
    else:
        m = s.model()

        statistics = {}
        for k, v in s.statistics():
            statistics[k] = v

        if not(args.json):
            print(m)
            print(statistics)
        else:
            faults = []
            for d in m.decls():
                if m[d]:
                    Dict = eval(d.name())
                    faults.append(Dict)
            faults = sorted(faults, key=order)

            print(json.dumps({"faults": faults,
                              "statistics": statistics}))

if __name__ == '__main__':
    main()
