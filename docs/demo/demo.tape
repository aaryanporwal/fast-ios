# The README demo, recorded with vhs (github.com/charmbracelet/vhs).
#   docs/demo/prepare.sh && vhs docs/demo/demo.tape && docs/demo/teardown.sh
# Everything runs the real fast-ios against simulators in /tmp/demo/sims.
# Hidden parts: the shell set-up below, a 3 s pause while the helper makes
# the stopped simulator light, and the wait for memory to settle before the
# last `fast-ios`. Nothing else is cut or sped up.

Output docs/demo/fast-ios-demo.gif
Output docs/demo/fast-ios-demo.mp4
Output docs/demo/fast-ios-demo.webm

Set Shell "bash"
Set FontSize 22
Set Width 1280
Set Height 820
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms
Set WaitPattern /\$\s*$/
Set WaitTimeout 3m

Hide
Type "export PS1='$ ' PATH=/tmp/demo/bin:$PATH FASTIOS_DEVICE_SET=/tmp/demo/sims FASTIOS_STATE_DIR=/tmp/demo/state FASTIOS_AGENT_LABEL=dev.fast-ios.demo BASH_SILENCE_DEPRECATION_WARNING=1 && cd /tmp/demo && clear"
Enter
Wait
Show

# 1. A full simulator.
Type "fast-ios"
Enter
Wait
Sleep 3s

# 2. Turn fast-ios on, then restart the simulator.
Type "fast-ios on"
Enter
Wait
Sleep 2s
Type `xcrun simctl --set sims shutdown "iPhone 18 Pro"`
Enter
Wait
Hide
Sleep 3s
Show
Type `xcrun simctl --set sims boot "iPhone 18 Pro"`
Enter
Wait
Sleep 1s
Ctrl+L

# 3. The agent path: one command to a running app, cold from the template, then warm.
Type "UDID=$(fast-ios run --app MyApp.app)"
Enter
Wait
Sleep 2s
Type "fast-ios release $UDID && fast-ios run --app MyApp.app"
Enter
Wait
Sleep 2s
Type "fast-ios shot --app MyApp.app --udid $UDID --max-width 400 --out shots"
Enter
Wait
Sleep 3s
Ctrl+L

# 4. Memory settles (hidden wait), then the result.
Hide
Type "sleep 150 && clear"
Enter
Wait
Show
Type "fast-ios"
Enter
Wait
Sleep 6s
