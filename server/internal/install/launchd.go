package install

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"time"
)

const launchLabel = "dev.mudo.mudod"

func xmlText(s string) string {
	var b bytes.Buffer
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

// LaunchAgentPlist is the per-user LaunchAgent that keeps `mudod serve` running on macOS.
func LaunchAgentPlist(bin, log string) string {
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>%s</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>serve</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>%s</string>
	<key>StandardErrorPath</key>
	<string>%s</string>
</dict>
</plist>
`, launchLabel, xmlText(bin), xmlText(log), xmlText(log))
}

// bootstrapLaunchAgent (re)loads the agent. bootout is asynchronous, so the
// following bootstrap can fail briefly with an I/O error; retry a few times.
func bootstrapLaunchAgent(o Options, plist string) error {
	target := fmt.Sprintf("gui/%d", o.UID)
	_, _ = o.Exec("launchctl", "bootout", target+"/"+launchLabel)
	var out string
	var err error
	for i := 0; i < 5; i++ {
		if out, err = o.Exec("launchctl", "bootstrap", target, plist); err == nil {
			return nil
		}
		o.sleep(300 * time.Millisecond)
	}
	return fmt.Errorf("launchctl bootstrap: %v: %s", err, out)
}
