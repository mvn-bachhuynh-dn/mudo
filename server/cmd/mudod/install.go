package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"time"

	"mudo/internal/install"
)

func installOptions() (install.Options, error) {
	p, err := homePaths()
	if err != nil {
		return install.Options{}, err
	}
	self, err := os.Executable()
	if err != nil {
		return install.Options{}, err
	}
	if resolved, err := filepath.EvalSymlinks(self); err == nil {
		self = resolved
	}
	host, _ := os.Hostname()
	u, err := user.Current()
	if err != nil {
		return install.Options{}, err
	}
	return install.Options{
		Home: p.Home, Self: self, Hostname: host, User: u.Username, Now: time.Now,
		Exec: func(name string, args ...string) (string, error) {
			out, err := exec.Command(name, args...).CombinedOutput()
			return string(out), err
		},
	}, nil
}

func runInstall([]string) error {
	o, err := installOptions()
	if err != nil {
		return err
	}
	res, err := install.Run(o)
	for _, w := range res.Warnings {
		fmt.Println("warning:", w)
	}
	if err != nil {
		return err
	}
	fmt.Println("mudod installed and running. Add this server in MuDo (open on the Mac):")
	fmt.Println(res.ConnectURL)
	return nil
}

func runUninstall([]string) error {
	o, err := installOptions()
	if err != nil {
		return err
	}
	if err := install.Uninstall(o); err != nil {
		return err
	}
	p, _ := homePaths()
	fmt.Printf("mudod unit and hooks removed. Kept: %s, %s, %s\n", p.Config, p.State, p.Bin)
	return nil
}
