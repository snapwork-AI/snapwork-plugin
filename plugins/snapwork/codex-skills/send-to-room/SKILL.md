---
name: send-to-room
description: Send something from this conversation, or a file from this folder, to this chat's snapwork room, or, with a room's name first, to another of your snapwork rooms (a shortcut for "send this to the room"). Only when the person invokes it; never on your own.
---
The person wants something sent to a snapwork room: the text after this skill says what, often by
pointing at your conversation, and may start with the name of another of their rooms. The snapwork
plugin already handled this before you saw it. Its result is the line starting with "Snapwork:" in
your context for this message: follow it, and end your final answer with the one ```snapwork block
it describes. To send a file, the block's first line is attach: <its path in this folder> and the
rest is the note.

If there is no such line, the plugin's hooks did not run. Post nothing, and tell the person, in one
line, to trust snapwork's hooks in Settings, Hooks, then try again.
