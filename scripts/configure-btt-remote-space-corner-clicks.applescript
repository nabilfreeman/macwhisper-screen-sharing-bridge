-- Recreates two BetterTouchTool ordinary corner click triggers, scoped to
-- Apple Screen Sharing, that send Control-Left and Control-Right through
-- System Events.
--
-- BetterTouchTool's "Send Keyboard Shortcut" action can synthesize an Fn
-- transition while sending Control-Arrow. If MacWhisper uses Globe/Fn as its
-- dictation key, that transition can start dictation. Running these tiny
-- AppleScripts avoids that shortcut-sending path while preserving the exact
-- key chord Apple Screen Sharing forwards to the remote Mac.
--
-- These UUIDs identify the two triggers on the machine where this script was
-- created. Replace them before using the script on another BTT installation.
-- The script deletes and recreates triggers with these UUIDs. This is
-- intentional: updating BTTActionsToExecute through BTT's scripting API can
-- leave the action missing after BTT relaunches.

set leftTriggerUUID to "C74DDFFF-EAF2-4923-976F-E94D82D03A20"
set rightTriggerUUID to "602D8079-C0DB-4386-89D6-665551C0EB42"

set leftJSON to "{\"BTTTriggerBelongsToPreset\":\"Freeman\",\"BTTBelongsToApp\":\"Screen Sharing\",\"BTTTriggerType\":182,\"BTTTriggerTypeDescriptionReadOnly\":\"Corner Click Top Left\",\"BTTTriggerClass\":\"BTTTriggerTypeTouchpadAll\",\"BTTUUID\":\"" & leftTriggerUUID & "\",\"BTTEnabled\":1,\"BTTEnabled2\":1,\"BTTOrder\":7,\"BTTActionsToExecute\":[{\"BTTPredefinedActionType\":172,\"BTTPredefinedActionName\":\"Run AppleScript (Blocking)\",\"BTTAdditionalActionData\":{\"BTTScriptType\":0,\"BTTAppleScriptUsePath\":false,\"BTTScriptLocation\":0,\"BTTAppleScriptRunInBackground\":false,\"BTTAppleScriptString\":\"delay 0.15\\ntell application \\\"System Events\\\" to key code 123 using control down\"},\"BTTOrder\":0}]}"
set rightJSON to "{\"BTTTriggerBelongsToPreset\":\"Freeman\",\"BTTBelongsToApp\":\"Screen Sharing\",\"BTTTriggerType\":183,\"BTTTriggerTypeDescriptionReadOnly\":\"Corner Click Top Right\",\"BTTTriggerClass\":\"BTTTriggerTypeTouchpadAll\",\"BTTUUID\":\"" & rightTriggerUUID & "\",\"BTTEnabled\":1,\"BTTEnabled2\":1,\"BTTOrder\":8,\"BTTActionsToExecute\":[{\"BTTPredefinedActionType\":172,\"BTTPredefinedActionName\":\"Run AppleScript (Blocking)\",\"BTTAdditionalActionData\":{\"BTTScriptType\":0,\"BTTAppleScriptUsePath\":false,\"BTTScriptLocation\":0,\"BTTAppleScriptRunInBackground\":false,\"BTTAppleScriptString\":\"delay 0.15\\ntell application \\\"System Events\\\" to key code 124 using control down\"},\"BTTOrder\":0}]}"

tell application "BetterTouchTool"
	try
		delete_trigger leftTriggerUUID
	end try
	try
		delete_trigger rightTriggerUUID
	end try
	set leftResult to add_new_trigger leftJSON
	set rightResult to add_new_trigger rightJSON
end tell

-- A clean quit forces BTT to flush the new trigger/action relationships to its
-- Core Data store. Without this, a BTT crash immediately after configuration
-- can leave the parent trigger present but its attached action missing.
set resultText to leftResult & linefeed & rightResult
delay 1
tell application "BetterTouchTool" to quit
delay 1
do shell script "/usr/bin/open -a BetterTouchTool"

return resultText
