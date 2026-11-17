// Command srvlint enforces the rules of srv/README.md that a compiler does not: no shell and
// one place that starts programs, a closed and audited set of programs, and the layering of the
// packages. It reads the syntax trees of every .go file under srv/ (the standard library only:
// go/parser, go/ast, go/types for constants and name resolution, go/constant), never text.
//
//	go run ./tools/srvlint ./...           check everything (from srv/); exit 1 on a finding
//	go run ./tools/srvlint -checks=noshell ./...   one group: noshell, layers or all (default)
//	go run ./tools/srvlint -list ./...     print the programs the tree runs, per package
//	go run ./tools/srvlint -v ./...        also print the warnings about test files
//
// It is a tool of the repository, not of the release: it lives under srv/tools/, which
// scripts/build-server.sh and scripts/release.sh (they build srv/cmd/*) never look at. It imports
// internal/run only (to compare its Programs list), and nothing imports it.
package main

import (
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
)

func main() {
	args := flag.Bool("args", false, "print the table of arguments (per call site: constant, validated or other) and exit")
	argsFile := flag.String("argsfile", "tools/srvlint/args.txt", "the checked-in table of arguments, relative to the root")
	list := flag.Bool("list", false, "print the programs the tree runs, per package, and exit")
	checks := flag.String("checks", "all", "which checks: all, noshell or layers")
	programs := flag.String("programs", "tools/srvlint/programs.txt", "the checked-in list of programs, relative to the root")
	root := flag.String("root", ".", "the module directory (srv/)")
	verbose := flag.Bool("v", false, "print the warnings about test files too")
	flag.Parse()
	for _, a := range flag.Args() {
		if a != "./..." {
			fmt.Fprintf(os.Stderr, "srvlint: only ./... is supported (got %s)\n", a)
			os.Exit(2)
		}
	}
	res, err := Analyze(Config{Root: *root})
	if err != nil {
		fmt.Fprintln(os.Stderr, "srvlint:", err)
		os.Exit(2)
	}
	if *list {
		fmt.Print(strings.Join(res.Programs, "\n") + "\n")
		return
	}
	if *args {
		fmt.Print(strings.Join(res.Args, "\n") + "\n")
		fmt.Printf("# positions: %d constant, %d prefixed, %d int, %d validated, %d value of an option, %d after --, %d other\n", res.Counts["const"], res.Counts["prefixed"], res.Counts["int"], res.Counts["valid"], res.Counts["valueof"], res.Counts["after--"], res.Counts["other"])
		return
	}
	res.CheckRunPrograms()
	res.checkTableFile(*root+"/"+*argsFile, res.Args, "args")
	res.checkProgramsFile(*root + "/" + *programs)
	var bad []Finding
	for _, f := range res.Findings {
		if *checks == "all" || (*checks == "layers") == (f.Group == "layers") {
			bad = append(bad, f)
		}
	}
	sort.SliceStable(bad, func(i, j int) bool { return bad[i].Pos < bad[j].Pos })
	for _, f := range bad {
		fmt.Printf("%s: [%s] %s\n", f.Pos, f.Group, f.Msg)
	}
	if len(res.Warnings) > 0 {
		if *verbose {
			for _, f := range res.Warnings {
				fmt.Printf("warning: %s: [%s] %s\n", f.Pos, f.Group, f.Msg)
			}
		} else {
			fmt.Printf("srvlint: %d warnings in test files (-v shows them)\n", len(res.Warnings))
		}
	}
	if len(bad) > 0 {
		fmt.Printf("srvlint: %d findings\n", len(bad))
		os.Exit(1)
	}
	fmt.Printf("srvlint: ok (%d packages, %d programs)\n", res.NPackages, len(res.Programs))
}
