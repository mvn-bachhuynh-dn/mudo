package fake

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"sync"
)

type window struct {
	Pct       float64 `json:"pct"`
	Clock     string  `json:"clock,omitempty"`
	Countdown string  `json:"countdown,omitempty"`
}

type scoped struct {
	Name string `json:"name"`
	window
}

type usage struct {
	FiveHour window   `json:"fiveHour"`
	SevenDay window   `json:"sevenDay"`
	Scoped   []scoped `json:"scoped,omitempty"`
}

type account struct {
	Number       int    `json:"number"`
	Email        string `json:"email"`
	Organization string `json:"organizationName"`
	Alias        string `json:"alias,omitempty"`
	Active       bool   `json:"active"`
	UsageStatus  string `json:"usageStatus"`
	Usage        *usage `json:"usage"`
	LastGood     *usage `json:"lastGoodUsage,omitempty"`
}

// Cswap returns a runner that mimics `cswap list --json` and `cswap switch <n>` with made-up
// accounts (placeholder addresses only), for screenshots and UI work. A switch moves the
// active mark, so clicking in the widget has a visible effect. Safe for concurrent use.
func Cswap() func(ctx context.Context, args ...string) ([]byte, error) {
	var mu sync.Mutex
	active := 1
	accounts := func() []account {
		u := func(five, seven float64, fable float64) *usage {
			return &usage{
				FiveHour: window{Pct: five, Clock: "22:49", Countdown: "4h 4m"},
				SevenDay: window{Pct: seven, Clock: "Nov 14 05:59", Countdown: "5d 11h"},
				Scoped:   []scoped{{Name: "Fable", window: window{Pct: fable, Clock: "Nov 13 22:00", Countdown: "5d 3h"}}},
			}
		}
		list := []account{
			{Number: 1, Email: "alex@example.com", Organization: "Team Alpha", UsageStatus: "ok", Usage: u(18, 41, 0)},
			{Number: 2, Email: "sam@example.com", Organization: "Team Beta", UsageStatus: "ok", Usage: u(74, 63, 12)},
			{Number: 3, Email: "kim@example.com", Organization: "Team Beta", UsageStatus: "ok", Usage: u(100, 38, 0)},
			{Number: 4, Email: "lee@example.com", Organization: "Team Gamma", UsageStatus: "relogin_required", LastGood: u(6, 69, 0)},
			{Number: 5, Email: "setup-token-5@token.local", Alias: "ci-bot", UsageStatus: "unavailable"},
		}
		for i := range list {
			list[i].Active = list[i].Number == active
		}
		return list
	}
	return func(_ context.Context, args ...string) ([]byte, error) {
		mu.Lock()
		defer mu.Unlock()
		switch {
		case len(args) == 2 && args[0] == "list" && args[1] == "--json":
			return json.Marshal(map[string]any{
				"schemaVersion":       1,
				"activeAccountNumber": active,
				"accounts":            accounts(),
			})
		case len(args) == 2 && args[0] == "switch":
			n, err := strconv.Atoi(args[1])
			if err != nil {
				return nil, fmt.Errorf("bad account %q", args[1])
			}
			for _, a := range accounts() {
				if a.Number == n {
					if a.UsageStatus == "relogin_required" {
						return nil, fmt.Errorf("account %d needs a new login", n)
					}
					active = n
					return nil, nil
				}
			}
			return nil, fmt.Errorf("no account %d", n)
		}
		return nil, fmt.Errorf("unsupported cswap command %v", args)
	}
}
