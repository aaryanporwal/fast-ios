# Template for docs/design/cli/stills.sh (@THEME@ and @SUFFIX@ are filled in).
Output "/tmp/fastios-stills/stills-@SUFFIX@.gif"

Set Shell "bash"
Set FontSize 20
Set Width 1400
Set Height 1180
Set Padding 28
Set Theme "@THEME@"
Set TypingSpeed 0
Set WaitPattern /\$\s*$/
Set WaitTimeout 2m

Hide
Type "export PS1='$ ' PATH=/tmp/fastios-stills/bin:$PATH FASTIOS_DEVICE_SET=/tmp/fastios-stills/sims FASTIOS_STATE_DIR=/tmp/fastios-stills/state FASTIOS_AGENT_LABEL=dev.fast-ios.stills BASH_SILENCE_DEPRECATION_WARNING=1 && cd /tmp/fastios-stills && clear"
Enter
Wait
Show

Type "fast-ios"
Enter
Wait
Sleep 1s
Screenshot docs/design/cli/home-@SUFFIX@.png
Sleep 500ms
Hide
Type "clear"
Enter
Wait
Sleep 300ms
Show

Type "fast-ios status"
Enter
Wait
Sleep 1s
Screenshot docs/design/cli/status-@SUFFIX@.png
Sleep 500ms
Hide
Type "clear"
Enter
Wait
Sleep 300ms
Show

Type "fast-ios doctor"
Enter
Wait
Sleep 1s
Screenshot docs/design/cli/doctor-@SUFFIX@.png
Sleep 500ms
Hide
Type "clear"
Enter
Wait
Sleep 300ms
Show

Type "fast-ios help"
Enter
Wait
Sleep 1s
Screenshot docs/design/cli/help-@SUFFIX@.png
Sleep 500ms
Hide
Type "clear"
Enter
Wait
Sleep 300ms
Show

Type "fast-ios on --dry-run=yes; fast-ios slim no-such-phone"
Enter
Wait
Sleep 1s
Screenshot docs/design/cli/error-@SUFFIX@.png
Sleep 1s
