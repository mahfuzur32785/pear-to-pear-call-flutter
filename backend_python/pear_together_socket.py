import socketio
from aiohttp import web

sio = socketio.AsyncServer(cors_allowed_origins="*")
app = web.Application()
sio.attach(app)

# Keep track of users in each room
rooms_users = {}

@sio.event
async def connect(sid, environ):
    print(f"Client connected: {sid}")

@sio.event
async def join(sid, data):
    room = data['room']
    await sio.enter_room(sid, room)

    print(f"{sid} joined room {room}")

    # Create the room list if it doesn't exist
    if room not in rooms_users:
        rooms_users[room] = []

    # Send existing users to the new user
    existing_users = [user for user in rooms_users[room] if user != sid]
    await sio.emit('existing-users', {'users': existing_users}, to=sid)

    # Add the new user to the room list
    rooms_users[room].append(sid)

    # Notify others in the room
    await sio.emit('user-joined', {'id': sid}, room=room, skip_sid=sid)

@sio.event
async def signal(sid, data):
    # Forward signaling data to the intended recipient
    target_id = data.get('to')
    if target_id:
        await sio.emit('signal', data, to=target_id)

@sio.event
async def disconnect(sid):
    print(f"Client disconnected: {sid}")

    # Remove user from rooms
    for room, users in rooms_users.items():
        if sid in users:
            users.remove(sid)
            # Notify others in the room
            await sio.emit('user-left', {'id': sid}, room=room)
            break  # sid should be in only one room

if __name__ == '__main__':
    web.run_app(app, port=5000)
