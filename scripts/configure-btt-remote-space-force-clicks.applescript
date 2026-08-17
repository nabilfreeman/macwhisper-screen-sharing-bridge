-- Reconfigures two existing BetterTouchTool trackpad triggers to send
-- Control-Left and Control-Right through System Events.
--
-- BetterTouchTool's "Send Keyboard Shortcut" action can synthesize an Fn
-- transition while sending Control-Arrow. If MacWhisper uses Globe/Fn as its
-- dictation key, that transition can start dictation. Running these tiny
-- AppleScripts avoids that shortcut-sending path while preserving the exact
-- key chord Apple Screen Sharing forwards to the remote Mac.
--
-- These UUIDs identify the two existing triggers on the machine where this
-- script was created. Replace them with the UUIDs of your own triggers before
-- using the script on another BetterTouchTool installation.

set leftTriggerUUID to "C74DDFFF-EAF2-4923-976F-E94D82D03A20"
set rightTriggerUUID to "602D8079-C0DB-4386-89D6-665551C0EB42"

set leftJSON to "{\"BTTActionsToExecute\":[{\"BTTPredefinedActionType\":172,\"BTTPredefinedActionName\":\"Run AppleScript (Blocking)\",\"BTTAdditionalActionData\":{\"BTTScriptType\":0,\"BTTAppleScriptUsePath\":false,\"BTTScriptLocation\":0,\"BTTAppleScriptRunInBackground\":false,\"BTTAppleScriptString\":\"tell application \\\"System Events\\\" to key code 123 using control down\"},\"BTTOrder\":0}]}"
set rightJSON to "{\"BTTActionsToExecute\":[{\"BTTPredefinedActionType\":172,\"BTTPredefinedActionName\":\"Run AppleScript (Blocking)\",\"BTTAdditionalActionData\":{\"BTTScriptType\":0,\"BTTAppleScriptUsePath\":false,\"BTTScriptLocation\":0,\"BTTAppleScriptRunInBackground\":false,\"BTTAppleScriptString\":\"tell application \\\"System Events\\\" to key code 124 using control down\"},\"BTTOrder\":0}]}"

tell application "BetterTouchTool"
	set leftResult to update_trigger leftTriggerUUID json leftJSON
	set rightResult to update_trigger rightTriggerUUID json rightJSON
end tell

return leftResult & linefeed & rightResult
