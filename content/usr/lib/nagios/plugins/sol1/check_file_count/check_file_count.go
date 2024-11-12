package main

import (
	"flag"
	"fmt"
	"os"
	"regexp"
)

const UNKNOWN int = 3
const CRITICAL int = 2
const WARNING int = 1
const OK int = 0

func usage() {
	fmt.Printf("usage: check_file_count [-w count] [-c count] [-r regex] path\n")
}

// FileNames takes a slice of FileInfos returned from os.Readdir, and prints a
// listing of the file names in the slice.
func FileNames(fi []os.FileInfo) {
	for i := 0; i < len(fi); i++ {
		filename := fi[i].Name()
		fmt.Printf("%s\n", filename)
	}
}

func main() {
	var dir string
	var warn *int
	var crit *int
	var reg *string
	var ret int

	warn = flag.Int("w", 8, "warning count")
	crit = flag.Int("c", 16, "warning count")
	reg = flag.String("r", "", "regex to match files on")
	flag.Parse()

	dir = flag.Arg(0)
	if dir == "" {
		usage()
		os.Exit(255)
	}

	f, err := os.Open(dir)
	if err != nil {
		fmt.Printf("Error opening %s: %v\n", dir, err)
	}
	fileinfo, err := f.Readdir(0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading directory: %v", err)
	}

	//If the regex flag isn't empty then filter the results
	if *reg != "" {
		//Check input is valid regex
		regex, err := regexp.Compile(`(?i)` + *reg)
		if err != nil {
			fmt.Printf("Error compiling regex: %s\n", err)
			os.Exit(255)
			return
		}

		//Build new slice where the filename matches the regular expression
		var filteredResults []os.FileInfo
		for _, file := range fileinfo {
			if regex.MatchString(file.Name()) {
				filteredResults = append(filteredResults, file)
			}
		}

		fileinfo = filteredResults
	}

	/*
	 * Compare the file count against threshold values and set icinga2(8)
	 * compatible exit codes accordingly.
	 */

	count := len(fileinfo)
	ret = UNKNOWN
	retText := "UNKNOWN"
	if count >= *crit {
		ret = CRITICAL
		retText = "CRITICAL"
	} else if count >= *warn {
		ret = WARNING
		retText = "WARNING"
	} else if count <= *warn {
		ret = OK
		retText = "OK"
	}

	filterText := ""
	if *reg != "" {
		filterText = "filtered by: " + *reg
	}

	fmt.Printf("%s: %d files present in %s %s\n", retText, count, dir, filterText)
	FileNames(fileinfo)
	os.Exit(ret)
}
