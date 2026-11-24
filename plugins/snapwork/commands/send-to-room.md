---
description: Send something from this conversation, or a file from this folder, to this chat's snapwork room, or to another of your rooms by naming it first
argument-hint: '[room name] <what to send, for example "this summary", "the plan we agreed" or "this file: report.pdf">'
disable-model-invocation: true
---
The person wants this sent to a Snapwork room:

$ARGUMENTS

It is a shortcut for "send this to the room", in the middle of your conversation with them. When
it starts with the name of another of their rooms, it goes there. The Snapwork plugin has already
handled this command before you saw it. Its result is the line starting with "Snapwork:" in your
context: follow it.
