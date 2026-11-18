# The README demo, recorded with vhs (github.com/charmbracelet/vhs).
#   docs/demo/prepare.sh && vhs docs/demo/demo.tape && docs/demo/teardown.sh
# One idea: a full simulator, `fast-ios on`, the same simulator light.
# Everything runs the real fast-ios against simulators in /tmp/demo/sims.
# Hidden, and said in the README caption: the shell set-up, the restart of
# the simulator after `fast-ios on` (quit and start it again, as fast-ios
# asks), and 200 s while its memory settles. Nothing else is cut or sped up.

# The raw recording; docs/demo/caption-video.sh adds the captions and makes
# the GIF, MP4, WebM, poster and subtitles track from it.
Output docs/demo/raw/demo-raw.mp4

Set Shell "bash"
Set FontSize 28
Set Width 1900
Set Height 860
Set Padding 36
Set Theme "Catppuccin Mocha"
Set TypingSpeed 70ms
Set WaitPattern /\$\s*$/
Set WaitTimeout 4m

Hide
Type "export PS1='$ ' PATH=/tmp/demo/bin:$PATH FASTIOS_DEVICE_SET=/tmp/demo/sims FASTIOS_STATE_DIR=/tmp/demo/state FASTIOS_AGENT_LABEL=dev.fast-ios.demo BASH_SILENCE_DEPRECATION_WARNING=1 && cd /tmp/demo && clear"
Enter
Wait
Show

# 1. A full simulator and its memory.
Sleep 500ms
Type "fast-ios"
Sleep 300ms
Enter
Wait
Sleep 6s
Ctrl+L

# 2. Turn fast-ios on.
Type "fast-ios on"
Sleep 300ms
Enter
Wait
Sleep 6s

# 3. Off screen: restart the simulator, then let memory settle.
Hide
Type `xcrun simctl --set sims shutdown "iPhone 18 Pro" && sleep 5 && xcrun simctl --set sims bootstatus "iPhone 18 Pro" -b >/dev/null && sleep 200 && clear`
Enter
Wait
Show
Type "# the simulator was quit and started again"
Sleep 1500ms
Enter
Wait
Type "fast-ios"
Sleep 300ms
Enter
Wait
Sleep 9s
