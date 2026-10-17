package proc

import (
	"bytes"
	"encoding/binary"
	"errors"
	"strings"
)

// parseLsofCwd extracts the path from `lsof -Fn` output: the first line
// starting with "n", without the prefix.
func parseLsofCwd(out string) (string, error) {
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "n") {
			return line[1:], nil
		}
	}
	return "", errors.New("proc: no cwd in lsof output")
}

// parseProcargs2 decodes a kern.procargs2 buffer: little-endian int32 argc,
// the NUL-terminated exec path, NUL padding, then argc NUL-terminated args
// (the environment that follows is ignored).
func parseProcargs2(b []byte) (exe string, args []string, err error) {
	if len(b) < 4 {
		return "", nil, errors.New("proc: short procargs2")
	}
	argc := int(int32(binary.LittleEndian.Uint32(b)))
	rest := b[4:]
	end := bytes.IndexByte(rest, 0)
	if end < 0 {
		return "", nil, errors.New("proc: unterminated exec path")
	}
	exe, rest = string(rest[:end]), rest[end:]
	for len(rest) > 0 && rest[0] == 0 {
		rest = rest[1:]
	}
	for i := 0; i < argc && len(rest) > 0; i++ {
		end := bytes.IndexByte(rest, 0)
		if end < 0 {
			end = len(rest)
		}
		args = append(args, string(rest[:end]))
		rest = rest[min(end+1, len(rest)):]
	}
	return exe, args, nil
}

// statFromKinfo maps kinfo_proc fields to a Stat. StartTime is in
// microseconds since the epoch; SZOMB (5) becomes "Z".
func statFromKinfo(comm string, ppid int, startSec, startUsec int64, pstat int8) Stat {
	state := "R"
	if pstat == 5 {
		state = "Z"
	}
	return Stat{Comm: comm, State: state, PPID: ppid, StartTime: uint64(startSec)*1e6 + uint64(startUsec)}
}
